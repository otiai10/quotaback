import Foundation

/// 表示するアカウント。どの認証情報が誰のものかは実行時に `.claude.json` のメールアドレスで判定する。
struct AccountConfig: Codable, Identifiable, Hashable {
    var label: String              // メニューバーに出す短いラベル (例: "P", "W")
    var name: String               // メールアドレス。`.claude.json` の oauthAccount.emailAddress と照合する
    // 旧形式の互換用。指定されていれば認証情報の置き場所 (CredentialSource) として扱う
    var keychainService: String?
    var credentialsPath: String?

    var id: String { name.lowercased() }
}

/// Claude Code のログイン1つ分の認証情報の置き場所。
/// 1つの置き場所には「最後にログインしたアカウント」のトークンしか入らない。
struct CredentialSource: Codable, Hashable, Identifiable {
    var keychainService: String?   // 例: "Claude Code-credentials"
    var credentialsPath: String?   // 例: "~/.claude-work/.credentials.json"
    /// 持ち主のメールアドレスを読む `.claude.json`。省略時は置き場所から推定
    var profilePath: String?
    /// `.claude.json` で判定できないときの手動指定
    var email: String?

    static let defaultKeychain = CredentialSource(keychainService: "Claude Code-credentials")

    var id: String {
        if let s = keychainService { return "keychain:\(s)" }
        return "file:\((credentialsPath.map { ($0 as NSString).expandingTildeInPath }) ?? "")"
    }

    var description: String {
        if let s = keychainService { return "Keychain '\(s)'" }
        return credentialsPath ?? "(未設定)"
    }

    /// 持ち主を判定する `.claude.json` の場所。
    /// - 既定の Keychain エントリ → `~/.claude.json`
    /// - `~/.claude/.credentials.json` → `~/.claude.json`
    /// - `<dir>/.credentials.json` → `<dir>/.claude.json`（CLAUDE_CONFIG_DIR を分けている場合）
    var resolvedProfilePath: String? {
        if let p = profilePath { return (p as NSString).expandingTildeInPath }
        if keychainService == Self.defaultKeychain.keychainService {
            return (("~/.claude.json") as NSString).expandingTildeInPath
        }
        if let c = credentialsPath {
            let dir = ((c as NSString).expandingTildeInPath as NSString).deletingLastPathComponent
            // 既定の ~/.claude だけは .claude.json がホーム直下にある
            if dir == ("~/.claude" as NSString).expandingTildeInPath {
                return ("~/.claude.json" as NSString).expandingTildeInPath
            }
            return (dir as NSString).appendingPathComponent(".claude.json")
        }
        return nil
    }
}

struct AppConfig: Codable {
    var refreshSeconds: Int
    var accounts: [AccountConfig]
    /// 省略時は accounts[] の旧形式指定 + 自動検出 (`CredentialSource.discover()`)
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

    /// 実際に読みに行く認証情報の置き場所
    func effectiveSources(discovered: [CredentialSource]) -> [CredentialSource] {
        let candidates: [CredentialSource]
        if let sources {
            candidates = sources
        } else {
            let legacy = accounts.compactMap { a -> CredentialSource? in
                // "Claude Code-credentials-<SUFFIX>" のような未記入のプレースホルダは無視
                if let s = a.keychainService, !s.contains("<") { return CredentialSource(keychainService: s) }
                if let c = a.credentialsPath { return CredentialSource(credentialsPath: c) }
                return nil
            }
            candidates = legacy + discovered
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted }
    }

    /// 設定ファイルを読む。無ければデフォルトを書き出してそれを返す。
    static func load() -> AppConfig {
        if let data = try? Data(contentsOf: path),
           let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return cfg
        }
        if !FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(fallback) { try? data.write(to: path) }
        }
        return fallback
    }
}

/// 利用上限の1つの枠 (5時間枠・週次枠など)
struct UsageWindow: Identifiable, Hashable, Codable {
    let key: String          // 一意キー (limits[].kind + scope、または旧形式のトップレベルキー名)
    let title: String
    let utilization: Double  // 0–100 (%)
    let resetsAt: Date?
    /// プランの利用上限 (メニューバーのピーク値計算の対象)
    let isLimit: Bool
    var detail: String? = nil  // 例: "$57.97 / $200.00"

    var id: String { key }

    /// リセット時刻を過ぎていれば、保存してある値はもう古い
    func isReset(at now: Date = Date()) -> Bool { resetsAt.map { $0 <= now } ?? false }

    init(key: String, title: String, utilization: Double, resetsAt: Date?, isLimit: Bool, detail: String? = nil) {
        self.key = key
        self.title = title
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.isLimit = isLimit
        self.detail = detail
    }

    /// 旧形式 (トップレベルの five_hour / seven_day* など) のキー名から組み立てる
    init(key: String, utilization: Double, resetsAt: Date?) {
        self.init(key: key, title: Self.legacyTitle(key), utilization: utilization, resetsAt: resetsAt,
                  isLimit: key == "five_hour" || key.hasPrefix("seven_day"))
    }

    static func legacyTitle(_ key: String) -> String {
        switch key {
        case "five_hour": return "Current session"
        case "seven_day": return "Current week (all models)"
        case "extra_usage": return "Usage credits"
        default:
            if key.hasPrefix("seven_day_") {
                let model = key.dropFirst("seven_day_".count)
                    .replacingOccurrences(of: "_", with: " ")
                return "Current week (\(model.capitalized))"
            }
            return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct AccountState {
    var windows: [UsageWindow] = []
    var fetchedAt: Date?
    var error: String?
    var loading = false
    /// いまこのマシンでログイン中か（false なら前回保存した値を表示している）
    var isCurrent = false
}

/// アカウントごとの最後に取得できた値。`~/.config/quotaback/state.json` に保存し、
/// 1つのログインを切り替えて使っている場合でも、ログインしていない方の値を出せるようにする。
struct Snapshot: Codable, Equatable {
    var windows: [UsageWindow]
    var fetchedAt: Date

    static let path = AppConfig.directory.appendingPathComponent("state.json")

    static func loadAll(from url: URL = path) -> [String: Snapshot] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? decoder.decode([String: Snapshot].self, from: data)) ?? [:]
    }

    static func saveAll(_ all: [String: Snapshot], to url: URL = path) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? enc.encode(all) { try? data.write(to: url, options: .atomic) }
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
