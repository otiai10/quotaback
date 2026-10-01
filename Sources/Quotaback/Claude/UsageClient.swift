import Foundation

enum UsageClient {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"

    // MARK: - Fetch

    /// - Parameter rawName: 生レスポンスの保存ファイル名に使う（アカウントのメールなど）
    static func fetch(token: String, rawName: String) async throws -> [UsageWindow] {
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
        saveRawResponse(data, name: rawName)
        return try parse(data)
    }

    /// デバッグ用に生レスポンスを保存（非公式APIなので形式が変わったときに確認できるように）
    private static func saveRawResponse(_ data: Data, name: String) {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let url = AppConfig.directory.appendingPathComponent("last-response-\(safe).json")
        try? data.write(to: url)
    }

    /// `limits` 配列（/usage の表示項目そのもの）を優先して読む。
    /// 無ければ「utilization を持つトップレベルのオブジェクト」を全部枠として拾う旧方式にフォールバック。
    static func parse(_ data: Data) throws -> [UsageWindow] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.parse("トップレベルがオブジェクトではありません")
        }
        var windows: [UsageWindow]
        if let limits = root["limits"] as? [[String: Any]] {
            windows = limits.compactMap(parseLimit)
        } else {
            windows = parseLegacy(root)
        }
        if let credits = parseSpend(root["spend"]) { windows.append(credits) }
        return windows
    }

    private static func parseLimit(_ obj: [String: Any]) -> UsageWindow? {
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
        return UsageWindow(key: scopeName.map { "\(kind)/\($0)" } ?? kind,
                           title: title,
                           utilization: percent,
                           resetsAt: parseDate(obj["resets_at"]),
                           isLimit: group == "session" || group == "weekly")
    }

    /// Usage credits。上限が設定されているときだけ出す
    private static func parseSpend(_ v: Any?) -> UsageWindow? {
        guard let spend = v as? [String: Any],
              spend["enabled"] as? Bool == true,
              let limit = money(spend["limit"]), limit.amount > 0 else { return nil }
        let used = money(spend["used"])
        let percent = (spend["percent"] as? NSNumber)?.doubleValue
            ?? (used.map { $0.amount / limit.amount * 100 } ?? 0)
        let detail = used.map { "\($0.formatted) / \(limit.formatted)" } ?? "上限 \(limit.formatted)"
        return UsageWindow(key: "spend", title: "Usage credits", utilization: percent,
                           resetsAt: nil, isLimit: false, detail: detail)
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

    private static func parseLegacy(_ root: [String: Any]) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        for (key, value) in root {
            guard let obj = value as? [String: Any],
                  let util = (obj["utilization"] as? NSNumber)?.doubleValue else { continue }
            windows.append(UsageWindow(key: key,
                                       utilization: util,
                                       resetsAt: parseDate(obj["resets_at"])))
        }
        return windows.sorted { order($0.key) < order($1.key) }
    }

    private static func order(_ key: String) -> Int {
        switch key {
        case "five_hour": return 0
        case "seven_day": return 1
        case _ where key.hasPrefix("seven_day_"): return 2
        default: return 9
        }
    }

    /// resets_at は取得のたびに "01:59:59.59" / "02:00:00.19" のように前後するので、最も近い分に丸める
    static func parseDate(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: s) ?? {
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: s)
        }() else { return nil }
        return Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded() * 60)
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
