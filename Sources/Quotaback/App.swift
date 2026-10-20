import SwiftUI
import AppKit
import ServiceManagement

import Combine

/// Menu bar item and panel. MenuBarExtra(.window) doesn't shrink its window when the content shrinks,
/// so this uses NSStatusItem + NSPopover and sizes the panel from NSHostingController's preferredContentSize.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var store: UsageStore!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var titleSubscription: AnyCancellable?
    private var analytics: AnalyticsWindowController!
    /// Closes the panel on clicks in other apps. .transient alone misses them when activation doesn't take
    /// (macOS 14+ treats activate(ignoringOtherApps:) as a request). Mouse-only global monitors need no permission
    private var outsideClickMonitor: Any?
    private var fadingOut = false
    private static let fadeInDuration: TimeInterval = 0.14
    private static let fadeOutDuration: TimeInterval = 0.12

    func applicationWillTerminate(_ notification: Notification) {
        BrowserLogin.shared.cancel()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an agent app without a Dock icon (same as LSUIElement in Info.plist)
        NSApp.setActivationPolicy(.accessory)

        store = UsageStore()
        analytics = AnalyticsWindowController(store: store)

        let hosting = NSHostingController(rootView: UsagePanel(store: store) { [weak self] in
            self?.popover.performClose(nil)
            self?.analytics.show()
        })
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        titleSubscription = store.$accounts.receive(on: RunLoop.main).sink { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
        updateTitle()
    }

    private func updateTitle() {
        let title = store.menuBarTitle.isEmpty ? "Quotaback" : store.menuBarTitle
        statusItem.button?.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
    }

    /// Left click opens the panel, right click (or control-click) the menu
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func showMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        let refresh = NSMenuItem(title: L10n.refresh, action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !store.refreshing
        menu.addItem(refresh)
        if LoginItem.isAvailable {
            let login = NSMenuItem(title: L10n.launchAtLogin, action: #selector(toggleLoginItem), keyEquivalent: "")
            login.target = self
            login.state = LoginItem.isEnabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L10n.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // Temporarily assigning the menu and clicking is the usual way to show a menu under a status item
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() {
        store.refreshAll()
    }

    @objc private func toggleLoginItem() {
        do {
            try LoginItem.set(!LoginItem.isEnabled)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = L10n.launchAtLoginFailed
            alert.runModal()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.panelOpened()
            // Without activating, clicking outside doesn't close it
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            fadeIn()
        }
    }

    /// NSPopover's own animation can't be shortened (and also animates resizing), so it's off and the panel fades itself
    private func fadeIn() {
        guard let window = popover.contentViewController?.view.window else { return }
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeInDuration
            window.animator().alphaValue = 1
        }
    }

    /// Every close request (performClose and .transient) comes through here. Fade out, then close() skips this
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        guard let window = popover.contentViewController?.view.window else { return true }
        if fadingOut { return false }
        fadingOut = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOutDuration
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.fadingOut = false
                self.popover.close()
            }
        })
        return false
    }

    func popoverDidShow(_ notification: Notification) {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.popover.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }
}

struct UsagePanel: View {
    @ObservedObject var store: UsageStore
    let openAnalytics: () -> Void
    /// Only accounts toggled by hand are recorded. Otherwise logged-in accounts are expanded and others collapsed
    @State private var expandedOverride: [String: Bool] = [:]

    private func expandedBinding(for account: AccountView) -> Binding<Bool> {
        Binding(
            get: { expandedOverride[account.id] ?? account.isLive },
            set: { expandedOverride[account.id] = $0 }
        )
    }

    /// Actual height of the account list (to size the scroll area to it)
    @State private var listHeight: CGFloat = 0

