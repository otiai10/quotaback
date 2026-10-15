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

    struct HeatCell: Identifiable, Hashable {
        /// Row: one account and window, in the order of `finalUsage`
        let row: String
        let account: String
        let window: String
        /// Start of the calendar week the reset falls in, so that windows resetting on different days share a column
        let week: Date
        /// nil when the cycle was never observed. Not the same as 0%
        let percent: Double?
        let isLowerBound: Bool

        var id: String { "\(row) \(week.timeIntervalSince1970)" }
    }

    /// `finalUsage` laid out as a grid: a row per account and window, a column per calendar week
    static func heatmap(_ cycles: [CycleSummary], now: Date, titles: (AccountKey) -> String,
                        calendar: Calendar = .current) -> [HeatCell] {
        finalUsage(cycles, now: now).flatMap { s -> [HeatCell] in
            var cells: [Date: HeatCell] = [:]
            for bar in s.bars {
                guard let week = calendar.dateInterval(of: .weekOfYear, for: bar.resetsAt)?.start else { continue }
                // The later cycle wins if two fall in the same week, unless it has no data
                if bar.percent == nil, cells[week] != nil { continue }
                cells[week] = HeatCell(row: s.id, account: titles(s.account), window: s.title, week: week,
                                       percent: bar.percent, isLowerBound: bar.isLowerBound)
            }
            return cells.values.sorted { $0.week < $1.week }
        }
    }

    // MARK: 2. Burndown of the current cycle

    struct BurnPoint: Identifiable, Hashable {
        enum Kind: Hashable { case observed, projected }
        /// Line identity (account + window)
        let series: String
        let label: String
        let at: Date
        /// Elapsed share of the cycle (0–100)
        let elapsed: Double
        let percent: Double
        let kind: Kind
        /// The reset that ends this cycle
        let resetsAt: Date

        var id: String { "\(series) \(kind) \(at.timeIntervalSince1970)" }
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
                BurnPoint(series: series, label: label, at: $0.0, elapsed: elapsed($0.0), percent: $0.1, kind: .observed,
                          resetsAt: reset)
            }
            if let eta = lw.estimate.limitETA, let last = lw.points.last {
                points += [BurnPoint(series: series, label: label, at: last.0, elapsed: elapsed(last.0), percent: last.1, kind: .projected,
                                     resetsAt: reset),
                           BurnPoint(series: series, label: label, at: eta, elapsed: elapsed(eta), percent: 100, kind: .projected,
                                     resetsAt: reset)]
            }
            return points
        }
    }

    /// The end of a projected tail: when the window is projected to hit its limit before the reset
    struct LimitMark: Identifiable, Hashable {
        let series: String
        let label: String
        let elapsed: Double
        let at: Date
        let resetsAt: Date

        var id: String { series }
    }

    /// The limit marks of `burndown`'s projections, earliest first
    static func limitMarks(_ points: [BurnPoint]) -> [LimitMark] {
        points.filter { $0.kind == .projected && $0.percent >= 100 }
            .sorted { $0.at < $1.at }
            .map { LimitMark(series: $0.series, label: $0.label, elapsed: $0.elapsed, at: $0.at, resetsAt: $0.resetsAt) }
    }

    /// Centers for labels `width` wide that want to sit at `xs`, moved as little as possible so that none overlap
    /// and all stay `within` (best effort: when they can't all fit, they overlap evenly). Same order as `xs`
    static func spread(_ xs: [Double], width: Double, within bounds: ClosedRange<Double>) -> [Double] {
        let order = xs.indices.sorted { xs[$0] < xs[$1] }
        let lo = bounds.lowerBound + width / 2, hi = max(lo, bounds.upperBound - width / 2)
        // Runs of labels packed side by side; a run sits where the mean of its labels' wishes puts it
        struct Run { var first: Int; var count: Int; var sum: Double; var start: Double }
        var runs: [Run] = []
        for (k, i) in order.enumerated() {
            let wish = min(hi, max(lo, xs[i]))
            var run = Run(first: k, count: 1, sum: wish, start: wish)
            while let prev = runs.last, prev.start + Double(prev.count) * width > run.start {
                runs.removeLast()
                let count = prev.count + run.count
                // Each label's wish minus its offset in the merged run
                let sum = prev.sum + run.sum - Double(prev.count) * width * Double(run.count)
                let span = Double(count - 1) * width
                let start = hi - lo >= span ? min(hi - span, max(lo, sum / Double(count))) : lo
                run = Run(first: prev.first, count: count, sum: sum, start: start)
            }
            runs.append(run)
        }
        var out = xs
        for run in runs {
            let step = run.count > 1 ? min(width, (hi - lo) / Double(run.count - 1)) : 0
            for k in 0..<run.count { out[order[run.first + k]] = run.start + Double(k) * step }
        }
        return out
    }
}
