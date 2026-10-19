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
                    let data = try await UsageClient.fetch(token: token, account: rawName)
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
