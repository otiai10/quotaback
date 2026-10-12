import Foundation

/// Where observations are stored.
/// - `latest.json`: the latest batch per account (overwritten each time, so freshness survives restarts)
/// - `observations.jsonl`: history appended only when values change (for pace projection; old entries are pruned)
/// - `cycles.jsonl`: one summary per closed reset cycle (for analytics; never pruned)
struct ObservationLog {
    private(set) var latest: [AccountKey: ObservationBatch] = [:]
    private(set) var history: [ObservationBatch] = []
    private(set) var cycles: [CycleSummary] = []

    let directory: URL
    static let retention: TimeInterval = 35 * 24 * 3600

    var latestURL: URL { directory.appendingPathComponent("latest.json") }
    var historyURL: URL { directory.appendingPathComponent("observations.jsonl") }
    var cyclesURL: URL { directory.appendingPathComponent("cycles.jsonl") }
    /// Legacy (Snapshot) store. Imported once
    var legacyURL: URL { directory.appendingPathComponent("state.json") }

    init(directory: URL = AppConfig.directory) {
        self.directory = directory
    }

    // MARK: - Load

    static func load(directory: URL = AppConfig.directory, now: Date = Date()) -> ObservationLog {
        var log = ObservationLog(directory: directory)
        if let data = try? Data(contentsOf: log.latestURL),
           let list = try? decoder.decode([ObservationBatch].self, from: data) {
            for b in list { log.latest[b.account] = b }
        } else {
            log.importLegacy()
        }
        log.loadCycles()
        if let text = try? String(contentsOf: log.historyURL, encoding: .utf8) {
            let all = text.split(separator: "\n").compactMap {
                try? decoder.decode(ObservationBatch.self, from: Data($0.utf8))
            }
            log.history = all.filter { now.timeIntervalSince($0.observedAt) < retention }
            // Summarize before pruning the file so that a cycle is summarized from all of its observations
            log.summarizeClosedCycles(in: all, now: now)
            if log.history.count != all.count { log.rewriteHistory() }
        } else {
            log.summarizeClosedCycles(in: [], now: now)
        }
        return log
    }

    /// Imports state.json (account email → Snapshot) as Claude observations
    private mutating func importLegacy() {
        struct LegacySnapshot: Decodable {
            struct Window: Decodable {
                var key: String; var title: String; var utilization: Double
                var resetsAt: Date?; var isLimit: Bool; var detail: String?
            }
            var windows: [Window]
            var fetchedAt: Date
        }
        guard let data = try? Data(contentsOf: legacyURL),
              let all = try? Self.decoder.decode([String: LegacySnapshot].self, from: data) else { return }
        for (email, snap) in all {
            let key = AccountKey(provider: ClaudeProvider.id, account: email)
            latest[key] = ObservationBatch(
                account: key, observedAt: snap.fetchedAt, source: "state.json",
                windows: snap.windows.map {
                    WindowObservation(key: $0.key, title: $0.title, percent: $0.utilization,
                                      resetsAt: $0.resetsAt, isLimit: $0.isLimit, detail: $0.detail,
                                      cadence: ClaudeProvider.cadence(forWindowKey: $0.key))
                })
        }
        saveLatest()
    }

    // MARK: - Record

    /// Records an observation. latest is always updated; history is appended only when values or reset times change.
    mutating func record(_ batch: ObservationBatch) {
        let previous = history.last { $0.account == batch.account } ?? latest[batch.account]
        let replaced = latest[batch.account]
        latest[batch.account] = batch
        saveLatest()
        if previous.map({ !Self.sameValues($0, batch) }) ?? true {
            history.append(batch)
            appendHistory(batch)
        }
        // The replaced latest may be the only record of its cycle's last observation (same values aren't appended)
        let replacedBatch = [replaced].compactMap { $0 }
        if hasUnsummarizedClosedCycle(latest.values + replacedBatch, now: batch.observedAt) {
            summarizeClosedCycles(in: history + replacedBatch, now: batch.observedAt)
        }
    }

    /// Retracts a latest batch recorded for the wrong account and falls back to the previous observation
    mutating func retractLatest(of account: AccountKey) {
        guard let bad = latest[account] else { return }
        retract(of: account, from: bad.observedAt, through: bad.observedAt)
    }

