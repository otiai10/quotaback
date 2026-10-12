import Foundation

enum UsageClient {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"

    // MARK: - Fetch

    /// Calls the usage API and returns the raw body (HTTP 200 only)
    static func fetch(token: String) async throws -> Data {
        var req = URLRequest(url: endpoint)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw UsageError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Reads `limits` (exactly the items /usage shows) plus the `spend` credits; a response without `limits` is a format change and throws
    static func parse(_ data: Data) throws -> [WindowObservation] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.parse(L10n.notAnObject)
        }
        guard let limits = root["limits"] as? [[String: Any]] else {
            throw UsageError.parse(L10n.limitsMissing)
        }
        var windows = limits.compactMap(parseLimit)
        if let credits = parseSpend(root["spend"]) { windows.append(credits) }
        return windows
    }

    private static func parseLimit(_ obj: [String: Any]) -> WindowObservation? {
        guard let kind = obj["kind"] as? String,
              let percent = (obj["percent"] as? NSNumber)?.doubleValue else { return nil }
        let scope = obj["scope"] as? [String: Any]
        let scopeName = ((scope?["model"] as? [String: Any])?["display_name"] as? String)
            ?? ((scope?["surface"] as? [String: Any])?["display_name"] as? String)
            ?? (scope?["surface"] as? String)

        let title: String
        switch kind {
        case "session": title = "Current session"
        case "weekly_all": title = "Current week (all models)"
        case "weekly_scoped": title = "Current week (\(scopeName ?? "scoped"))"
        default: title = kind.replacingOccurrences(of: "_", with: " ").capitalized
                         + (scopeName.map { " (\($0))" } ?? "")
        }
        let group = obj["group"] as? String
        return WindowObservation(key: scopeName.map { "\(kind)/\($0)" } ?? kind,
                                 title: title,
                                 percent: percent,
                                 resetsAt: parseDate(obj["resets_at"]),
                                 isLimit: group == "session" || group == "weekly",
                                 cadence: ClaudeProvider.cadence(forKind: kind))
    }

    /// Usage credits. Only when a limit is set
    private static func parseSpend(_ v: Any?) -> WindowObservation? {
        guard let spend = v as? [String: Any],
              spend["enabled"] as? Bool == true,
              let limit = money(spend["limit"]), limit.amount > 0 else { return nil }
        let used = money(spend["used"])
        let percent = (spend["percent"] as? NSNumber)?.doubleValue
            ?? (used.map { $0.amount / limit.amount * 100 } ?? 0)
        let detail = used.map { "\($0.formatted) / \(limit.formatted)" } ?? L10n.creditLimit(limit.formatted)
        return WindowObservation(key: "spend", title: "Usage credits", percent: percent,
                                 resetsAt: nil, isLimit: false, detail: detail,
                                 cadence: ClaudeProvider.cadence(forKind: "spend"))
    }

    private struct Money {
        let amount: Double
        let currency: String
        let exponent: Int
        var formatted: String {
            let symbol = currency == "USD" ? "$" : currency + " "
            return symbol + String(format: "%.\(exponent)f", amount)
        }
    }

    private static func money(_ v: Any?) -> Money? {
        guard let obj = v as? [String: Any],
              let minor = (obj["amount_minor"] as? NSNumber)?.doubleValue else { return nil }
        let exp = (obj["exponent"] as? NSNumber)?.intValue ?? 2
        return Money(amount: minor / pow(10, Double(exp)),
                     currency: obj["currency"] as? String ?? "USD",
                     exponent: exp)
    }

    // On macOS 27 either style reads both forms, but that leniency is undocumented,
    // so fall back to the plain style when the fractional one fails
    private static let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainStyle = Date.ISO8601FormatStyle()

    /// resets_at jitters between fetches ("01:59:59.59" / "02:00:00.19"), so round to the nearest minute
    static func parseDate(_ v: Any?) -> Date? {
        guard let s = v as? String,
              let d = (try? Date(s, strategy: fractionalStyle)) ?? (try? Date(s, strategy: plainStyle))
        else { return nil }
        return Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded() * 60)
    }
}
