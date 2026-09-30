import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var config: AppConfig
    @Published private(set) var states: [String: AccountState] = [:]

    private var timer: Timer?

    init() {
        config = AppConfig.load()
        start()
    }

    func start() {
        timer?.invalidate()
        refreshAll()
        let interval = TimeInterval(max(60, config.refreshSeconds))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    func reloadConfig() {
        config = AppConfig.load()
        states = [:]
        start()
    }

    func refreshAll() {
        for account in config.accounts {
            refresh(account)
        }
    }

    private func refresh(_ account: AccountConfig) {
        states[account.id, default: AccountState()].loading = true
        Task {
            do {
                let windows = try await UsageClient.fetch(account: account)
                states[account.id] = AccountState(windows: windows, fetchedAt: Date(), error: nil)
            } catch {
                // 失敗しても前回値は残す（古い値であることは fetchedAt で分かる）
                var s = states[account.id] ?? AccountState()
                s.error = error.localizedDescription
                s.loading = false
                states[account.id] = s
            }
        }
    }

    func state(for account: AccountConfig) -> AccountState {
        states[account.id] ?? AccountState()
    }

    /// メニューバー用: 各アカウントの利用上限枠のうち一番高い %
    func peak(for account: AccountConfig) -> Double? {
        state(for: account).windows.filter(\.isLimit).map(\.utilization).max()
    }

    var menuBarTitle: String {
        config.accounts.map { acc -> String in
            if let p = peak(for: acc) { return "\(acc.label) \(Int(p.rounded()))%" }
            return state(for: acc).error != nil ? "\(acc.label) !" : "\(acc.label) –"
        }.joined(separator: " · ")
    }
}
