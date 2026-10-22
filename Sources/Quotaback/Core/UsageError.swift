import Foundation

/// Fetch failures, shared across providers
enum UsageError: LocalizedError {
    case credentials(String)
    case tokenExpired
    case http(Int, String)
    case parse(String)
    /// The gate declined to call (no request was sent). `rateLimited` = the pause follows an earlier 429
    case deferred(Date, rateLimited: Bool)
    /// The server answered 429 just now; `until` is when the gate will try again
    case rateLimited(until: Date, retryAfter: String?)
    /// Fetched, but no new observation for the current owner (not shown as an error; the previous value keeps showing as a lower bound)
    case noObservation(String)

    var errorDescription: String? {
        switch self {
        case .credentials(let m): return L10n.credentialsError(m)
        case .tokenExpired: return L10n.tokenExpired
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .parse(let m): return L10n.parseError(m)
        case .noObservation(let m): return m
        case .deferred(let until, let limited): return L10n.usageDeferred(until, rateLimited: limited)
        case .rateLimited(let until, let retryAfter): return L10n.rateLimited(until, retryAfter: retryAfter)
        }
    }
}
