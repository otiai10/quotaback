import Foundation

/// An account to show. Which credentials belong to whom is decided at runtime (for Claude, the email in `.claude.json`).
struct AccountConfig: Codable, Identifiable, Hashable {
    var email: String              // Account identifier (an email address for both Claude and Codex)
    /// Short mark shown in the menu bar (e.g. "🏈"). Prefixes the header in the panel
    var emoji: String?
    /// Display name (e.g. "Personal"). Shown in the panel instead of the email; also in the menu bar if there is no emoji
    var label: String?
    /// Defaults to "claude"
    var provider: String?
    // Legacy format. If set, treated as a Claude credential location (CredentialSource)
    var keychainService: String?
    var credentialsPath: String?

    init(email: String, emoji: String? = nil, label: String? = nil, provider: String? = nil,
         keychainService: String? = nil, credentialsPath: String? = nil) {
        self.email = email
        self.emoji = emoji
        self.label = label
        self.provider = provider
        self.keychainService = keychainService
        self.credentialsPath = credentialsPath
    }

    var key: AccountKey { AccountKey(provider: provider ?? ClaudeProvider.id, account: email) }
    var id: String { key.id }

    private enum CodingKeys: String, CodingKey {
        case email, emoji, label, provider, keychainService, credentialsPath
        case name   // Legacy key: same as email
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let email = try c.decodeIfPresent(String.self, forKey: .email) {
            self.email = email
        } else {
            self.email = try c.decode(String.self, forKey: .name)
        }
        // An empty string means unset
        emoji = try c.decodeIfPresent(String.self, forKey: .emoji).flatMap { $0.isEmpty ? nil : $0 }
        label = try c.decodeIfPresent(String.self, forKey: .label).flatMap { $0.isEmpty ? nil : $0 }
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        keychainService = try c.decodeIfPresent(String.self, forKey: .keychainService)
        credentialsPath = try c.decodeIfPresent(String.self, forKey: .credentialsPath)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(email, forKey: .email)
        try c.encodeIfPresent(emoji, forKey: .emoji)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(provider, forKey: .provider)
        try c.encodeIfPresent(keychainService, forKey: .keychainService)
        try c.encodeIfPresent(credentialsPath, forKey: .credentialsPath)
    }
}

struct AppConfig: Codable, Equatable {
    /// Display language, "en" or "ja". Defaults to English
    var language: String?
    var refreshSeconds: Int
    var accounts: [AccountConfig]
    /// Claude credential locations. If omitted, legacy entries in accounts[] plus auto-discovery (`CredentialSource.discover()`)
    var sources: [CredentialSource]?

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quotaback", isDirectory: true)
    static let path = directory.appendingPathComponent("config.json")

    static let fallback = AppConfig(
        refreshSeconds: 300,
        // Observed accounts are appended automatically
        accounts: []
    )

    /// Reads the config file. If it doesn't exist, writes the default and returns it.
    static func load() -> AppConfig {
        if case .success(let cfg) = read() { return cfg }
        if !FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? enc.encode(fallback) { try? data.write(to: path) }
        }
        return fallback
    }

    /// Reads the config file. Fails if it is missing or broken (so a typo mid-edit doesn't wipe the settings)
    static func read(from url: URL = path) -> Result<AppConfig, Error> {
        Result {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        }
    }

    /// Whether a change needs a refetch (sources or interval changed). Not for label-only changes
    func needsRefetch(comparedTo other: AppConfig) -> Bool {
        refreshSeconds != other.refreshSeconds
            || effectiveSources(discovered: []) != other.effectiveSources(discovered: [])
            || accounts.map(\.key) != other.accounts.map(\.key)
    }

    /// This config with observed accounts that are missing from it appended. nil if nothing to add.
    /// emoji and label are left out (the panel shows the email). Unknown owners (starting with "?") are skipped
    func addingAccounts(_ keys: [AccountKey]) -> AppConfig? {
        let existing = Set(accounts.map(\.key))
        let missing = Set(keys).subtracting(existing)
            .filter { !$0.account.isEmpty && !$0.account.hasPrefix("?") }
            .sorted()
        guard !missing.isEmpty else { return nil }
        var new = self
        new.accounts += missing.map { key in
            AccountConfig(email: key.account,
                          provider: key.provider == ClaudeProvider.id ? nil : key.provider)
        }
        return new
    }

    /// Appends observed accounts to config.json. Returns the new config if anything was added.
    /// Re-reads the file right before and appends to it (keeping user edits). Leaves it alone if it can't be read
    static func registerAccounts(_ keys: [AccountKey], at url: URL = path) -> AppConfig? {
        guard case .success(let current) = read(from: url),
              let new = current.addingAccounts(keys) else { return nil }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(new), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return new
    }

    static func modificationDate(of url: URL = path) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
