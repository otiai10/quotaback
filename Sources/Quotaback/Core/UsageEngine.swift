import Foundation

/// 観測・記録・推定の本体。UI（UsageStore）と `--once` の両方から使う。
actor UsageEngine {
    private(set) var log: ObservationLog
    /// 対象 → 直近に観測できたアカウント（= いまログイン中）
    private var liveByTarget: [String: AccountKey] = [:]
    /// 対象 → 直近の失敗（その時点の持ち主とメッセージ）
    private var errorByTarget: [String: (AccountKey, String)] = [:]
    /// 認証情報のハッシュ → それを最後に割り当てたアカウント（メモリ上のみ）
    private var fingerprintOwner: [String: AccountKey] = [:]
    /// 対象 → 前回確認した持ち主と判定元の更新時刻（切り替え検知用）
    private var knownOwner: [String: String?] = [:]
    private var knownStamp: [String: Date?] = [:]

    init(log: ObservationLog) {
        self.log = log
    }

    enum Outcome {
        case recorded(ObservationBatch)
        /// 取得はできたが、持ち主が確定できないので記録しなかった
        case skipped(String)
        case failed(String)
    }

    struct Report {
        let target: PollTarget
        let owner: String?
        let outcome: Outcome
    }

    // MARK: - Refresh

    @discardableResult
    func refresh(_ targets: [PollTarget], now: @Sendable () -> Date = { Date() }) async -> [Report] {
        var reports: [Report] = []
        for t in targets {
            reports.append(await refresh(t, now: now))
        }
        return reports
    }

    private func refresh(_ t: PollTarget, now: () -> Date) async -> Report {
        knownStamp[t.id] = t.ownerStamp()
        let before = t.owner()
        knownOwner[t.id] = before
        let key = AccountKey(provider: t.provider, account: before ?? "?\(t.description)")

        do {
            let fetched = try await t.fetch()

            // ログイン切り替え中（持ち主の情報と認証情報は別々に更新される）の取り違えを防ぐ
            let after = t.owner()
            guard after == before else {
                knownOwner[t.id] = after
                liveByTarget[t.id] = nil
                return Report(target: t, owner: before, outcome: .skipped("取得中に持ち主が変わった（\(before ?? "?") → \(after ?? "?")）"))
            }
            if let fp = fetched.credentialFingerprint {
                if let prev = fingerprintOwner[fp], prev != key {
                    liveByTarget[t.id] = nil
                    return Report(target: t, owner: before, outcome: .skipped("認証情報がまだ \(prev.account) のもの（切り替え途中）"))
                }
                fingerprintOwner[fp] = key
            }

            let batch = ObservationBatch(account: key, observedAt: now(), source: t.description,
                                         windows: fetched.windows)
            log.record(batch)
            liveByTarget[t.id] = key
            errorByTarget[t.id] = nil
            return Report(target: t, owner: before, outcome: .recorded(batch))
        } catch {
            liveByTarget[t.id] = nil
            errorByTarget[t.id] = (key, error.localizedDescription)
            return Report(target: t, owner: before, outcome: .failed(error.localizedDescription))
        }
    }

    /// 判定元の更新時刻が変わり、かつ持ち主が変わった対象（＝ログインが切り替わった）
    func changedTargets(_ targets: [PollTarget]) -> [PollTarget] {
        targets.filter { t in
            let stamp = t.ownerStamp()
            if let known = knownStamp[t.id], known == stamp { return false }
            knownStamp[t.id] = stamp
            let owner = t.owner()
            defer { knownOwner[t.id] = owner }
            guard let known = knownOwner[t.id] else { return true }
            return known != owner
        }
    }

    // MARK: - Views

    /// 表示用。設定にあるアカウント（順序どおり）＋観測やエラーで見つかったアカウント
    func accountViews(config: [AccountConfig], now: Date = Date()) -> [AccountView] {
        let live = Set(liveByTarget.values)
        var errors: [AccountKey: String] = [:]
        for (key, msg) in errorByTarget.values { errors[key] = msg }

        var keys = config.map(\.key)
        let extra = Set(log.latest.keys).union(errors.keys).subtracting(keys).sorted()
        keys += extra

        return keys.map { key in
            let cfg = config.first { $0.key == key }
            let batch = log.latest[key]
            let isLive = live.contains(key)
            let windows = (batch?.windows ?? []).map { w in
                Estimator.estimate(w, observedAt: batch!.observedAt, isLive: isLive,
                                   history: log.points(account: key, window: w), now: now)
            }
            return AccountView(key: key,
                               label: cfg?.label ?? "?",
                               name: cfg?.name ?? key.account,
                               isLive: isLive,
                               observedAt: batch?.observedAt,
                               source: batch?.source,
                               error: errors[key],
                               windows: windows)
        }
    }
}

struct AccountView: Identifiable, Hashable {
    let key: AccountKey
    let label: String
    let name: String
    let isLive: Bool
    let observedAt: Date?
    let source: String?
    let error: String?
    let windows: [WindowEstimate]

    var id: String { key.id }

    /// メニューバー用: 利用上限枠の下限値の最大
    var peak: Double? {
        windows.filter(\.window.isLimit).map(\.lowerBound).max()
    }

    var menuBarText: String {
        if let p = peak {
            let v = "\(Int(p.rounded()))%"
            return isLive ? "\(label) \(v)" : "\(label) ≥\(v)"
        }
        return error != nil ? "\(label) !" : "\(label) –"
    }
}
