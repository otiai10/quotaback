import Foundation

/// What the Analytics window shows, taken from UsageEngine: past cycles and the current cycle of logged-in accounts
struct AnalyticsInput {
    struct LiveWindow {
        let account: AccountKey
        let estimate: WindowEstimate
        /// Observations in the current cycle (oldest first)
        let points: [(Date, Double)]
    }

    var cycles: [CycleSummary] = []
    /// Account → panel title (emoji + label, or the part of the email before @)
    var titles: [AccountKey: String] = [:]
    var live: [LiveWindow] = []
    var now = Date()

    func title(_ account: AccountKey) -> String {
        titles[account] ?? UsageEngine.localPart(account.account)
    }
}

/// Chart data for the Analytics window. Pure functions so that they can be tested without the UI
enum AnalyticsModel {
    /// A cycle whose last observation is this long before the reset ended while not logged in: its final value is a lower bound
    static let lowerBoundGap: TimeInterval = 15 * 60

    static func isLowerBound(_ s: CycleSummary) -> Bool {
        s.resetsAt.timeIntervalSince(s.lastObservedAt) > lowerBoundGap
    }

    // MARK: 1. Final usage at reset

    struct CycleBar: Identifiable, Hashable {
        let resetsAt: Date
        /// nil when the cycle has no summary (never observed). Not the same as 0%
        let percent: Double?
        let isLowerBound: Bool

        var id: Date { resetsAt }
    }

    struct CycleSeries: Identifiable, Hashable {
        let account: AccountKey
        let key: String
        let title: String
        let bars: [CycleBar]

        var id: String { "\(account.id) \(key)" }
    }

    /// One series per account and fixed-cadence window (weekly), oldest cycle first. A cycle missing between two
    /// summaries, or after the last one and already reset by `now`, becomes a bar without a value
    static func finalUsage(_ cycles: [CycleSummary], now: Date) -> [CycleSeries] {
        let fixed = cycles.filter { if case .fixed(let p) = $0.cadence { return p > 0 } else { return false } }
        return Dictionary(grouping: fixed, by: \.windowID).values.compactMap { group -> CycleSeries? in
            let sorted = group.sorted { $0.resetsAt < $1.resetsAt }
            guard let last = sorted.last, case .fixed(let period) = last.cadence else { return nil }
            var bars: [CycleBar] = []
            for s in sorted {
                if let prev = bars.last {
                    let missing = Int((s.resetsAt.timeIntervalSince(prev.resetsAt) / period).rounded()) - 1
                    if missing > 0 {
                        bars += (1...missing).map {
                            CycleBar(resetsAt: prev.resetsAt.addingTimeInterval(Double($0) * period),
                                     percent: nil, isLowerBound: false)
                        }
                    }
                }
                bars.append(CycleBar(resetsAt: s.resetsAt, percent: s.finalPercent, isLowerBound: isLowerBound(s)))
            }
            // Cycles that have ended since the last summary without ever being observed
            var next = last.resetsAt.addingTimeInterval(period)
            while next.addingTimeInterval(60) < now {
                bars.append(CycleBar(resetsAt: next, percent: nil, isLowerBound: false))
                next.addTimeInterval(period)
            }
            return CycleSeries(account: last.account, key: last.key, title: last.title, bars: bars)
        }
        .sorted { ($0.account, $0.key) < ($1.account, $1.key) }
    }

    // MARK: 2. Burndown of the current cycle

    struct BurnPoint: Identifiable, Hashable {
        enum Kind: Hashable { case observed, projected }
        /// Line identity (account + window)
        let series: String
        let label: String
        /// Elapsed share of the cycle (0–100)
        let elapsed: Double
        let percent: Double
        let kind: Kind

        var id: String { "\(series) \(kind) \(elapsed)" }
    }

    /// Lines for the usage-limit windows of logged-in accounts, with time as the elapsed share of each cycle so that
    /// 5-hour and weekly windows share one axis (the ideal pace is the diagonal). A window still projected to reach
    /// 100% gets a projected segment from its last observation to the limit
    static func burndown(_ live: [AnalyticsInput.LiveWindow], titles: (AccountKey) -> String) -> [BurnPoint] {
        live.flatMap { lw -> [BurnPoint] in
            let w = lw.estimate.window
            guard w.isLimit, let reset = w.resetsAt, lw.estimate.value != .reset else { return [] }
            let length: TimeInterval
            switch w.cadence {
            case .fixed(let p), .rolling(let p): length = p
            case .monthly, .unknown: return []
            }
            guard length > 0 else { return [] }
            let start = reset.addingTimeInterval(-length)
            let elapsed = { (t: Date) in min(100, max(0, t.timeIntervalSince(start) / length * 100)) }
            let series = "\(lw.account.id) \(w.key)"
            let label = "\(titles(lw.account)) · \(w.title)"
            var points = lw.points.map {
                BurnPoint(series: series, label: label, elapsed: elapsed($0.0), percent: $0.1, kind: .observed)
            }
            if let eta = lw.estimate.limitETA, let last = lw.points.last {
                points += [BurnPoint(series: series, label: label, elapsed: elapsed(last.0), percent: last.1, kind: .projected),
                           BurnPoint(series: series, label: label, elapsed: elapsed(eta), percent: 100, kind: .projected)]
            }
            return points
        }
    }

    // MARK: 3. Balance between accounts

    struct BalanceBar: Identifiable, Hashable {
        /// Start of the calendar week the reset falls in
        let week: Date
        let account: AccountKey
        let title: String
        let percent: Double
        let isLowerBound: Bool

        var id: String { "\(week.timeIntervalSince1970) \(account.id)" }
    }

    /// Final usage of each Claude account's all-models weekly window, lined up by the calendar week of the reset.
    /// A week without an account's summary has no bar for it
    static func balance(_ cycles: [CycleSummary], titles: (AccountKey) -> String,
                        calendar: Calendar = .current) -> [BalanceBar] {
        var bars: [String: BalanceBar] = [:]
        for s in cycles.sorted(by: { $0.resetsAt < $1.resetsAt })
        where s.account.provider == ClaudeProvider.id && s.key == "weekly_all" {
            guard let week = calendar.dateInterval(of: .weekOfYear, for: s.resetsAt)?.start else { continue }
            let bar = BalanceBar(week: week, account: s.account, title: titles(s.account),
                                 percent: s.finalPercent, isLowerBound: isLowerBound(s))
            bars[bar.id] = bar   // The later cycle wins if two fall in the same week
        }
        return bars.values.sorted { ($0.week, $0.account) < ($1.week, $1.account) }
    }
}
