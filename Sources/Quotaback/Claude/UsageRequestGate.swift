import Foundation

/// 起動・パネル・手動更新を同じ入口で制限する。認証トークンは保存しない。
actor UsageRequestGate {
    static let shared = UsageRequestGate(url: AppConfig.directory.appendingPathComponent("usage-throttle.json"))
    static let minimumInterval: TimeInterval = 60

    private struct State: Codable {
        var nextByAccount: [String: Date] = [:]
        var blockedUntil: Date = .distantPast
        var consecutiveLimits = 0
    }

    private let url: URL
    private var state: State

    init(url: URL) {
        self.url = url
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: url))) ?? State()
    }

    func acquire(account: String, now: Date = Date()) throws {
        if state.blockedUntil > now {
            throw UsageError.deferred(state.blockedUntil, rateLimited: true)
        }
        if let next = state.nextByAccount[account], next > now {
            throw UsageError.deferred(next, rateLimited: false)
        }
        state.nextByAccount = state.nextByAccount.filter { $0.value > now }
        state.nextByAccount[account] = now.addingTimeInterval(Self.minimumInterval)
        save()
    }

    /// 429 はアカウントを切り替えても迂回しない。待機は 5 分から最大 30 分へ延ばす。
    func received(status: Int, retryAfter: String?, now: Date = Date()) -> Date? {
        if status == 429 {
            state.consecutiveLimits = min(state.consecutiveLimits + 1, 4)
            let delay = min(300 * pow(2, Double(state.consecutiveLimits - 1)), 1800)
            let serverDate = Self.retryDate(retryAfter, now: now) ?? now
            state.blockedUntil = max(state.blockedUntil, max(now.addingTimeInterval(delay), serverDate))
            save()
            return state.blockedUntil
        }
        if status == 200, state.blockedUntil <= now {
            state.consecutiveLimits = 0
            save()
        }
        return nil
    }

    static func retryDate(_ header: String?, now: Date) -> Date? {
        guard let header else { return nil }
        let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return format.date(from: value)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
        } catch {
            ActivityLog.write("使用量 API の待機状態を保存できません: \(error.localizedDescription)")
        }
    }
}
