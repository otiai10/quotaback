import Foundation
import SwiftUI

/// UI 用。観測・推定は UsageEngine に任せ、表示用の値を公開するだけ。
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var config: AppConfig
    @Published private(set) var accounts: [AccountView] = []
    @Published private(set) var refreshing = false

    private let engine = UsageEngine(log: ObservationLog.load())
    private var targets: [PollTarget] = []
    private var refreshTimer: Timer?
    private var watchTimer: Timer?
    private var pending = false

    /// ログイン切り替えの確認と、推定値の再計算（リセット時刻の通過など）の間隔
    static let watchInterval: TimeInterval = 15
    /// 切り替えを検知してから取得するまでの待ち（認証情報の書き込みが追いつくのを待つ）
    static let switchDebounce: UInt64 = 3_000_000_000

    init() {
        config = AppConfig.load()
        start()
    }

    func start() {
        targets = Providers.targets(config: config)
        refreshTimer?.invalidate()
        watchTimer?.invalidate()
        Task { await updateViews() }
        refreshAll()
        let interval = TimeInterval(max(60, config.refreshSeconds))
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
        watchTimer = Timer.scheduledTimer(withTimeInterval: Self.watchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.watch() }
        }
    }

    func reloadConfig() {
        config = AppConfig.load()
        start()
    }

    func refreshAll() {
        refresh(targets)
    }

    /// - Parameter retries: 切り替え途中で見送られた対象を取り直す残り回数
    private func refresh(_ list: [PollTarget], retries: Int = 2) {
        guard !list.isEmpty else { return }
        // 取得中に呼ばれたら、終わってからもう一度まとめて取る
        guard !refreshing else { pending = true; return }
        refreshing = true
        Task {
            let reports = await engine.refresh(list)
            await updateViews()
            refreshing = false
            if pending {
                pending = false
                refreshAll()
            }
            let skipped = reports.compactMap { r -> PollTarget? in
                if case .skipped = r.outcome { return r.target }
                return nil
            }
            if !skipped.isEmpty && retries > 0 {
                try? await Task.sleep(nanoseconds: UInt64((UsageEngine.conflictSettle + 5) * 1_000_000_000))
                refresh(skipped, retries: retries - 1)
            }
        }
    }

    /// ログインが切り替わった対象だけすぐ取りに行く
    private func watch() async {
        let changed = await engine.changedTargets(targets)
        if !changed.isEmpty {
            try? await Task.sleep(nanoseconds: Self.switchDebounce)
            refresh(changed)
        }
        await updateViews()
    }

    private func updateViews() async {
        accounts = await engine.accountViews(config: config.accounts)
    }

    var menuBarTitle: String {
        accounts.map(\.menuBarText).joined(separator: " · ")
    }
}
