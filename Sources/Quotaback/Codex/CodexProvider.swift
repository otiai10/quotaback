import Foundation

/// OpenAI Codex CLI の利用上限（`/status` の 5h limit / Weekly limit）。
///
/// Claude と違い API は呼ばない。Codex は応答のたびにセッションログ
/// (`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`) に `token_count` イベントとして
/// `rate_limits` を書くので、その最新の記録を「その時刻の観測」として読む。トークンは使わない。
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

/// Codex の設定ディレクトリ（既定 `~/.codex`、`$CODEX_HOME` で変更可）1つ分
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

    /// `auth.json` の `tokens.id_token`（JWT）の `email` クレーム。署名は検証しない（表示用の判定だけ）
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
            throw UsageError.noObservation("Codex のセッションログに利用上限の記録がありません（codex を一度使うと記録されます）")
        }
        // ログには誰のセッションかが書かれていない。ログイン（とトークン更新）のたびに書かれる
        // auth.json の last_refresh より前の記録は、今の持ち主のものとは限らないので使わない
        if let since = lastRefresh() ?? authStamp(), event.at < since {
            throw UsageError.noObservation("ログイン後の Codex の記録がまだありません（codex を一度使うと記録されます）")
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
