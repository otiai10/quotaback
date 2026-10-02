import SwiftUI
import AppKit
import ServiceManagement

import Combine

/// メニューバーの項目とパネル。MenuBarExtra(.window) は中身が縮んでもウィンドウが縮まないので、
/// NSStatusItem + NSPopover にして、パネルの大きさは NSHostingController の preferredContentSize に追従させる。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var store: UsageStore!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var titleSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock に出さない常駐アプリにする（Info.plist の LSUIElement 相当）
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

    /// 左クリックでパネル、右クリック（または control＋クリック）でメニュー
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
        let refresh = NSMenuItem(title: "更新", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        refresh.isEnabled = !store.refreshing
        menu.addItem(refresh)
        if LoginItem.isAvailable {
            let login = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLoginItem), keyEquivalent: "")
            login.target = self
            login.state = LoginItem.isEnabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // メニューを一時的に割り当ててクリックさせるのが、ステータス項目の下にメニューを出す定番の方法
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
            alert.messageText = "ログイン時に起動を切り替えられませんでした"
            alert.runModal()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.panelOpened()
            // アクティブにしておかないと、外をクリックしても閉じない
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

struct UsagePanel: View {
    @ObservedObject var store: UsageStore
    /// 開閉を手で切り替えたアカウントだけ記録する。未指定ならログイン中は開き、未ログインは畳む
    @State private var expandedOverride: [String: Bool] = [:]

    private func expandedBinding(for account: AccountView) -> Binding<Bool> {
        Binding(
            get: { expandedOverride[account.id] ?? account.isLive },
            set: { expandedOverride[account.id] = $0 }
        )
    }

    /// アカウント一覧の実際の高さ（スクロール領域をそれに合わせるため）
    @State private var listHeight: CGFloat = 0

    /// 画面に収まる一覧の最大の高さ。ボタン類（約120pt）とメニューバー・ポップオーバーの矢印の余白を引く
    private var maxListHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(200, screen - 160)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 開くと画面に収まらないことがあるので、一覧だけスクロールさせてボタン類は常に見せる
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
            // 更新・ログイン時に起動・終了はメニューバーの項目の右クリックメニューにある
            HStack(spacing: 6) {
                if let t = store.accounts.filter(\.isLive).compactMap(\.observedAt).max() {
                    Text("取得: \(t.formatted(date: .omitted, time: .shortened))")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if store.refreshing { ProgressView().controlSize(.mini) }
                Spacer()
                Button("設定を開く") {
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

/// ログイン時に起動（SMAppService）。.app バンドルから起動しているときだけ使える。
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

    /// 見出しの ▸ の幅と、▸ とラベルの間隔。中身はこの分だけ下げてラベルの位置に揃える
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
                // 畳んでいるときは一番埋まっている枠だけ
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
                    Text("まだ観測していません（このアカウントで claude にログインすると取得されます）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// クリックで開閉
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
                Text(account.isLive ? "ログイン中" : "未ログイン")
                    .font(.caption2)
                    .foregroundStyle(account.isLive ? Color.green : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func observedText(_ t: Date) -> String {
        let time = t.formatted(date: Calendar.current.isDateInToday(t) ? .omitted : .abbreviated, time: .shortened)
        let ago = RelativeDateTimeFormatter().localizedString(for: t, relativeTo: Date())
        return "最終観測: \(time)（\(ago)）· 以降の使用は含まない下限値"
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
                        // このペースで使い続けたら上限に達する見込みの時刻
                        Label("\(Self.resetFormatter.string(from: eta)) 頃に上限", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                            .help("このペースで使い続けた場合の見込み")
                    }
                }
            }
        }
    }

    private var valueText: String {
        switch estimate.value {
        case .exact(let v): return "\(Int(v.rounded()))%"
        case .atLeast(let v): return "≥\(Int(v.rounded()))%"
        case .reset: return "リセット済み"
        }
    }

    private var valueColor: Color {
        if case .reset = estimate.value { return .secondary }
        return color
    }

    private var resetText: String? {
        switch estimate.nextReset {
        case .known(let d): return "Resets \(Self.resetFormatter.string(from: d))"
        case .projected(let d): return "Resets \(Self.resetFormatter.string(from: d))（推定）"
        case .unknown:
            if case .reset = estimate.value, case .rolling = window.cadence {
                return "次のリセットは使い始めてから決まる"
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

    static let resetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d (E) HH:mm"
        return f
    }()
}