    /// Max list height that fits on screen, minus the buttons (~120pt) and room for the menu bar and popover arrow
    private var maxListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(200, screen - 160)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Expanded lists may not fit on screen, so only the list scrolls and the buttons stay visible
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(store.accounts) { account in
                        AccountSection(account: account, expanded: expandedBinding(for: account))
                        if account != store.accounts.last { Divider() }
                    }
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: ListHeightKey.self, value: g.size.height)
                })
            }
            .frame(height: min(listHeight, maxListHeight))
            .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            if let err = store.configError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            // Refresh, Launch at Login and Quit live in the status item's right-click menu
            HStack(spacing: 6) {
                if let t = store.accounts.filter(\.isLive).compactMap(\.observedAt).max() {
                    Text(L10n.fetchedAt(t.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(L10n.locale))))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if store.refreshing { ProgressView().controlSize(.mini) }
                Spacer()
                Button(L10n.analytics, action: openAnalytics)
                    .controlSize(.small)
                Button(L10n.openSettings) {
                    NSWorkspace.shared.open(AppConfig.path)
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Launch at Login (SMAppService). Only available when running from an .app bundle.
enum LoginItem {
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}

struct AccountSection: View {
    let account: AccountView
    @Binding var expanded: Bool
    @State private var loginHovered = false
    @ObservedObject private var login = BrowserLogin.shared

    /// Width of the header's ▸ and its gap to the label. Content is indented by this to line up with the label
    private static let chevronWidth: CGFloat = 10
    private static let headerSpacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if login.running && login.activeKey == account.key {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    if login.acceptsCode {
                        Button("ログイン中…") { login.showCodeEntry() }
                            .buttonStyle(.link)
                            .help("認証コードを手動で入力")
                    } else {
                        Text("ログイン中…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("キャンセル") { login.cancel() }
                        .buttonStyle(.borderless)
                }
                .font(.caption)
                .padding(.leading, Self.chevronWidth + Self.headerSpacing)
            }
            content
                .padding(.leading, Self.chevronWidth + Self.headerSpacing)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            if expanded {
                ForEach(account.windows) { w in
                    WindowRow(estimate: w)
                }
            } else if let rep = account.representative {
                // When collapsed, only the fullest window
                WindowRow(estimate: rep)
            }

            if let err = account.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if expanded {
                if let t = account.observedAt, !account.isLive {
                    Text(observedText(t))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if account.observedAt == nil, account.error == nil {
                    Text(L10n.notObservedYet)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // アカウント名は開閉、プロバイダアイコンはログイン操作を担当する。
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.headerSpacing) {
            Button {
                expanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Self.headerSpacing) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: Self.chevronWidth)
                    Text(account.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if AccountLogin.command(for: account.key) != nil {
                Button {
                    AccountLogin.showMenu(for: account.key)
                } label: {
                    loginMark
                        .padding(3)
                        .background {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.blue.opacity(loginHovered ? 0.25 : 0))
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    loginHovered = hovering
                }
                .onDisappear { loginHovered = false }
            } else {
                loginMark
            }
        }
    }

    /// The provider's logo (or its name when there is none) with the login state: a green dot and a solid logo
    /// when logged in, a faded logo otherwise. The words are in the tooltip
    private var loginMark: some View {
        let state = account.isLive ? L10n.loggedIn : L10n.notLoggedIn
        return HStack(spacing: 4) {
            if account.isLive {
                Circle().fill(Color.green).frame(width: 6, height: 6)
            }
            Group {
                if let icon = ProviderIcon.image(for: account.key.provider) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 13, height: 13)
                } else {
                    Text(account.providerName).font(.caption2)
                }
            }
            .foregroundStyle(account.isLive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .opacity(account.isLive ? 1 : 0.5)
        }
        .help("\(account.providerName) · \(state)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(account.providerName), \(state)")
    }

    private func observedText(_ t: Date) -> String {
        let time = t.formatted(Date.FormatStyle(date: Calendar.current.isDateInToday(t) ? .omitted : .abbreviated,
                                                time: .shortened).locale(L10n.locale))
        let relative = RelativeDateTimeFormatter()
        relative.locale = L10n.locale
        return L10n.lastObserved(time, relative.localizedString(for: t, relativeTo: Date()))
    }
}

/// A thin bar drawn in SwiftUI (unlike ProgressView, it also renders in ImageRenderer for the layout tests)
struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: max(fraction > 0 ? 4 : 0, g.size.width * fraction))
            }
        }
        .frame(height: 4)
    }
}

struct WindowRow: View {
    let estimate: WindowEstimate

    private var window: WindowObservation { estimate.window }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(window.title).font(.subheadline)
                Spacer()
                Text(valueText)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(valueColor)
            }
            UsageBar(fraction: min(estimate.lowerBound, 100) / 100, color: color)
            // Under the bar: the limit ETA on the left, the detail (e.g. "$0.00 / $200.00") and the reset on the right
            if resetText != nil || estimate.limitETA != nil || window.detail != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let eta = estimate.limitETA {
                        // When the limit would be hit at this pace (the bar turns orange too)
                        Text(L10n.limitAround(Self.format(eta)))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help(L10n.limitAroundHelp)
                    }
                    Spacer(minLength: 4)
                    if let detail = window.detail {
                        Text(detail)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let reset = resetText {
                        Text(reset)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }
        }
    }

    private var valueText: String {
        switch estimate.value {
        case .exact(let v): return "\(Int(v.rounded()))%"
        case .atLeast(let v): return "≥\(Int(v.rounded()))%"
        case .reset: return L10n.resetDone
        }
    }

    /// The number stays in the text color (colored text is hard to read on the translucent panel); the bar carries the color
    private var valueColor: Color {
        if case .reset = estimate.value { return .secondary }
        return .primary
    }

    private var resetText: String? {
        switch estimate.nextReset {
        case .known(let d): return L10n.resets(Self.format(d))
        case .projected(let d): return L10n.resetsProjected(Self.format(d))
        case .unknown:
            if case .reset = estimate.value, case .rolling = window.cadence {
                return L10n.resetStartsOnUse
            }
            return nil
        }
    }

    private var color: Color {
        switch estimate.lowerBound {
        case ..<60: return estimate.limitETA == nil ? .accentColor : .orange
        case ..<85: return .orange
        default: return .red
        }
    }

    /// e.g. "10/3 (Sat) 14:00". The weekday follows the display language
    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateFormat = "M/d (E) HH:mm"
        return f.string(from: date)
    }
}
