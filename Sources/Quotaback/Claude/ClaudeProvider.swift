import Foundation

/// Claude Code subscription usage limits (same as `/usage`)
struct ClaudeProvider: UsageProvider {
    static let id = "claude"

    func targets(config: AppConfig) -> [PollTarget] {
        config.effectiveSources(discovered: CredentialSource.discover()).map { source in
            PollTarget(
                provider: Self.id,
                id: source.id,
                description: source.description,
                owner: { source.ownerEmail() },
                ownerStamp: { source.ownerStamp() },
                fetch: {
                    let token = try source.accessToken()
                    let rawName = source.ownerEmail() ?? source.id
                    let data = try await UsageClient.fetch(token: token)
                    // Save before parsing: a response that fails to parse is exactly the one to look at
                    Self.saveRawResponse(data, name: rawName)
                    return FetchedUsage(windows: try UsageClient.parse(data),
                                        credentialFingerprint: CredentialSource.fingerprint(token))
                })
        }
    }

    /// Saves the raw response for debugging (the API is unofficial, so we can check when the format changes)
    private static func saveRawResponse(_ data: Data, name: String) {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let url = AppConfig.directory.appendingPathComponent("last-response-\(safe).json")
        try? data.write(to: url)
    }

    /// Decides the reset cadence from a stored window key (`limits[].kind[/scope]` or a legacy top-level key).
    /// Also used when importing the legacy `state.json`.
    static func cadence(forWindowKey key: String) -> Cadence {
        cadence(forKind: key.split(separator: "/").first.map(String.init) ?? key)
    }

    /// Decides the reset cadence from `limits[].kind` (or a legacy top-level key)
    static func cadence(forKind kind: String) -> Cadence {
        switch kind {
        case "session", "five_hour":
            return .rolling(5 * 3600)
        case "spend", "extra_usage":
            return .monthly
        default:
            if kind.hasPrefix("weekly") || kind.hasPrefix("seven_day") { return .fixed(7 * 24 * 3600) }
            return .unknown
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
