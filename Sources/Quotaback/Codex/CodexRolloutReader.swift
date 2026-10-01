import Foundation

/// Codex のセッションログから最新の `rate_limits` を読む。
///
/// 形式（codex-cli 0.147 で確認）:
/// ```
/// {"timestamp":"2026-10-01T09:26:48.152Z","type":"event_msg","payload":{"type":"token_count",
///   "rate_limits":{"primary":{"used_percent":3.0,"window_minutes":10080,"resets_at":1791125902},
///                  "secondary":null, ...}}}
/// ```
/// 古い版では `resets_at` の代わりに `resets_in_seconds`（記録時刻からの秒数）が入る。
enum CodexRolloutReader {
    struct Event {
        let at: Date
        let windows: [WindowObservation]
    }

    /// 新しいログから順に見て、最初に見つかった記録を返す。ログは大きいので末尾だけ読む
    static func latestRateLimits(sessions: URL, maxFiles: Int = 20, tailBytes: Int = 1 << 20) -> Event? {
        for file in recentRollouts(in: sessions).prefix(maxFiles) {
            guard let data = readTail(of: file, bytes: tailBytes),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
                if let event = parse(line: Data(line.utf8)) { return event }
            }
        }
        return nil
    }

    static func parse(line: Data) -> Event? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let ts = obj["timestamp"] as? String, let at = parseTimestamp(ts),
              let payload = obj["payload"] as? [String: Any],
              let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        let windows = ["primary", "secondary"].compactMap { slot -> WindowObservation? in
            guard let w = limits[slot] as? [String: Any],
                  let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (w["window_minutes"] as? NSNumber)?.intValue
            let resetsAt: Date?
            if let epoch = (w["resets_at"] as? NSNumber)?.doubleValue {
                resetsAt = Date(timeIntervalSince1970: epoch)
            } else if let secs = (w["resets_in_seconds"] as? NSNumber)?.doubleValue {
                resetsAt = at.addingTimeInterval(secs)
            } else {
                resetsAt = nil
            }
            return window(minutes: minutes, slot: slot, percent: used,
                          resetsAt: resetsAt.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded() * 60) })
        }
        guard !windows.isEmpty else { return nil }
        return Event(at: at, windows: windows.sorted { ($0.cadenceSeconds ?? 0) < ($1.cadenceSeconds ?? 0) })
    }

    /// 枠は primary / secondary の位置ではなく長さで区別する（プランや版で入れ替わるため）
    static func window(minutes: Int?, slot: String, percent: Double, resetsAt: Date?) -> WindowObservation {
        let key = minutes.map { "window_\($0)m" } ?? slot
        let title: String
        let cadence: Cadence
        switch minutes {
        case 300?:
            title = "5h limit"
            cadence = .rolling(5 * 3600)
        case 10080?:
            title = "Weekly limit"
            cadence = .fixed(7 * 24 * 3600)
        case let m?:
            title = m % 1440 == 0 ? "\(m / 1440)d limit" : m % 60 == 0 ? "\(m / 60)h limit" : "\(m)m limit"
            cadence = .rolling(TimeInterval(m * 60))
        case nil:
            title = slot.capitalized + " limit"
            cadence = .unknown
        }
        return WindowObservation(key: key, title: title, percent: percent, resetsAt: resetsAt,
                                 isLimit: true, detail: nil, cadence: cadence)
    }

    /// `sessions/YYYY/MM/DD/rollout-*.jsonl` を新しい順に。日付ディレクトリは名前順で新しいものから辿る
    static func recentRollouts(in sessions: URL, limit: Int = 20) -> [URL] {
        let fm = FileManager.default
        func children(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        var files: [URL] = []
        outer: for y in children(sessions) {
            for m in children(y) {
                for d in children(m) {
                    let rollouts = children(d).filter {
                        $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl"
                    }
                    files += rollouts.sorted { mtime($0) > mtime($1) }
                    if files.count >= limit { break outer }
                }
            }
        }
        return Array(files.prefix(limit))
    }

    private static func mtime(_ url: URL) -> Date {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
    }

    private static func readTail(of url: URL, bytes: Int) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        guard var data = try? h.readToEnd() else { return nil }
        // 途中から読んだら最初の（欠けた）行を捨てる
        if start > 0, let nl = data.firstIndex(of: 0x0A) { data = data[data.index(after: nl)...] }
        return Data(data)
    }

    static func parseTimestamp(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

private extension WindowObservation {
    var cadenceSeconds: TimeInterval? {
        switch cadence {
        case .fixed(let t), .rolling(let t): return t
        case .monthly: return 30 * 24 * 3600
        case .unknown: return nil
        }
    }
}
