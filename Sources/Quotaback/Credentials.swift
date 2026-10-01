import Foundation

/// 認証情報の読み取り（読み取り専用。リフレッシュはしない）
extension CredentialSource {
    /// このマシンにある認証情報の置き場所を探す（存在確認だけで中身は読まない）
    /// - 既定の Keychain エントリ
    /// - `$CLAUDE_CONFIG_DIR/.credentials.json`
    /// - `~/.claude*/.credentials.json`
    static func discover(environment: [String: String] = ProcessInfo.processInfo.environment,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [CredentialSource] {
        let fm = FileManager.default
        var found = [defaultKeychain]
        var dirs: [URL] = []
        if let dir = environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            dirs.append(URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
        }
        let entries = (try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        dirs += entries.filter { $0.lastPathComponent.hasPrefix(".claude") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in dirs {
            let file = dir.appendingPathComponent(".credentials.json")
            if fm.fileExists(atPath: file.path) {
                found.append(CredentialSource(credentialsPath: file.path))
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }
    }

    /// この置き場所に今ログインしているアカウントのメールアドレス
    func ownerEmail() -> String? {
        if let email { return email.lowercased() }
        guard let path = resolvedProfilePath,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return Self.email(fromProfile: data)
    }

    /// `.claude.json` の `oauthAccount.emailAddress`
    static func email(fromProfile data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String, !email.isEmpty else { return nil }
        return email.lowercased()
    }

    /// Claude Code が保存している credentials JSON から accessToken を取り出す。
    /// 期限切れの場合、ここで refresh はしない（refresh token のローテーションで
    /// Claude Code 側のログインを壊す可能性があるため）。
    func accessToken() throws -> String {
        let raw: Data
        if let service = keychainService {
            raw = try Self.readKeychain(service: service)
        } else if let path = credentialsPath {
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
}
