import Foundation

/// 取得の失敗。プロバイダ共通
enum UsageError: LocalizedError {
    case credentials(String)
    case tokenExpired
    case http(Int, String)
    case parse(String)
    /// 取りに行けたが、今の持ち主の新しい観測が無い（エラーとしては出さず、前回値を下限として出し続ける）
    case noObservation(String)

    var errorDescription: String? {
        switch self {
        case .credentials(let m): return "認証情報を読めません: \(m)"
        case .tokenExpired: return "トークン期限切れ（このアカウントで claude を一度起動すると更新されます）"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .parse(let m): return "レスポンス解析失敗: \(m)"
        case .noObservation(let m): return m
        }
    }
}
