import Foundation

/// 1アカウント分の設定。keychainService か credentialsPath のどちらかを指定する。
struct AccountConfig: Codable, Identifiable, Hashable {
    var label: String              // メニューバーに出す短いラベル (例: "P", "W")
    var name: String               // ポップオーバーに出す名前 (メールアドレスなど)
    var keychainService: String?   // 例: "Claude Code-credentials"
    var credentialsPath: String?   // 例: "~/.claude-work/.credentials.json"

    var id: String { label + "|" + name }
}

struct AppConfig: Codable {
    var refreshSeconds: Int
    var accounts: [AccountConfig]

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quotaback", isDirectory: true)
    static let path = directory.appendingPathComponent("config.json")

    static let fallback = AppConfig(
        refreshSeconds: 300,
        accounts: [
            AccountConfig(label: "P", name: "personal@example.com",
                          keychainService: "Claude Code-credentials", credentialsPath: nil),
            // 仕事用: service 名は `security dump-keychain | grep '"svce"' | grep -i claude` で調べて置き換える
            AccountConfig(label: "W", name: "work@example.com",
                          keychainService: "Claude Code-credentials-<SUFFIX>", credentialsPath: nil),
        ]
    )

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
struct UsageWindow: Identifiable, Hashable {
    let key: String          // 一意キー (limits[].kind + scope、または旧形式のトップレベルキー名)
    let title: String
    let utilization: Double  // 0–100 (%)
    let resetsAt: Date?
    /// プランの利用上限 (メニューバーのピーク値計算の対象)
    let isLimit: Bool
    var detail: String? = nil  // 例: "$57.97 / $200.00"

    var id: String { key }

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
}
