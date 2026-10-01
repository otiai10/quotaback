import Foundation

/// プロバイダ + アカウントの識別子。保存・表示ともにこれで引く。
struct AccountKey: Hashable, Codable, Comparable {
    var provider: String   // 例: "claude"
    var account: String    // 例: メールアドレス（小文字）

    var id: String { "\(provider):\(account)" }

    init(provider: String, account: String) {
        self.provider = provider
        self.account = account.lowercased()
    }

    init?(id: String) {
        guard let i = id.firstIndex(of: ":") else { return nil }
        self.init(provider: String(id[..<i]), account: String(id[id.index(after: i)...]))
    }

    static func < (a: AccountKey, b: AccountKey) -> Bool { a.id < b.id }
}

/// 枠がいつリセットされるか。次のリセット時刻を推定できるかどうかを決める。
enum Cadence: Codable, Hashable {
    /// 一定周期（週次枠など）。過ぎたリセット時刻に周期を足して次を推定できる
    case fixed(TimeInterval)
    /// 毎月（Usage credits など）
    case monthly
    /// 使い始めた時点から数える（5時間のセッション枠など）。リセット後の次の時刻は分からない
    case rolling(TimeInterval)
    case unknown
}

/// 1回の観測で得た1つの枠の値。表示用の推定はここから毎回計算する（保存するのは事実だけ）。
struct WindowObservation: Codable, Hashable, Identifiable {
    var key: String
    var title: String
    var percent: Double
    var resetsAt: Date?
    var isLimit: Bool
    var detail: String?
    var cadence: Cadence

    var id: String { key }
}

/// 1アカウントを1回観測した結果。最新のバッチがそのアカウントに今ある枠の一覧を決める。
struct ObservationBatch: Codable, Hashable {
    var account: AccountKey
    var observedAt: Date
    /// どこから観測したか（例: "Keychain 'Claude Code-credentials'"）
    var source: String
    var windows: [WindowObservation]
}
