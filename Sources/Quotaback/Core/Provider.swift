import Foundation

/// A usage source (provider): Claude or Codex.
protocol UsageProvider {
    /// Lists the targets to observe (credential locations) from the config
    func targets(config: AppConfig) -> [PollTarget]
}

enum Providers {
    static let all: [UsageProvider] = [ClaudeProvider(), CodexProvider()]

    static func targets(config: AppConfig) -> [PollTarget] {
        all.flatMap { $0.targets(config: config) }
    }
}

/// One observation target (e.g. a Keychain entry). It is assumed to hold
/// only the account that is logged in at that moment.
struct PollTarget: @unchecked Sendable {
    let provider: String
    let id: String
    let description: String
    /// Current owner (account identifier). Must be cheap to read, without network or Keychain access
    let owner: @Sendable () -> String?
    /// Modification time of the owner source. Used to detect login switches (owner is re-read when it changes)
    let ownerStamp: @Sendable () -> Date?
    let fetch: @Sendable () async throws -> FetchedUsage
}

struct FetchedUsage {
    var windows: [WindowObservation]
    /// Hash of the credentials used (kept in memory only, never stored)
    var credentialFingerprint: String? = nil
    /// When the values are from. nil if just fetched from the API (= fetch time).
    /// For past values read from logs etc., the time they were recorded
    var asOf: Date? = nil
}
