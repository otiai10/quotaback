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
                    let windows = try await UsageClient.fetch(token: token,
                                                              rawName: source.ownerEmail() ?? source.id)
                    return FetchedUsage(windows: windows.map(Self.observation),
                                        credentialFingerprint: CredentialSource.fingerprint(token))
                })
        }
    }

    static func observation(_ w: UsageWindow) -> WindowObservation {
        WindowObservation(key: w.key, title: w.title, percent: w.utilization, resetsAt: w.resetsAt,
                          isLimit: w.isLimit, detail: w.detail, cadence: cadence(forWindowKey: w.key))
    }

    /// Decides the reset cadence from the window key (`limits[].kind[/scope]` or a legacy top-level key)
    static func cadence(forWindowKey key: String) -> Cadence {
        let kind = key.split(separator: "/").first.map(String.init) ?? key
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