    /// Retracts every batch of an account observed in `from...through` (e.g. a run of polls recorded for the wrong account).
    /// If latest falls in that range, it falls back to the last history batch before `from`. History is only appended
    /// when values change, so that batch may be older than the last correct latest (same values, earlier time)
    mutating func retract(of account: AccountKey, from: Date, through: Date = .distantFuture) {
        let range = from...through
        let before = history.count
        history.removeAll { $0.account == account && range.contains($0.observedAt) }
        if history.count != before { rewriteHistory() }
        guard let current = latest[account], range.contains(current.observedAt) else { return }
        latest[account] = history.last { $0.account == account && $0.observedAt < from }
        saveLatest()
    }

    /// Same windows, values and reset times (to the minute) count as the same
    static func sameValues(_ a: ObservationBatch, _ b: ObservationBatch) -> Bool {
        guard a.windows.count == b.windows.count else { return false }
        return zip(a.windows, b.windows).allSatisfy { x, y in
            x.key == y.key && x.percent == y.percent && sameCycle(x.resetsAt, y.resetsAt)
        }
    }

    /// Whether it's the same reset period. resets_at jitters below a second between fetches, so compare by minute
    static func sameCycle(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x.timeIntervalSince(y)) < 60
        default: return false
        }
    }

    /// History of a window within the same reset period (oldest first), including the latest observation
    func points(account: AccountKey, window: WindowObservation) -> [(Date, Double)] {
        var pts: [(Date, Double)] = history.compactMap { b in
            guard b.account == account,
                  let w = b.windows.first(where: { $0.key == window.key }),
                  Self.sameCycle(w.resetsAt, window.resetsAt) else { return nil }
            return (b.observedAt, w.percent)
        }
        if let l = latest[account], let w = l.windows.first(where: { $0.key == window.key }),
           Self.sameCycle(w.resetsAt, window.resetsAt), pts.last?.0 != l.observedAt {
            pts.append((l.observedAt, w.percent))
        }
        return pts.sorted { $0.0 < $1.0 }
    }

    // MARK: - Cycles

    /// Appends a summary for every closed cycle that isn't summarized yet. A cycle is closed when a later cycle of the
    /// same window has been observed, or when `now` is past its resetsAt + 1 minute. The same code covers a new cycle
    /// being observed, time passing without observations, and backfill
    /// Cheap when nothing has closed: only the latest windows are checked before scanning the history
    mutating func summarizeClosedCycles(now: Date) {
        guard hasUnsummarizedClosedCycle(Array(latest.values), now: now) else { return }
        summarizeClosedCycles(in: history, now: now)
    }

    private mutating func summarizeClosedCycles(in batches: [ObservationBatch], now: Date) {
        let done = summarizedResets()
        let new = Self.closedCycles(in: batches + latest.values, now: now)
            .filter { s in !(done[s.windowID] ?? []).contains { Self.sameCycle($0, s.resetsAt) } }
        guard !new.isEmpty else { return }
        cycles += new
        appendCycles(new)
    }

    /// "account key" → reset times already summarized
    private func summarizedResets() -> [String: [Date]] {
        Dictionary(grouping: cycles, by: \.windowID).mapValues { $0.map(\.resetsAt) }
    }

    /// Whether a window in `batches` belongs to a closed cycle (past its reset, or no longer the latest one) that
    /// isn't summarized yet. A cycle normally closes through one of these windows, so the history needn't be scanned.
    /// A window that disappears from an account before its reset is only summarized at the next load
    private func hasUnsummarizedClosedCycle(_ batches: [ObservationBatch], now: Date) -> Bool {
        let done = summarizedResets()
        return batches.contains { b in
            b.windows.contains { w in
                guard let r = w.resetsAt else { return false }
                let current = latest[b.account]?.windows.first { $0.key == w.key }?.resetsAt
                let closed = r.addingTimeInterval(60) < now || !Self.sameCycle(current, r)
                return closed && !(done["\(b.account.id) \(w.key)"] ?? []).contains { Self.sameCycle($0, r) }
            }
        }
    }

    /// Recreates the summaries from the raw log (e.g. after fixing a mix-up in it). Summaries of cycles that
    /// started before the oldest retained observation can't be recreated, so they are kept. Returns the count
    mutating func rebuildCycles(now: Date = Date()) -> Int {
        let oldest = (history + latest.values).map(\.observedAt).min() ?? .distantFuture
        cycles.removeAll { $0.firstObservedAt >= oldest }
        rewriteCycles()
        summarizeClosedCycles(in: history, now: now)
        return cycles.count
    }

    /// Groups observations by account, window and reset cycle (`sameCycle`), and summarizes the closed ones.
    /// Windows without resetsAt (an unused session window) are skipped. `observations` counts distinct stored
    /// observation times (unchanged values aren't stored, so it's not the number of fetches)
    static func closedCycles(in batches: [ObservationBatch], now: Date) -> [CycleSummary] {
        struct Point { var at: Date; var window: WindowObservation; var resetsAt: Date }
        var groups: [String: (AccountKey, [Point])] = [:]
        var seen: [AccountKey: Set<Date>] = [:]
        for b in batches where seen[b.account, default: []].insert(b.observedAt).inserted {
            for w in b.windows {
                guard let r = w.resetsAt else { continue }
                groups["\(b.account.id) \(w.key)", default: (b.account, [])].1
                    .append(Point(at: b.observedAt, window: w, resetsAt: r))
            }
        }
        var result: [CycleSummary] = []
        for (account, points) in groups.values {
            // Sorted by reset time, one cycle is a run of reset times within a minute of each other
            var runs: [[Point]] = []
            for p in points.sorted(by: { ($0.resetsAt, $0.at) < ($1.resetsAt, $1.at) }) {
                if let prev = runs.last?.last, sameCycle(prev.resetsAt, p.resetsAt) {
                    runs[runs.count - 1].append(p)
                } else {
                    runs.append([p])
                }
            }
            for (i, run) in runs.enumerated() {
                let byTime = run.sorted { $0.at < $1.at }
                guard let first = byTime.first, let last = byTime.last,
                      i < runs.count - 1 || last.resetsAt.addingTimeInterval(60) < now else { continue }
                result.append(CycleSummary(
                    account: account, key: last.window.key, title: last.window.title, cadence: last.window.cadence,
                    resetsAt: last.resetsAt, firstObservedAt: first.at, lastObservedAt: last.at,
                    finalPercent: last.window.percent, peakPercent: run.map(\.window.percent).max() ?? 0,
                    observations: run.count))
            }
        }
        return result.sorted { ($0.resetsAt, $0.account, $0.key) < ($1.resetsAt, $1.account, $1.key) }
    }

    // MARK: - Files

    private func saveLatest() {
        let list = latest.values.sorted { $0.account < $1.account }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Self.encoder(pretty: true).encode(list) {
            try? data.write(to: latestURL, options: .atomic)
        }
    }

    private func appendHistory(_ batch: ObservationBatch) {
        guard var line = try? Self.encoder(pretty: false).encode(batch) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: historyURL) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: historyURL)
        }
    }

    /// Reads cycles.jsonl. Rows for the same cycle (e.g. written by both `--rebuild-cycles` and the app) keep the last
    private mutating func loadCycles() {
        guard let text = try? String(contentsOf: cyclesURL, encoding: .utf8) else { return }
        let all = text.split(separator: "\n").compactMap { try? Self.decoder.decode(CycleSummary.self, from: Data($0.utf8)) }
        var kept: [String: [Date]] = [:]
        for s in all.reversed() where !(kept[s.windowID] ?? []).contains(where: { Self.sameCycle($0, s.resetsAt) }) {
            kept[s.windowID, default: []].append(s.resetsAt)
            cycles.append(s)
        }
        cycles.reverse()
    }

    private func appendCycles(_ new: [CycleSummary]) {
        append(Self.lines(new), to: cyclesURL)
    }

    private func rewriteCycles() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Self.lines(cycles).write(to: cyclesURL, options: .atomic)
    }

    private func append(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func lines<T: Encodable>(_ items: [T]) -> Data {
        let enc = encoder(pretty: false)
        var data = Data()
        for item in items {
            if let line = try? enc.encode(item) { data.append(line); data.append(0x0A) }
        }
        return data
    }

    private func rewriteHistory() {
        let enc = Self.encoder(pretty: false)
        var data = Data()
        for b in history {
            if let line = try? enc.encode(b) { data.append(line); data.append(0x0A) }
        }
        try? data.write(to: historyURL, options: .atomic)
    }

    private static func encoder(pretty: Bool) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
