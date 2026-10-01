import Foundation

/// 切り替えの検知や取得の結果を `~/.config/quotaback/activity.log` に残す（トークンは書かない）。
/// 「自動で反映されなかった」ときに何が起きていたかを後から追えるように。
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
                // 古い半分を捨てる（行の途中から始まらないよう次の改行まで進める）
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

    /// テスト用: 書き込みの完了を待つ
    static func flush() { queue.sync {} }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()
}
