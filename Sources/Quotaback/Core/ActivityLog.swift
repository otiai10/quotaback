import Foundation

/// Logs switch detection and fetch results to `~/.config/quotaback/activity.log` (never tokens).
/// So we can trace what happened when something didn't update automatically.
enum ActivityLog {
    static var url = AppConfig.directory.appendingPathComponent("activity.log")
    static let maxBytes = 512 * 1024
    private static let queue = DispatchQueue(label: "quotaback.activity-log")

    static func write(_ message: String, at date: Date = Date()) {
        let line = "\(stamp.string(from: date)) \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes,
               let data = try? Data(contentsOf: url) {
                // Drop the older half (advancing to the next newline so we don't start mid-line)
                var tail = data.suffix(maxBytes / 2)
                if let nl = tail.firstIndex(of: 0x0A) { tail = tail[tail.index(after: nl)...] }
                try? Data(tail).write(to: url, options: .atomic)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// For tests: waits for pending writes
    static func flush() { queue.sync {} }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()
}
