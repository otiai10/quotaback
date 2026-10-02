import Foundation

/// Provider + account identifier. Used as the key for both storage and display.
struct AccountKey: Hashable, Codable, Comparable {
    var provider: String   // e.g. "claude"
    var account: String    // e.g. an email address (lowercased)

    var id: String { "\(provider):\(account)" }

    init(provider: String, account: String) {
        self.provider = provider
        self.account = account.lowercased()
    }

    init?(id: String) {
        guard let i = id.firstIndex(of: ":") else { return nil }
        self.init(provider: String(id[..<i]), account: String(id[id.index(after: i)...]))
    }

    static func < (a: AccountKey, b: AccountKey) -> Bool { a.id < b.id }
}

/// When a window resets. Decides whether the next reset can be projected.
enum Cadence: Codable, Hashable {
    /// Fixed period (weekly windows, etc.). The next reset is the past one plus the period
    case fixed(TimeInterval)
    /// Monthly (Usage credits, etc.)
    case monthly
    /// Counts from first use (the 5-hour session window, etc.). The next reset is unknown after a reset
    case rolling(TimeInterval)
    case unknown
}

/// One window's value from one observation. Display estimates are recomputed from it each time (only facts are stored).
struct WindowObservation: Codable, Hashable, Identifiable {
    var key: String
    var title: String
    var percent: Double
    var resetsAt: Date?
    var isLimit: Bool
    var detail: String?
    var cadence: Cadence

    var id: String { key }
}

/// The result of observing one account once. The latest batch defines which windows the account has now.
struct ObservationBatch: Codable, Hashable {
    var account: AccountKey
    var observedAt: Date
    /// Where it was observed from (e.g. "Keychain 'Claude Code-credentials'")
    var source: String
    var windows: [WindowObservation]
}
