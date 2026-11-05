import Foundation

/// Claude Code subscription usage limits (same as `/usage`)
struct ClaudeProvider: UsageProvider {
    static let id = "claude"

    func targets(config: AppConfig) -> [PollTarget] {
        let files = RawResponseFiles()
        return config.effectiveSources(discovered: CredentialSource.discover()).map { source in
            PollTarget(
                provider: Self.id,
                id: source.id,
                description: source.description,
                owner: { source.ownerEmail() },
                ownerStamp: { source.ownerStamp() },
                fetch: {
                    let token = try source.accessToken()
                    let data = try await UsageClient.fetch(token: token, account: source.ownerEmail() ?? source.id)
                    return try Self.received(data, token: token, files: files)
                },
                rawResponses: files,
                credentialFingerprint: { (try? source.accessToken()).map(CredentialSource.fingerprint) })
        }
    }

    /// Keeps the response under a neutral name before parsing (a response that fails to parse is exactly
    /// the one to look at), then parses it. The account-named copy waits until the engine records it
    static func received(_ data: Data, token: String, files: RawResponseFiles) throws -> FetchedUsage {
        files.saveUnverified(data)
        return FetchedUsage(windows: try UsageClient.parse(data),
                            credentialFingerprint: CredentialSource.fingerprint(token),
                            raw: data)
    }

    /// Decides the reset cadence from a stored window key (`limits[].kind[/scope]`).
    /// The old `state.json` import also passes the legacy top-level keys (`five_hour` / `seven_day*` /
    /// `extra_usage`), which responses no longer provide, so they are mapped to their kinds here.
    static func cadence(forWindowKey key: String) -> Cadence {
        switch key {
        case "five_hour": return cadence(forKind: "session")
        case "extra_usage": return cadence(forKind: "spend")
        case _ where key.hasPrefix("seven_day"): return cadence(forKind: "weekly_all")
        default: return cadence(forKind: key.split(separator: "/").first.map(String.init) ?? key)
        }
    }

    /// Decides the reset cadence from `limits[].kind`
    static func cadence(forKind kind: String) -> Cadence {
        switch kind {
        case "session":
            return .rolling(5 * 3600)
        case "spend":
            return .monthly
        default:
            return kind.hasPrefix("weekly") ? .fixed(7 * 24 * 3600) : .unknown
        }
    }
}

extension CredentialSource {
    /// Modification time of the owner source (`.claude.json`)
    func ownerStamp() -> Date? {
        guard let path = resolvedProfilePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.modificationDate] as? Date
    }
}

/// Raw responses for debugging (the API is unofficial, so we can check when the format changes).
/// `last-response-unverified.json` is the latest response of any owner, including ones that were skipped
/// or failed to parse; `last-response-<email>.json` only holds responses recorded as that account's
struct RawResponseFiles: RawResponseStore {
    var directory = AppConfig.directory

    func url(for name: String) -> URL {
        directory.appendingPathComponent("last-response-\(name.replacingOccurrences(of: "/", with: "_")).json")
    }

    func saveUnverified(_ data: Data) {
        try? data.write(to: url(for: "unverified"))
    }

    func confirm(_ data: Data, account: String) {
        try? data.write(to: url(for: account))
    }

    func discard(account: String) {
        try? FileManager.default.removeItem(at: url(for: account))
    }
}
