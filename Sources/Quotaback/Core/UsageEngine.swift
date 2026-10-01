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
    /// 割り当てと食い違ったハッシュ → 新しく名乗った持ち主と最初に見た時刻
    private var conflicts: [String: (owner: AccountKey, since: Date)] = [:]
    /// アカウント → 最新バッチを取ったときの認証情報のハッシュ（取り違えの取り消し用）
    private var latestFingerprint: [AccountKey: String] = [:]

    /// 食い違いを「本当の持ち主の変更」と認めるまでの時間。
    /// `/login` で持ち主の情報と認証情報のどちらが先に書かれても、この間に両方そろう想定
    static let conflictSettle: TimeInterval = 30
    /// ログイン中のアカウントの値を「今の値（exact）」とみなせる観測からの経過時間
    static let freshness: TimeInterval = 10 * 60
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
        /// 持ち主は分かったが新しい観測が無かった
        case unchanged(String)

        var summary: String {
            switch self {
            case .recorded(let b): return "recorded \(b.windows.map { "\($0.key)=\(Int($0.percent))" }.joined(separator: ","))"
            case .skipped(let m): return "skipped: \(m)"
            case .failed(let m): return "failed: \(m)"
            case .unchanged(let m): return "unchanged: \(m)"
            }
        }
    }

    struct Report {
        let target: PollTarget
        let owner: String?
        let outcome: Outcome
    }

    // MARK: - Refresh

    @discardableResult
    func refresh(_ targets: [PollTarget], reason: String = "",
                 now: @Sendable () -> Date = { Date() }) async -> [Report] {
        var reports: [Report] = []
        for t in targets {
            let r = await refresh(t, now: now)
            ActivityLog.write("refresh\(reason.isEmpty ? "" : "(\(reason))") \(t.description) owner=\(r.owner ?? "?") → \(r.outcome.summary)")
            reports.append(r)
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
            let at = now()
            if let fp = fetched.credentialFingerprint {
                if let prev = fingerprintOwner[fp], prev != key {
                    // 同じ認証情報が別の持ち主を名乗った。切り替え途中かもしれないので一旦見送り、
                    // しばらくしても同じ組み合わせなら新しい持ち主を正とする（書き込み順に依存しない）
                    guard let c = conflicts[fp], c.owner == key,
                          at.timeIntervalSince(c.since) >= Self.conflictSettle else {
                        if conflicts[fp]?.owner != key { conflicts[fp] = (key, at) }
                        liveByTarget[t.id] = nil
                        return Report(target: t, owner: before,
                                      outcome: .skipped("認証情報が \(prev.account) のものとして記録済み（切り替え途中の可能性）"))
                    }
                    // 前の持ち主に記録したのは実はこのアカウントの値だった → 取り消す
                    if latestFingerprint[prev] == fp {
                        log.retractLatest(of: prev)
                        latestFingerprint[prev] = nil
                    }
                    conflicts[fp] = nil
                }
                fingerprintOwner[fp] = key
                latestFingerprint[key] = fp
            }

            let batch = ObservationBatch(account: key, observedAt: fetched.asOf ?? at, source: t.description,
                                         windows: fetched.windows)
            log.record(batch)
            liveByTarget[t.id] = key
            errorByTarget[t.id] = nil
            return Report(target: t, owner: before, outcome: .recorded(batch))
        } catch UsageError.noObservation(let message) {
            // ログインはしているが新しい値が無い。前回の観測は古いので下限として出る
            liveByTarget[t.id] = key
            errorByTarget[t.id] = nil
            return Report(target: t, owner: before, outcome: .unchanged(message))
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
            if known != owner {
                ActivityLog.write("switch \(t.description) \(known ?? "?") → \(owner ?? "?")")
                return true
            }
            return false
        }
    }

    // MARK: - Views

    /// 設定に無いアカウントのラベル。メールの頭文字、持ち主不明なら "?"
    static func defaultLabel(for key: AccountKey) -> String {
        guard !key.account.hasPrefix("?"), let c = key.account.first else { return "?" }
        return String(c).uppercased()
    }

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
            // ログイン中でも、値そのものが古ければ（ログから読んだ過去の記録など）その後の使用は含まないので下限
            let isFresh = isLive && batch.map { now.timeIntervalSince($0.observedAt) <= Self.freshness } ?? false
            let windows = (batch?.windows ?? []).map { w in
                Estimator.estimate(w, observedAt: batch!.observedAt, isLive: isFresh,
                                   history: log.points(account: key, window: w), now: now)
            }
            return AccountView(key: key,
                               label: cfg?.label ?? Self.defaultLabel(for: key),
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

    var providerName: String {
        switch key.provider {
        case ClaudeProvider.id: return "Claude"
        case CodexProvider.id: return "Codex"
        default: return key.provider.capitalized
        }
    }

    /// 代表の枠: 利用上限枠のうち一番埋まっているもの（メニューバーの % はこの枠の値）。
    /// 同じ値ならリセットが遠い方（回復に時間がかかる方が効く制約なので）
    var representative: WindowEstimate? {
        windows.filter(\.window.isLimit).max { a, b in
            if a.lowerBound != b.lowerBound { return a.lowerBound < b.lowerBound }
            return (a.window.resetsAt ?? .distantPast) < (b.window.resetsAt ?? .distantPast)
        }
    }

    /// メニューバー用: 利用上限枠の下限値の最大
    var peak: Double? { representative?.lowerBound }

    var menuBarText: String {
        if let p = peak {
            let v = "\(Int(p.rounded()))%"
            if case .exact = representative?.value { return "\(label) \(v)" }
            return "\(label) ≥\(v)"
        }
        return error != nil ? "\(label) !" : "\(label) –"
    }
}
