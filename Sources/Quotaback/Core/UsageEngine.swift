import Foundation

/// Core of observing, recording and estimating. Used by both the UI (UsageStore) and `--once`.
actor UsageEngine {
    private(set) var log: ObservationLog
    /// Target → the account last observed (= currently logged in)
    private var liveByTarget: [String: AccountKey] = [:]
    /// Target → the last failure (the owner at that time and the message)
    private var errorByTarget: [String: (AccountKey, String)] = [:]
    /// Credential hash → the account it was last assigned to (in memory only)
    private var fingerprintOwner: [String: AccountKey] = [:]
    /// Hash that conflicts with its assignment → the newly claimed owner and when it was first seen
    private var conflicts: [String: (owner: AccountKey, since: Date)] = [:]
    /// Account → hash of the credentials its latest batch came from (to retract mix-ups)
    private var latestFingerprint: [AccountKey: String] = [:]

    /// How long a conflict must persist before it counts as a real owner change.
    /// Whichever of the owner info and the credentials `/login` writes first, both should be in place by then
    static let conflictSettle: TimeInterval = 30
    /// How long after an observation a logged-in account's value still counts as current (exact)
    static let freshness: TimeInterval = 10 * 60
    /// Target → the owner last checked and the mtime of its source (for switch detection)
    private var knownOwner: [String: String?] = [:]
    private var knownStamp: [String: Date?] = [:]

    init(log: ObservationLog) {
        self.log = log
    }

    enum Outcome {
        case recorded(ObservationBatch)
        /// Fetched, but not recorded because the owner couldn't be confirmed
        case skipped(String)
        case failed(String)
        /// The owner is known but there was no new observation
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

            // Avoid mix-ups during a login switch (the owner info and the credentials are updated separately)
            let after = t.owner()
            guard after == before else {
                knownOwner[t.id] = after
                liveByTarget[t.id] = nil
                return Report(target: t, owner: before, outcome: .skipped(L10n.ownerChanged(before ?? "?", after ?? "?")))
            }
            let at = now()
            if let fp = fetched.credentialFingerprint {
                if let prev = fingerprintOwner[fp], prev != key {
                    // The same credentials now claim a different owner. This may be mid-switch, so skip for now;
                    // if the pairing persists, accept the new owner (independent of write order)
                    guard let c = conflicts[fp], c.owner == key,
                          at.timeIntervalSince(c.since) >= Self.conflictSettle else {
                        if conflicts[fp]?.owner != key { conflicts[fp] = (key, at) }
                        liveByTarget[t.id] = nil
                        return Report(target: t, owner: before,
                                      outcome: .skipped(L10n.tokenBelongsTo(prev.account)))
                    }
                    // What was recorded for the previous owner was actually this account's → retract it
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
            // Logged in but no new value. The previous observation is stale, so it shows as a lower bound
            liveByTarget[t.id] = key
            errorByTarget[t.id] = nil
            return Report(target: t, owner: before, outcome: .unchanged(message))
        } catch {
            liveByTarget[t.id] = nil
            errorByTarget[t.id] = (key, error.localizedDescription)
            return Report(target: t, owner: before, outcome: .failed(error.localizedDescription))
        }
    }

    /// Targets whose source mtime changed and whose owner changed (= the login was switched)
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

    /// Menu bar text when there is neither emoji nor label: the first letter of the email, or "?" if the owner is unknown
    static func defaultLabel(for key: AccountKey) -> String {
        guard !key.account.hasPrefix("?"), let c = key.account.first else { return "?" }
        return String(c).uppercased()
    }

    /// The part of the email before @ (the whole string if there is no @)
    static func localPart(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@"), at != email.startIndex else { return email }
        return String(email[..<at])
    }

    /// Accounts observed so far (used to add them to config.json)
    var observedAccounts: [AccountKey] { log.latest.keys.sorted() }

    /// For display: configured accounts (in order) + accounts found through observations or errors
    func accountViews(config: [AccountConfig], now: Date = Date()) -> [AccountView] {
        let live = Set(liveByTarget.values)
        var errors: [AccountKey: String] = [:]
        for (key, msg) in errorByTarget.values { errors[key] = msg }

        var keys = config.map(\.key)
        let extra = Set(log.latest.keys).union(errors.keys).subtracting(keys).sorted()
        keys += extra

        // Without a label, the panel header is the part before @, or the full address if it collides with another email
        let localParts = Dictionary(grouping: Set(keys.map(\.account)), by: Self.localPart)

        return keys.map { key in
            let cfg = config.first { $0.key == key }
            let local = Self.localPart(key.account)
            let name = (localParts[local]?.count ?? 0) > 1 ? key.account : local
            let batch = log.latest[key]
            let isLive = live.contains(key)
            // Even when logged in, an old value (e.g. a past record read from logs) excludes later usage, so it is a lower bound
            let isFresh = isLive && batch.map { now.timeIntervalSince($0.observedAt) <= Self.freshness } ?? false
            let windows = (batch?.windows ?? []).map { w in
                Estimator.estimate(w, observedAt: batch!.observedAt, isLive: isFresh,
                                   history: log.points(account: key, window: w), now: now)
            }
            return AccountView(key: key,
                               label: cfg?.emoji ?? cfg?.label ?? Self.defaultLabel(for: key),
                               title: [cfg?.emoji, cfg?.label ?? name].compactMap { $0 }.joined(separator: " "),
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
    let label: String   // For the menu bar
    let title: String   // Panel header: emoji + label (or the part of the email before @ without a label)
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

    /// Representative window: the fullest usage-limit window (the menu bar % is this window's value).
    /// On a tie, the one resetting later (the slower one to recover is the binding constraint)
    var representative: WindowEstimate? {
        windows.filter(\.window.isLimit).max { a, b in
            if a.lowerBound != b.lowerBound { return a.lowerBound < b.lowerBound }
            return (a.window.resetsAt ?? .distantPast) < (b.window.resetsAt ?? .distantPast)
        }
    }

    /// For the menu bar: the maximum lower bound among usage-limit windows
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
