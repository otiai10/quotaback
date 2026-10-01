import Foundation
import SwiftUI

/// UI 用。観測・推定は UsageEngine に任せ、表示用の値を公開するだけ。
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var config: AppConfig
    @Published private(set) var accounts: [AccountView] = []
    @Published private(set) var refreshing = false
    /// config.json を読めなかったときのメッセージ（直前の設定のまま動き続ける）
    @Published private(set) var configError: String?

    private let engine = UsageEngine(log: ObservationLog.load())
    private var targets: [PollTarget] = []
    private var refreshTimer: Timer?
    private var watchTimer: Timer?
    private var switchTimer: Timer?
    private var lastFetchAt: Date?
    private var pending = false
    private var configWatcher: DispatchSourceFileSystemObject?
    private var configStamp: Date?

    /// 推定値の再計算（リセット時刻の通過など）と config.json の確認の間隔
    static let watchInterval: TimeInterval = 15
    /// ログイン切り替えの確認間隔。`.claude.json` の mtime を見るだけで、変わったときだけ中身を読む
    static let switchCheckInterval: TimeInterval = 2
    /// 切り替えを検知してから取得するまでの待ち（認証情報の書き込みが追いつくのを待つ）
    static let switchDebounce: UInt64 = 1_000_000_000
    /// 切り替え途中で見送ったときの取り直し（秒後）。2回目は取り違え判定が確定する時間の後
    static let retryDelays: [TimeInterval] = [5, UsageEngine.conflictSettle + 5]
    /// パネルを開いたとき、直近の取得がこれより古ければ取り直す
    static let staleOnOpen: TimeInterval = 60

    init() {
        config = AppConfig.load()
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
        let interval = TimeInterval(max(60, config.refreshSeconds))
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll(reason: "timer") }
        }
        watchTimer = Timer.scheduledTimer(withTimeInterval: Self.watchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.watch() }
        }
        switchTimer = Timer.scheduledTimer(withTimeInterval: Self.switchCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkSwitch() }
        }
    }

    /// パネルを開いたとき。切り替えを今すぐ確認し、値が古ければ取り直す
    func panelOpened() {
        Task {
            await checkSwitch(reason: "panel")
            if lastFetchAt.map({ Date().timeIntervalSince($0) > Self.staleOnOpen }) ?? true {
                refresh(targets, reason: "panel")
            }
        }
    }

    /// 「設定を再読込」。取得もやり直す
    func reloadConfig() {
        configStamp = AppConfig.modificationDate()
        switch AppConfig.read() {
        case .success(let new):
            configError = nil
            config = new
            start()
        case .failure(let error):
            configError = "config.json を読めません（前の設定のまま）: \(error.localizedDescription)"
        }
    }

    // MARK: - config.json の変更を反映

    /// エディタの保存（一時ファイル → rename）でファイル自体の監視は外れるので、ディレクトリを監視する。
    /// 書き換えの方法によってはディレクトリのイベントが出ないので、watch() でも mtime を確認する。
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

    /// config.json が変わっていたら反映する。ラベルなど表示だけの変更なら取得し直さない
    private func configMaybeChanged() {
        let stamp = AppConfig.modificationDate()
        guard stamp != configStamp else { return }
        configStamp = stamp
        guard stamp != nil else { return }   // 保存の途中で一瞬消えている
        switch AppConfig.read() {
        case .success(let new):
            configError = nil
            guard new != config else { return }
            let refetch = new.needsRefetch(comparedTo: config)
            config = new
            if refetch { start() } else { Task { await updateViews() } }
        case .failure(let error):
            configError = "config.json を読めません（前の設定のまま）: \(error.localizedDescription)"
        }
    }

    func refreshAll(reason: String = "manual") {
        refresh(targets, reason: reason)
    }

    /// - Parameter attempt: 切り替え途中で見送られた対象の取り直し回数
    private func refresh(_ list: [PollTarget], reason: String, attempt: Int = 0) {
        guard !list.isEmpty else { return }
        // 取得中に呼ばれたら、終わってからもう一度まとめて取る
        guard !refreshing else { pending = true; return }
        refreshing = true
        Task {
            let reports = await engine.refresh(list, reason: reason)
            lastFetchAt = Date()
            await updateViews()
            refreshing = false
            if pending {
                pending = false
                refreshAll(reason: "pending")
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

    /// ログインが切り替わった対象だけすぐ取りに行く
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
        accounts = await engine.accountViews(config: config.accounts)
    }

    var menuBarTitle: String {
        accounts.map(\.menuBarText).joined(separator: " · ")
    }
}
