import Foundation

/// Display language: `language` in config.json ("en" / "ja"), English when omitted
enum Language: String, CaseIterable {
    case en, ja

    /// The current display language. Switched by `L10n.apply(_:)` when the config is read
    static var current: Language = .en

    static var system: Language { from(Locale.preferredLanguages.first) ?? .en }

    /// From "ja", "ja-JP", "en_US" and so on. nil if unsupported
    static func from(_ code: String?) -> Language? {
        guard let code = code?.lowercased() else { return nil }
        return allCases.first { code == $0.rawValue || code.hasPrefix($0.rawValue + "-") || code.hasPrefix($0.rawValue + "_") }
    }

    /// Locale for date formatting. Uses the OS region settings as-is when the language matches the OS
    var locale: Locale {
        Language.system == self ? .current : Locale(identifier: rawValue)
    }
}

/// UI and message strings (en / ja). Add translations here only
enum L10n {
    /// Applies `language` from the config. English when unset or unsupported
    static func apply(_ code: String?) {
        Language.current = Language.from(code) ?? .en
    }

    static var locale: Locale { Language.current.locale }

    private static func t(_ en: String, _ ja: String) -> String {
        switch Language.current {
        case .en: return en
        case .ja: return ja
        }
    }

    // MARK: Menu and panel

    static var refresh: String { t("Refresh", "更新") }
    static var launchAtLogin: String { t("Launch at Login", "ログイン時に起動") }
    static var quit: String { t("Quit", "終了") }
    static var launchAtLoginFailed: String { t("Couldn't change Launch at Login", "ログイン時に起動を切り替えられませんでした") }
    static func fetchedAt(_ time: String) -> String { t("Updated \(time)", "取得: \(time)") }
    static var openSettings: String { t("Open Settings", "設定を開く") }
    static var loggedIn: String { t("Logged in", "ログイン中") }
    static var notLoggedIn: String { t("Not logged in", "未ログイン") }
    static var notObservedYet: String {
        t("Not observed yet (it's fetched once you log in to claude with this account)",
          "まだ観測していません（このアカウントで claude にログインすると取得されます）")
    }
    static func lastObserved(_ time: String, _ ago: String) -> String {
        t("Last observed \(time) (\(ago)) · a lower bound that excludes later usage",
          "最終観測: \(time)（\(ago)）· 以降の使用は含まない下限値")
    }
    static func limitAround(_ time: String) -> String { t("Limit around \(time)", "\(time) 頃に上限") }
    static var limitAroundHelp: String { t("Projected if you keep this pace", "このペースで使い続けた場合の見込み") }
    static var resetDone: String { t("Reset", "リセット済み") }
    static func resets(_ time: String) -> String { "Resets \(time)" }
    static func resetsProjected(_ time: String) -> String { t("Resets \(time) (est.)", "Resets \(time)（推定）") }
    static var resetStartsOnUse: String { t("Next reset is set once you start using it", "次のリセットは使い始めてから決まる") }
    static func configUnreadable(_ error: String) -> String {
        t("Can't read config.json (keeping the previous settings): \(error)",
          "config.json を読めません（前の設定のまま）: \(error)")
    }

    // MARK: Fetch errors

    static func credentialsError(_ m: String) -> String { t("Can't read credentials: \(m)", "認証情報を読めません: \(m)") }
    static var tokenExpired: String {
        t("Token expired (run claude once with this account to refresh it)",
          "トークン期限切れ（このアカウントで claude を一度起動すると更新されます）")
    }
    static func parseError(_ m: String) -> String { t("Couldn't parse the response: \(m)", "レスポンス解析失敗: \(m)") }
    static var notAnObject: String { t("the top level is not an object", "トップレベルがオブジェクトではありません") }
    static var notSet: String { t("(not set)", "(未設定)") }
    static func notFound(_ path: String) -> String { t("\(path) not found", "\(path) が見つかりません") }
    static var setKeychainOrPath: String { t("set keychainService or credentialsPath", "keychainService か credentialsPath を設定してください") }
    static var accessTokenMissing: String { t("claudeAiOauth.accessToken is missing", "claudeAiOauth.accessToken がありません") }
    static func creditLimit(_ amount: String) -> String { t("limit \(amount)", "上限 \(amount)") }
    static var codexNoRecord: String {
        t("No usage limits in the Codex session logs yet (they're recorded once you use codex)",
          "Codex のセッションログに利用上限の記録がありません（codex を一度使うと記録されます）")
    }
    static var codexNoRecordSinceLogin: String {
        t("No Codex records since the last login yet (they're recorded once you use codex)",
          "ログイン後の Codex の記録がまだありません（codex を一度使うと記録されます）")
    }
    static func ownerChanged(_ before: String, _ after: String) -> String {
        t("the owner changed while fetching (\(before) → \(after))", "取得中に持ち主が変わった（\(before) → \(after)）")
    }
    static func tokenBelongsTo(_ account: String) -> String {
        t("these credentials were recorded as \(account)'s (possibly mid-switch)",
          "認証情報が \(account) のものとして記録済み（切り替え途中の可能性）")
    }

    // MARK: --once

    static var onceObserve: String { t("== Observations", "== 観測") }
    static var unknownOwner: String { t("unknown owner", "持ち主不明") }
    static func recorded(_ n: Int) -> String { t("recorded: \(n) \(n == 1 ? "window" : "windows")", "記録: \(n) 枠") }
    static func skipped(_ m: String) -> String { t("skipped: \(m)", "スキップ: \(m)") }
    static func noNewObservation(_ m: String) -> String { t("no new observation: \(m)", "新しい観測なし: \(m)") }
    static var onceAdded: String { t("== Added to config.json: ", "== config.json に追加: ") }
    static var onceEstimates: String { t("== Estimates (including saved observations)", "== 推定（保存済みの観測を含む）") }
    static func lastObservedShort(_ time: String) -> String { t("last observed: \(time)", "最終観測: \(time)") }
    static var projectedSuffix: String { t(" (est.)", " (推定)") }
    static func limitETA(_ time: String) -> String { t(" · limit around \(time)", " · 上限到達見込み \(time)") }
}
