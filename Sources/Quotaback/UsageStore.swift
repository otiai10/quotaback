import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var config: AppConfig
    /// key: AccountConfig.id（メールアドレスの小文字）
    @Published private(set) var states: [String: AccountState] = [:]
    /// 設定に無いアカウント、または持ち主が分からない置き場所
    @Published private(set) var unknownAccounts: [AccountConfig] = []
    @Published private(set) var refreshing = false

    private var snapshots: [String: Snapshot]
    private var timer: Timer?

    init() {
        config = AppConfig.load()
        snapshots = Snapshot.loadAll()
        restoreSnapshots()
        start()
    }

    var accounts: [AccountConfig] { config.accounts + unknownAccounts }

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
        unknownAccounts = []
        restoreSnapshots()
        start()
    }

    /// 前回保存した値を「未ログイン」扱いで並べておく（取得できたものから上書きされる）
    private func restoreSnapshots() {
        states = snapshots.mapValues { AccountState(windows: $0.windows, fetchedAt: $0.fetchedAt) }
        for id in snapshots.keys where !config.accounts.contains(where: { $0.id == id }) {
            unknownAccounts.append(AccountConfig(label: "?", name: id))
        }
    }

    func refreshAll() {
        guard !refreshing else { return }
        refreshing = true
        for a in accounts { states[a.id, default: AccountState()].loading = true }
        let sources = config.effectiveSources(discovered: CredentialSource.discover())

        Task {
            var succeeded = Set<String>()
            var touched = Set<String>()
            for source in sources {
                let r = await UsageClient.poll(source)
                let account = account(for: r)
                touched.insert(account.id)
                switch r.result {
                case .success(let windows):
                    let now = Date()
                    succeeded.insert(account.id)
                    states[account.id] = AccountState(windows: windows, fetchedAt: now, isCurrent: true)
                    snapshots[account.id] = Snapshot(windows: windows, fetchedAt: now)
                case .failure(let error):
                    // 同じアカウントを別の置き場所から取れていればエラーで上書きしない
                    guard !succeeded.contains(account.id) else { continue }
                    // 失敗しても前回値は残す（古い値であることは fetchedAt で分かる）
                    var s = states[account.id] ?? AccountState()
                    s.error = error.localizedDescription
                    s.loading = false
                    s.isCurrent = false
                    states[account.id] = s
                }
            }
            // どの置き場所にもログインしていないアカウントは前回値のまま
            for a in accounts where !touched.contains(a.id) {
                states[a.id, default: AccountState()].loading = false
                states[a.id]?.isCurrent = false
                states[a.id]?.error = nil
            }
            Snapshot.saveAll(snapshots)
            refreshing = false
        }
    }

    /// 取得結果をどのアカウントに割り当てるか。設定に無ければ "?" として追加する
    private func account(for r: UsageClient.SourceResult) -> AccountConfig {
        let id = r.email ?? r.source.description
        if let a = accounts.first(where: { $0.id == id.lowercased() }) { return a }
        let a = AccountConfig(label: "?", name: id)
        unknownAccounts.append(a)
        return a
    }

    func state(for account: AccountConfig) -> AccountState {
        states[account.id] ?? AccountState()
    }

    /// メニューバー用: 各アカウントの利用上限枠のうち一番高い %（リセット済みの枠は 0 扱い）
    func peak(for account: AccountConfig) -> Double? {
        state(for: account).windows.filter(\.isLimit)
            .map { $0.isReset() ? 0 : $0.utilization }
            .max()
    }

    var menuBarTitle: String {
        accounts.map { acc -> String in
            let s = state(for: acc)
            if let p = peak(for: acc) {
                let v = "\(Int(p.rounded()))%"
                // ログインしていないアカウントは前回値を括弧付きで
                return s.isCurrent ? "\(acc.label) \(v)" : "\(acc.label) (\(v))"
            }
            return s.error != nil ? "\(acc.label) !" : "\(acc.label) –"
        }.joined(separator: " · ")
    }
}
