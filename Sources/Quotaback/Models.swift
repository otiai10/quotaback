import Foundation

/// 表示するアカウント。どの認証情報が誰のものかは実行時に判定する（Claude なら `.claude.json` のメールアドレス）。
struct AccountConfig: Codable, Identifiable, Hashable {
    var label: String              // メニューバーに出す短いラベル (例: "P", "W")
    var name: String               // アカウント識別子。Claude ならメールアドレス
    /// 省略時は "claude"
    var provider: String?
    // 旧形式の互換用。指定されていれば Claude の認証情報の置き場所 (CredentialSource) として扱う
    var keychainService: String?
    var credentialsPath: String?

    var key: AccountKey { AccountKey(provider: provider ?? ClaudeProvider.id, account: name) }
    var id: String { key.id }
}

struct AppConfig: Codable, Equatable {
    var refreshSeconds: Int
    var accounts: [AccountConfig]
    /// Claude の認証情報の置き場所。省略時は accounts[] の旧形式指定 + 自動検出 (`CredentialSource.discover()`)
    var sources: [CredentialSource]?

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quotaback", isDirectory: true)
    static let path = directory.appendingPathComponent("config.json")

    static let fallback = AppConfig(
        refreshSeconds: 300,
        accounts: [
            AccountConfig(label: "P", name: "personal@example.com"),
            AccountConfig(label: "W", name: "work@example.com"),
        ]
    )

    /// 設定ファイルを読む。無ければデフォルトを書き出してそれを返す。
    static func load() -> AppConfig {
        if case .success(let cfg) = read() { return cfg }
        if !FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(fallback) { try? data.write(to: path) }
        }
        return fallback
    }

    /// 設定ファイルを読む。無い・壊れているときは失敗を返す（編集途中の書き間違いで設定を失わないように）
    static func read(from url: URL = path) -> Result<AppConfig, Error> {
        Result {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        }
    }

    /// 変わったときに取り直しが必要か（取得先や間隔が変わった）。ラベルや表示名だけなら不要
    func needsRefetch(comparedTo other: AppConfig) -> Bool {
        refreshSeconds != other.refreshSeconds
            || effectiveSources(discovered: []) != other.effectiveSources(discovered: [])
            || accounts.map(\.key) != other.accounts.map(\.key)
    }

    static func modificationDate(of url: URL = path) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
