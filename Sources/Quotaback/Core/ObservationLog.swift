import Foundation

/// Where observations are stored.
/// - `latest.json`: the latest batch per account (overwritten each time, so freshness survives restarts)
/// - `observations.jsonl`: history appended only when values change (for pace projection; old entries are pruned)
struct ObservationLog {
    private(set) var latest: [AccountKey: ObservationBatch] = [:]
    private(set) var history: [ObservationBatch] = []

    let directory: URL
    static let retention: TimeInterval = 35 * 24 * 3600

    var latestURL: URL { directory.appendingPathComponent("latest.json") }
    var historyURL: URL { directory.appendingPathComponent("observations.jsonl") }
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
        if let text = try? String(contentsOf: log.historyURL, encoding: .utf8) {
            let all = text.split(separator: "\n").compactMap {
                try? decoder.decode(ObservationBatch.self, from: Data($0.utf8))
            }
            log.history = all.filter { now.timeIntervalSince($0.observedAt) < retention }
            if log.history.count != all.count { log.rewriteHistory() }
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
        latest[batch.account] = batch
        saveLatest()
        if previous.map({ !Self.sameValues($0, batch) }) ?? true {
            history.append(batch)
            appendHistory(batch)
        }
    }

    /// Retracts a latest batch recorded for the wrong account and falls back to the previous observation
    mutating func retractLatest(of account: AccountKey) {
        guard let bad = latest[account] else { return }
        let before = history.count
        history.removeAll { $0.account == account && $0.observedAt == bad.observedAt }
        if history.count != before { rewriteHistory() }
        latest[account] = history.last { $0.account == account && $0.observedAt < bad.observedAt }
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
