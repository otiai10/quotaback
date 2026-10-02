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
        // 観測できたアカウントは、メールの頭文字をラベルにして自動で書き足される
        accounts: []
    )

    /// 設定ファイルを読む。無ければデフォルトを書き出してそれを返す。
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

    /// 観測できたのに設定に無いアカウントを末尾に足したもの。足すものが無ければ nil。
    /// ラベルはメールの頭文字。持ち主が分からないもの（"?" 始まり）は足さない
    func addingAccounts(_ keys: [AccountKey]) -> AppConfig? {
        let existing = Set(accounts.map(\.key))
        let missing = Set(keys).subtracting(existing)
            .filter { !$0.account.isEmpty && !$0.account.hasPrefix("?") }
            .sorted()
        guard !missing.isEmpty else { return nil }
        var new = self
        new.accounts += missing.map { key in
            AccountConfig(label: UsageEngine.defaultLabel(for: key), name: key.account,
                          provider: key.provider == ClaudeProvider.id ? nil : key.provider)
        }
        return new
    }

    /// 観測できたアカウントを config.json に書き足す。書き足したらその設定を返す。
    /// 直前にファイルを読み直して、それに足す（ユーザーの編集を消さない）。読めないときは触らない
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
