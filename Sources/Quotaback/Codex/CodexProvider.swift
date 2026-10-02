import Foundation

/// OpenAI Codex CLI usage limits (the 5h limit / Weekly limit in `/status`).
///
/// Unlike Claude, no API calls. On every response Codex writes `rate_limits` to its session log
/// (`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`) as a `token_count` event,
/// so the latest record is read as an observation at that time. No tokens are used.
struct CodexProvider: UsageProvider {
    static let id = "codex"

    func targets(config: AppConfig) -> [PollTarget] {
        CodexHome.discover().map { home in
            PollTarget(
                provider: Self.id,
                id: "codex:\(home.url.path)",
                description: "Codex \(home.displayPath)",
                owner: { home.ownerEmail() },
                ownerStamp: { home.authStamp() },
                fetch: { try home.fetch() })
        }
    }
}

/// One Codex home directory (`~/.codex` by default, overridable with `$CODEX_HOME`)
struct CodexHome: Sendable {
    let url: URL

    var displayPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    var authURL: URL { url.appendingPathComponent("auth.json") }
    var sessionsURL: URL { url.appendingPathComponent("sessions") }

    static func discover(environment: [String: String] = ProcessInfo.processInfo.environment,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CodexHome] {
        var dirs: [URL] = []
        if let dir = environment["CODEX_HOME"], !dir.isEmpty {
            dirs.append(URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
        }
        dirs.append(home.appendingPathComponent(".codex"))
        var seen = Set<String>()
        return dirs
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("auth.json").path) }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .map { CodexHome(url: $0) }
    }

    // MARK: - Owner

    /// The `email` claim of `tokens.id_token` (a JWT) in `auth.json`. The signature isn't verified (only used to tell accounts apart)
    func ownerEmail() -> String? {
        guard let data = FileManager.default.contents(atPath: authURL.path) else { return nil }
        return Self.email(fromAuth: data)
    }

    static func email(fromAuth data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2, let payload = base64URLDecode(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let email = claims["email"] as? String, !email.isEmpty else { return nil }
        return email.lowercased()
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b)
    }

    func authStamp() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: authURL.path))?[.modificationDate] as? Date
    }

    // MARK: - Fetch

    func fetch() throws -> FetchedUsage {
        guard let event = CodexRolloutReader.latestRateLimits(sessions: sessionsURL) else {
            throw UsageError.noObservation(L10n.codexNoRecord)
        }
        // Logs don't say whose session they are. Records older than last_refresh in auth.json,
        // which is written on every login (and token refresh), may not be the current owner's, so skip them
        if let since = lastRefresh() ?? authStamp(), event.at < since {
            throw UsageError.noObservation(L10n.codexNoRecordSinceLogin)
        }
        return FetchedUsage(windows: event.windows, asOf: event.at)
    }

    private func lastRefresh() -> Date? {
        guard let data = FileManager.default.contents(atPath: authURL.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = json["last_refresh"] as? String else { return nil }
        return CodexRolloutReader.parseTimestamp(s)
    }
}
