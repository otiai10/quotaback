import Foundation

/// Core of observing, recording and estimating. Used by both the UI (UsageStore) and `--once`.
actor UsageEngine {
    private(set) var log: ObservationLog
    /// Target → the account last observed (= currently logged in)
    private var liveByTarget: [String: AccountKey] = [:]
    /// Target → the last failure (the owner at that time and the message)
    private var errorByTarget: [String: (AccountKey, String)] = [:]
    /// Targets the gate is holding back after a 429 (shown as an orange dot with the last value, not as an error)
    private var pausedByTarget: [String: (AccountKey, Date)] = [:]
    /// Credential hash → the account it was last assigned to (in memory only)
    private var fingerprintOwner: [String: AccountKey] = [:]
    /// Hash that conflicts with its assignment → the newly claimed owner and when it was first seen
    private var conflicts: [String: (owner: AccountKey, since: Date)] = [:]
    /// Account → hash of the credentials its latest batch came from, and when that hash was first recorded
    /// for it (to retract the whole run of a mix-up)
    private var latestFingerprint: [AccountKey: (fp: String, since: Date)] = [:]

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
        // Cycles of accounts that aren't logged in close by time alone
        log.summarizeClosedCycles(now: now())
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
            let observedAt = fetched.asOf ?? at
            if let fp = fetched.credentialFingerprint {
                // Credentials not yet tied to anyone (e.g. refreshed since last seen): if the weekly reset time is
                // another account's rather than this one's, they are probably still that account's. Not tied on skip
                if fingerprintOwner[fp] == nil, let other = foreignCycleOwner(fetched.windows, for: key, now: at) {
                    liveByTarget[t.id] = nil
                    return Report(target: t, owner: before, outcome: .skipped(L10n.resetMatchesOther(other.account)))
                }
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
                    // What was recorded for the previous owner with these credentials was actually this account's → retract it all
                    if let l = latestFingerprint[prev], l.fp == fp {
                        log.retract(of: prev, from: l.since)
                        latestFingerprint[prev] = nil
                    }
                    conflicts[fp] = nil
                }
                fingerprintOwner[fp] = key
                if latestFingerprint[key]?.fp != fp { latestFingerprint[key] = (fp, observedAt) }
            }

            let batch = ObservationBatch(account: key, observedAt: observedAt, source: t.description,
                                         windows: fetched.windows)
            log.record(batch)
            liveByTarget[t.id] = key
            errorByTarget[t.id] = nil
            pausedByTarget[t.id] = nil
            return Report(target: t, owner: before, outcome: .recorded(batch))
        } catch UsageError.deferred(let until, let limited) {
            // Waiting is not an auth failure: the state is kept only while the confirmed owner is the same
            if liveByTarget[t.id] != key { liveByTarget[t.id] = nil }
            if errorByTarget[t.id]?.0 != key { errorByTarget[t.id] = nil }
            if limited { pause(t, key, until) }
            return Report(target: t, owner: before, outcome: .unchanged(L10n.usageDeferred(until, rateLimited: limited)))
        } catch UsageError.rateLimited(let until, let retryAfter) {
            // The server said 429. Logged once here; the panel just shows the pause with the last value
            if liveByTarget[t.id] != key { liveByTarget[t.id] = nil }
            pause(t, key, until)
            return Report(target: t, owner: before, outcome: .unchanged(L10n.rateLimited(until, retryAfter: retryAfter)))
        } catch UsageError.noObservation(let message) {
            // Logged in but no new value. The previous observation is stale, so it shows as a lower bound
            liveByTarget[t.id] = key
            errorByTarget[t.id] = nil
            pausedByTarget[t.id] = nil
            return Report(target: t, owner: before, outcome: .unchanged(message))
        } catch {
            liveByTarget[t.id] = nil
            errorByTarget[t.id] = (key, error.localizedDescription)
            pausedByTarget[t.id] = nil
            return Report(target: t, owner: before, outcome: .failed(error.localizedDescription))
        }
    }

    /// A pause supersedes any earlier error for the target: the last value is shown with a quiet note instead
    private func pause(_ t: PollTarget, _ key: AccountKey, _ until: Date) {
        errorByTarget[t.id] = nil
        pausedByTarget[t.id] = (key, until)
    }

    /// Another account (same provider) whose next weekly reset the fetched windows share to the minute,
    /// while it differs from this account's own expected reset (projected over the cadence once passed).
    /// Windows this account has never observed are no evidence either way
    private func foreignCycleOwner(_ windows: [WindowObservation], for key: AccountKey, now: Date) -> AccountKey? {
        func expectedReset(_ account: AccountKey, _ w: WindowObservation) -> Date? {
            log.latest[account]?.windows.first { $0.key == w.key }.flatMap { Estimator.nextReset($0, now: now).date }
        }
        let others = log.latest.keys
            .filter { $0.provider == key.provider && $0 != key && !$0.account.hasPrefix("?") }
            .sorted()
        for w in windows {
            guard case .fixed = w.cadence, let r = w.resetsAt,
                  let mine = expectedReset(key, w), !ObservationLog.sameCycle(r, mine) else { continue }
            if let other = others.first(where: { o in
                expectedReset(o, w).map { ObservationLog.sameCycle(r, $0) } ?? false
            }) { return other }
        }
        return nil
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

    /// For the Analytics window: cycle summaries and the current cycle of logged-in accounts (`views` from `accountViews`)
    func analytics(views: [AccountView], now: Date = Date()) -> AnalyticsInput {
        AnalyticsInput(
            cycles: log.cycles,
            titles: Dictionary(views.map { ($0.key, $0.title) }, uniquingKeysWith: { a, _ in a }),
            live: views.filter(\.isLive).flatMap { v in
                v.windows.map { AnalyticsInput.LiveWindow(account: v.key, estimate: $0,
                                                          points: log.points(account: v.key, window: $0.window)) }
            },
            now: now)
    }

    /// Accounts observed so far (used to add them to config.json)
    var observedAccounts: [AccountKey] { log.latest.keys.sorted() }

    /// For display: configured accounts (in order) + accounts found through observations or errors
    func accountViews(config: [AccountConfig], now: Date = Date()) -> [AccountView] {
        let live = Set(liveByTarget.values)
        var errors: [AccountKey: String] = [:]
        for (key, msg) in errorByTarget.values { errors[key] = msg }
        // A pause that has already expired disappears on its own rather than lingering until the next tick
        var paused: [AccountKey: Date] = [:]
        for (key, until) in pausedByTarget.values where until > now { paused[key] = until }

        var keys = config.map(\.key)
        let extra = Set(log.latest.keys).union(errors.keys).union(paused.keys).subtracting(keys).sorted()
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
                               windows: windows,
                               pausedUntil: paused[key])
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
    /// Set while the gate is holding back after a 429: the windows above are the last value, the login dot turns orange
    var pausedUntil: Date? = nil

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
