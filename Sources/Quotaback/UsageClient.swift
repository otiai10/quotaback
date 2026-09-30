import Foundation

enum UsageError: LocalizedError {
    case credentials(String)
    case tokenExpired
    case http(Int, String)
    case parse(String)

    var errorDescription: String? {
        switch self {
        case .credentials(let m): return "認証情報を読めません: \(m)"
        case .tokenExpired: return "トークン期限切れ（このアカウントで claude を一度起動すると更新されます）"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .parse(let m): return "レスポンス解析失敗: \(m)"
        }
    }
}

enum UsageClient {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"

    // MARK: - Credentials (読み取り専用。リフレッシュはしない)

    /// Claude Code が保存している credentials JSON から accessToken を取り出す。
    /// 期限切れの場合、ここで refresh はしない（refresh token のローテーションで
    /// Claude Code 側のログインを壊す可能性があるため）。
    static func accessToken(for account: AccountConfig) throws -> String {
        let raw: Data
        if let service = account.keychainService {
            raw = try readKeychain(service: service)
        } else if let path = account.credentialsPath {
            let expanded = (path as NSString).expandingTildeInPath
            guard let d = FileManager.default.contents(atPath: expanded) else {
                throw UsageError.credentials("\(path) が見つかりません")
            }
            raw = d
        } else {
            throw UsageError.credentials("keychainService か credentialsPath を設定してください")
        }

        guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw UsageError.credentials("claudeAiOauth.accessToken がありません")
        }
        if let expiresAt = oauth["expiresAt"] as? Double,
           Date(timeIntervalSince1970: expiresAt / 1000) < Date() {
            throw UsageError.tokenExpired
        }
        return token
    }

    /// `security` コマンド経由で読む（初回に Keychain のアクセス許可ダイアログが出る。
    /// 「常に許可」を選べば以降は出ない）
    private static func readKeychain(service: String) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UsageError.credentials("Keychain '\(service)': \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        var data = out.fileHandleForReading.readDataToEndOfFile()
        if data.last == 0x0A { data.removeLast() }
        return data
    }

    // MARK: - Fetch

    static func fetch(account: AccountConfig) async throws -> [UsageWindow] {
        let token = try accessToken(for: account)
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw UsageError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        saveRawResponse(data, label: account.label)
        return try parse(data)
    }

    /// デバッグ用に生レスポンスを保存（非公式APIなので形式が変わったときに確認できるように）
    private static func saveRawResponse(_ data: Data, label: String) {
        let url = AppConfig.directory.appendingPathComponent("last-response-\(label).json")
        try? data.write(to: url)
    }

    /// レスポンス形式を決め打ちしすぎないよう、
    /// 「utilization を持つオブジェクト」を全部枠として拾う。
    static func parse(_ data: Data) throws -> [UsageWindow] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.parse("トップレベルがオブジェクトではありません")
        }
        var windows: [UsageWindow] = []
        for (key, value) in root {
            guard let obj = value as? [String: Any],
                  let util = (obj["utilization"] as? NSNumber)?.doubleValue else { continue }
            windows.append(UsageWindow(key: key,
                                       utilization: util,
                                       resetsAt: parseDate(obj["resets_at"])))
        }
        return windows.sorted { order($0.key) < order($1.key) }
    }

    private static func order(_ key: String) -> Int {
        switch key {
        case "five_hour": return 0
        case "seven_day": return 1
        case _ where key.hasPrefix("seven_day_"): return 2
        default: return 9
        }
    }

    private static func parseDate(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
