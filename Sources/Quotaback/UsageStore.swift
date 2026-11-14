import Foundation
import SwiftUI

/// For the UI. Leaves observing and estimating to UsageEngine and only publishes values for display.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var config: AppConfig
    @Published private(set) var accounts: [AccountView] = []
    /// Data for the Analytics window. Only kept up to date while the window is open
    @Published private(set) var analytics = AnalyticsInput()
    var analyticsVisible = false {
        didSet {
            if analyticsVisible { Task { await updateViews() } } else { analytics = AnalyticsInput() }
        }
    }
    @Published private(set) var refreshing = false
    /// Message when config.json can't be read (keeps running with the previous settings)
    @Published private(set) var configError: String?

    private let engine = UsageEngine(log: ObservationLog.load())
    private var targets: [PollTarget] = []
    private var refreshTimer: Timer?
    private var watchTimer: Timer?
    private var switchTimer: Timer?
    /// Target → when it was last sent to the engine (any reason). Drives `PollSchedule`
    private var lastAttempt: [String: Date] = [:]
    /// Targets asked for while a refresh was running; fetched right after it
    private var pending: [PollTarget] = []
    private var configWatcher: DispatchSourceFileSystemObject?
    private var configStamp: Date?

    /// Interval for recomputing estimates (e.g. passing a reset time) and checking config.json
    static let watchInterval: TimeInterval = 15
    /// Interval for checking login switches. Only looks at the mtime of `.claude.json` and reads it only when it changed
    static let switchCheckInterval: TimeInterval = 2
    /// Delay between detecting a switch and fetching (lets the credential write catch up)
    static let switchDebounce: UInt64 = 1_000_000_000
    /// Retries (seconds later) after skipping mid-switch. The second one comes after the mix-up check settles
    static let retryDelays: [TimeInterval] = [5, UsageEngine.conflictSettle + 5]

    init() {
        config = AppConfig.load()
        L10n.apply(config.language)
        configStamp = AppConfig.modificationDate()
        watchConfigDirectory()
        start()
    }

    func start() {
        targets = Providers.targets(config: config)
        refreshTimer?.invalidate()
        watchTimer?.invalidate()
        switchTimer?.invalidate()
        Task { await updateViews() }
        refreshAll(reason: "start")
        refreshTimer = Timer.scheduledTimer(withTimeInterval: PollSchedule.tick, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshDue(reason: "timer") }
        }
        watchTimer = Timer.scheduledTimer(withTimeInterval: Self.watchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.watch() }
        }
        switchTimer = Timer.scheduledTimer(withTimeInterval: Self.switchCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkSwitch() }
        }
    }

    /// When the panel opens: check for a switch now, and fetch what is due without waiting for the next tick.
    /// Opening the panel is not an explicit fetch, so it follows `PollSchedule` (the "Refresh" menu doesn't)
    func panelOpened() {
        Task {
            await checkSwitch(reason: "panel")
            await refreshDue(reason: "panel")
        }
    }

    // MARK: - Applying config.json changes

    /// Editors save via a temp file + rename, which breaks watching the file itself, so watch the directory.
    /// Some ways of rewriting produce no directory event, so watch() also checks the mtime.
    private func watchConfigDirectory() {
        try? FileManager.default.createDirectory(at: AppConfig.directory, withIntermediateDirectories: true)
        let fd = open(AppConfig.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.configMaybeChanged() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }

    /// Applies config.json if it changed. Display-only changes such as labels don't trigger a refetch
    private func configMaybeChanged() {
        let stamp = AppConfig.modificationDate()
        guard stamp != configStamp else { return }
        configStamp = stamp
        guard stamp != nil else { return }   // Briefly missing in the middle of a save
        switch AppConfig.read() {
        case .success(let new):
            configError = nil
            guard new != config else { return }
            let refetch = new.needsRefetch(comparedTo: config)
            // Error messages etc. are built at fetch time, so refetch when the language changes
            let relocalize = new.language != config.language
            L10n.apply(new.language)
            config = new
            if refetch { start() } else if relocalize { refreshAll(reason: "language") } else { Task { await updateViews() } }
        case .failure(let error):
            configError = L10n.configUnreadable(error.localizedDescription)
        }
    }

    /// Adds observed accounts missing from config.json. Keeps every observed account in the config
    /// so its label can be edited. Fetch targets don't change, so no refetch
    private func registerObservedAccounts() async {
        guard configError == nil,
              let new = AppConfig.registerAccounts(await engine.observedAccounts) else { return }
        configStamp = AppConfig.modificationDate()
        config = new
    }

    /// Fetches the targets whose `PollSchedule` interval has passed since their last attempt.
    /// When anything is due, also rediscovers locations (e.g. a newly added `CLAUDE_CONFIG_DIR`); new ones are due at once
    private func refreshDue(reason: String) async {
        guard !(await dueTargets(targets)).isEmpty else { return }
        targets = Providers.targets(config: config)
        refresh(await dueTargets(targets), reason: reason)
    }

    private func dueTargets(_ list: [PollTarget]) async -> [PollTarget] {
        let now = Date()
        var due: [PollTarget] = []
        for t in list {
            guard let last = lastAttempt[t.id] else { due.append(t); continue }
            // Half a tick of tolerance so a 15-minute interval isn't pushed to 15.5 by timer jitter
            if now.timeIntervalSince(last) >= (await engine.pollInterval(t, now: now)) - PollSchedule.tick / 2 {
                due.append(t)
            }
        }
        return due
    }

    /// Fetches all targets now (start, the "Refresh" menu, a language change). Also rediscovers locations
    func refreshAll(reason: String = "manual") {
        targets = Providers.targets(config: config)
        refresh(targets, reason: reason)
    }

    /// - Parameter attempt: how many times targets skipped mid-switch have been retried
    private func refresh(_ list: [PollTarget], reason: String, attempt: Int = 0) {
        guard !list.isEmpty else { return }
        // If called while fetching, fetch these right after it
        guard !refreshing else {
            pending += list.filter { t in !pending.contains { $0.id == t.id } }
            return
        }
        refreshing = true
        let started = Date()
        for t in list { lastAttempt[t.id] = started }
        Task {
            let reports = await engine.refresh(list, reason: reason)
            await registerObservedAccounts()
            await updateViews()
            refreshing = false
            if !pending.isEmpty {
                let next = pending
                pending = []
                refresh(next, reason: "pending")
            }
            let skipped = reports.compactMap { r -> PollTarget? in
                if case .skipped = r.outcome { return r.target }
                return nil
            }
            if !skipped.isEmpty && attempt < Self.retryDelays.count {
                try? await Task.sleep(nanoseconds: UInt64(Self.retryDelays[attempt] * 1_000_000_000))
                refresh(skipped, reason: "retry", attempt: attempt + 1)
            }
        }
    }

    /// Immediately fetches only the targets whose login switched
    private func checkSwitch(reason: String = "switch") async {
        let changed = await engine.changedTargets(targets)
        guard !changed.isEmpty else { return }
        try? await Task.sleep(nanoseconds: Self.switchDebounce)
        refresh(changed, reason: reason)
    }

    private func watch() async {
        configMaybeChanged()
        await updateViews()
    }

    private func updateViews() async {
        let now = Date()
        accounts = await engine.accountViews(config: config.accounts, now: now)
        if analyticsVisible { analytics = await engine.analytics(views: accounts, now: now) }
    }

    var menuBarTitle: String {
        accounts.map(\.menuBarText).joined(separator: " · ")
    }
}
