import SwiftUI
import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dock に出さない常駐アプリにする（Info.plist の LSUIElement 相当）
        NSApp.setActivationPolicy(.accessory)
    }
}

struct QuotabackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(store: store)
        } label: {
            Text(store.menuBarTitle)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
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

    /// 画面に収まる一覧の最大の高さ。ボタン類（約120pt）とメニューバーからの余白を引く
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
            HStack {
                Button("更新") { store.refreshAll() }
                    .disabled(store.refreshing)
                Button("設定を開く") {
                    NSWorkspace.shared.open(AppConfig.path)
                }
                Button("設定を再読込") { store.reloadConfig() }
                Spacer()
                if store.refreshing { ProgressView().controlSize(.mini) }
                Button("終了") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
            if LoginItem.isAvailable {
                LoginItemToggle()
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { store.panelOpened() }
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

struct LoginItemToggle: View {
    @State private var enabled = LoginItem.isEnabled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("ログイン時に起動", isOn: Binding(
                get: { enabled },
                set: { newValue in
                    do {
                        try LoginItem.set(newValue)
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                    enabled = LoginItem.isEnabled
                }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

struct AccountSection: View {
    let account: AccountView
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

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
                if let t = account.observedAt {
                    Text(observedText(t))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if account.error == nil {
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
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("\(account.label) - \(account.name)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
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
        if account.isLive { return "取得: \(time)" }
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
            if let reset = resetText {
                Text(reset)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let eta = estimate.limitETA {
                Text("このペースだと \(Self.resetFormatter.string(from: eta)) 頃に上限")
                    .font(.caption2)
                    .foregroundStyle(.orange)
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
