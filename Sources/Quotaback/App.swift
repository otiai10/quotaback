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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(store.config.accounts) { account in
                AccountSection(account: account, state: store.state(for: account))
                if account != store.config.accounts.last { Divider() }
            }
            Divider()
            HStack {
                Button("更新") { store.refreshAll() }
                Button("設定を開く") {
                    NSWorkspace.shared.open(AppConfig.path)
                }
                Button("設定を再読込") { store.reloadConfig() }
                Spacer()
                Button("終了") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
            if LoginItem.isAvailable {
                LoginItemToggle()
            }
        }
        .padding(14)
        .frame(width: 340)
    }
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
    let account: AccountConfig
    let state: AccountState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(account.name).font(.headline)
                Spacer()
                if state.loading { ProgressView().controlSize(.mini) }
            }

            ForEach(state.windows) { w in
                WindowRow(window: w)
            }

            if let err = state.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let t = state.fetchedAt {
                Text("取得: \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct WindowRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title).font(.subheadline)
                Spacer()
                Text("\(Int(window.utilization.rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(color)
            }
            ProgressView(value: min(window.utilization, 100), total: 100)
                .tint(color)
            if let r = window.resetsAt {
                Text("Resets \(Self.resetFormatter.string(from: r))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var color: Color {
        switch window.utilization {
        case ..<60: return .accentColor
        case ..<85: return .orange
        default: return .red
        }
    }

    private static let resetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d (E) HH:mm"
        return f
    }()
}
