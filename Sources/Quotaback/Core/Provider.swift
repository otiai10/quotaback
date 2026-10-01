import Foundation

/// 使用量の取得元（プロバイダ）。Claude と Codex。
protocol UsageProvider {
    /// 設定から、観測しに行く対象（認証情報の置き場所）を列挙する
    func targets(config: AppConfig) -> [PollTarget]
}

enum Providers {
    static let all: [UsageProvider] = [ClaudeProvider(), CodexProvider()]

    static func targets(config: AppConfig) -> [PollTarget] {
        all.flatMap { $0.targets(config: config) }
    }
}

/// 観測対象の1つ（例: Keychain の1エントリ）。ここに入っているのは
/// 「その時点でログインしているアカウント」のものだけ、という前提で扱う。
struct PollTarget: @unchecked Sendable {
    let provider: String
    let id: String
    let description: String
    /// 今の持ち主（アカウント識別子）。ネットワークや Keychain に触れず安価に読めること
    let owner: @Sendable () -> String?
    /// 持ち主の判定元の更新時刻。ログイン切り替えの検知に使う（変化したら owner を読み直す）
    let ownerStamp: @Sendable () -> Date?
    let fetch: @Sendable () async throws -> FetchedUsage
}

struct FetchedUsage {
    var windows: [WindowObservation]
    /// 使った認証情報のハッシュ（メモリ上でだけ使う。保存しない）
    var credentialFingerprint: String? = nil
    /// 値がいつ時点のものか。API で今取ったなら nil（= 取得時刻）。
    /// ログなどから読んだ過去の値なら、その記録時刻
    var asOf: Date? = nil
}
