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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as an agent app without a Dock icon (same as LSUIElement in Info.plist)
        NSApp.setActivationPolicy(.accessory)

        store = UsageStore()

        let hosting = NSHostingController(rootView: UsagePanel(store: store))
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
        }
    }
}

struct UsagePanel: View {
    @ObservedObject var store: UsageStore
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
                VStack(alignment: .leading, spacing: 14) {
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

    /// Width of the header's ▸ and its gap to the label. Content is indented by this to line up with the label
    private static let chevronWidth: CGFloat = 10
    private static let headerSpacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
                .padding(.leading, Self.chevronWidth + Self.headerSpacing)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
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

    /// Click to expand or collapse
    private var header: some View {
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
                Text(account.providerName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(account.isLive ? L10n.loggedIn : L10n.notLoggedIn)
                    .font(.caption2)
                    .foregroundStyle(account.isLive ? Color.green : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func observedText(_ t: Date) -> String {
        let time = t.formatted(Date.FormatStyle(date: Calendar.current.isDateInToday(t) ? .omitted : .abbreviated,
                                                time: .shortened).locale(L10n.locale))
        let relative = RelativeDateTimeFormatter()
        relative.locale = L10n.locale
        return L10n.lastObserved(time, relative.localizedString(for: t, relativeTo: Date()))
    }
}

struct WindowRow: View {
    let estimate: WindowEstimate

    private var window: WindowObservation { estimate.window }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title).font(.subheadline)
                Spacer()
                Text(valueText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(valueColor)
            }
            if let detail = window.detail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(estimate.lowerBound, 100), total: 100)
                .tint(color)
            if resetText != nil || estimate.limitETA != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let reset = resetText {
                        Text(reset)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if let eta = estimate.limitETA {
                        // When the limit would be hit at this pace
                        Label(L10n.limitAround(Self.format(eta)), systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                            .help(L10n.limitAroundHelp)
                    }
                }
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

    private var valueColor: Color {
        if case .reset = estimate.value { return .secondary }
        return color
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
        case ..<60: return .accentColor
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
