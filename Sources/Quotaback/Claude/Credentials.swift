import Foundation
import CryptoKit

/// Where one Claude Code login's credentials live.
/// A location only holds the token of the account that logged in last.
struct CredentialSource: Codable, Hashable, Identifiable {
    var keychainService: String?   // e.g. "Claude Code-credentials"
    var credentialsPath: String?   // e.g. "~/.claude-work/.credentials.json"
    /// The `.claude.json` to read the owner's email from. Inferred from the location when omitted
    var profilePath: String?
    /// Manual override when `.claude.json` can't tell
    var email: String?

    static let defaultKeychain = CredentialSource(keychainService: "Claude Code-credentials")

    var id: String {
        if let s = keychainService { return "keychain:\(s)" }
        return "file:\((credentialsPath.map { ($0 as NSString).expandingTildeInPath }) ?? "")"
    }

    var description: String {
        if let s = keychainService { return "Keychain '\(s)'" }
        return credentialsPath ?? L10n.notSet
    }

    /// Location of the `.claude.json` that identifies the owner.
    /// - Default Keychain entry → `~/.claude.json`
    /// - `~/.claude/.credentials.json` → `~/.claude.json`
    /// - `<dir>/.credentials.json` → `<dir>/.claude.json` (when using a separate CLAUDE_CONFIG_DIR)
    var resolvedProfilePath: String? {
        if let p = profilePath { return (p as NSString).expandingTildeInPath }
        if keychainService == Self.defaultKeychain.keychainService {
            return (("~/.claude.json") as NSString).expandingTildeInPath
        }
        if let c = credentialsPath {
            let dir = ((c as NSString).expandingTildeInPath as NSString).deletingLastPathComponent
            // Only for the default ~/.claude does .claude.json live directly under home
            if dir == ("~/.claude" as NSString).expandingTildeInPath {
                return ("~/.claude.json" as NSString).expandingTildeInPath
            }
            return (dir as NSString).appendingPathComponent(".claude.json")
        }
        return nil
    }
}

extension AppConfig {
    /// Credential locations actually read
    func effectiveSources(discovered: [CredentialSource]) -> [CredentialSource] {
        let candidates: [CredentialSource]
        if let sources {
            candidates = sources
        } else {
            let legacy = accounts.compactMap { a -> CredentialSource? in
                // Ignore unfilled placeholders like "Claude Code-credentials-<SUFFIX>"
                if let s = a.keychainService, !s.contains("<") { return CredentialSource(keychainService: s) }
                if let c = a.credentialsPath { return CredentialSource(credentialsPath: c) }
                return nil
            }
            candidates = legacy + discovered
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted }
    }
}

/// Reading credentials (read-only; never refreshes)
extension CredentialSource {
    /// Finds credential locations on this machine (checks existence only; doesn't read contents)
    /// - The default Keychain entry
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

    /// Email of the account currently logged in at this location
    func ownerEmail() -> String? {
        if let email { return email.lowercased() }
        guard let path = resolvedProfilePath,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return Self.email(fromProfile: data)
    }

    /// `oauthAccount.emailAddress` in `.claude.json`
    static func email(fromProfile data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any],
              let email = account["emailAddress"] as? String, !email.isEmpty else { return nil }
        return email.lowercased()
    }

    /// Extracts accessToken from the credentials JSON that Claude Code stores.
    /// Expired tokens are not refreshed here (rotating the refresh token could
    /// break Claude Code's own login).
    func accessToken() throws -> String {
        let raw: Data
        if let service = keychainService {
            raw = try Self.readKeychain(service: service)
        } else if let path = credentialsPath {
            let expanded = (path as NSString).expandingTildeInPath
            guard let d = FileManager.default.contents(atPath: expanded) else {
                throw UsageError.credentials(L10n.notFound(path))
            }
            raw = d
        } else {
            throw UsageError.credentials(L10n.setKeychainOrPath)
        }

        guard let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw UsageError.credentials(L10n.accessTokenMissing)
        }
        if let expiresAt = oauth["expiresAt"] as? Double,
           Date(timeIntervalSince1970: expiresAt / 1000) < Date() {
            throw UsageError.tokenExpired
        }
        return token
    }

    /// Token hash (first 16 hex digits) for mix-up detection. Used in memory only, never stored
    static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads via the `security` command (the first read shows a Keychain access prompt;
    /// choose "Always Allow" and it won't appear again)
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
