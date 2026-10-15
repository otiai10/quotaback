import XCTest
@testable import Quotaback

final class AnalyticsModelTests: XCTestCase {
    let p = AccountKey(provider: "claude", account: "p@example.com")
    let w = AccountKey(provider: "claude", account: "w@example.com")
    let codex = AccountKey(provider: "codex", account: "p@example.com")
    let week: TimeInterval = 7 * 24 * 3600

    func cycle(_ account: AccountKey, _ key: String = "weekly_all", resetsAt: Date, final: Double,
               lastObservedBefore gap: TimeInterval = 60, cadence: Cadence? = nil) -> CycleSummary {
        CycleSummary(account: account, key: key, title: key, cadence: cadence ?? .fixed(week),
                     resetsAt: resetsAt, firstObservedAt: resetsAt - 6 * day, lastObservedAt: resetsAt - gap,
                     finalPercent: final, peakPercent: final, observations: 3)
    }

    func titles(_ a: AccountKey) -> String { a == p ? "P" : "W" }

    /// AC-2: a cycle whose last observation is more than 15 minutes before the reset is a lower bound
    func testFinalUsageMarksLowerBounds() {
        let r = t0 + week
        let series = AnalyticsModel.finalUsage([
            cycle(p, resetsAt: r, final: 80, lastObservedBefore: 5 * 60),
            cycle(p, resetsAt: r + week, final: 60, lastObservedBefore: 15 * 60),
            cycle(p, resetsAt: r + 2 * week, final: 40, lastObservedBefore: 15 * 60 + 1),
            cycle(p, resetsAt: r + 3 * week, final: 30, lastObservedBefore: 3 * day),
        ], now: r + 3 * week + hour)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].bars.map(\.isLowerBound), [false, false, true, true])
        XCTAssertEqual(series[0].bars.map(\.percent), [80, 60, 40, 30])
    }

    /// AC-3: a week without a summary is a bar without a value, not 0%
    func testMissingCycleIsNoDataNotZero() {
        let r = t0 + week
        let series = AnalyticsModel.finalUsage([
            cycle(p, resetsAt: r, final: 70),
            // Two weeks are missing; the reset time jitters by under a minute
            cycle(p, resetsAt: r + 3 * week + 30, final: 50),
        ], now: r + 3 * week + day)
        let bars = series[0].bars
        XCTAssertEqual(bars.count, 4)
        XCTAssertEqual(bars.map(\.percent), [70, nil, nil, 50])
        XCTAssertEqual(bars[1].resetsAt, r + week)
        XCTAssertEqual(bars[2].resetsAt, r + 2 * week)
        XCTAssertFalse(bars.contains { $0.percent == 0 })
    }

    /// Cycles that ended after the last summary without being observed are also "no data"; the current one isn't shown
    func testCyclesEndedSinceLastSummaryAreNoData() {
        let r = t0 + week
        let bars = AnalyticsModel.finalUsage([cycle(w, resetsAt: r, final: 45)], now: r + 2 * week + day)[0].bars
        XCTAssertEqual(bars.map(\.percent), [45, nil, nil])
        XCTAssertEqual(bars.map(\.resetsAt), [r, r + week, r + 2 * week])
    }

    func testFinalUsageOnlyFixedCadencePerAccountAndWindow() {
        let r = t0 + week
        let series = AnalyticsModel.finalUsage([
            cycle(w, resetsAt: r, final: 10),
            cycle(p, "weekly_scoped/Fable", resetsAt: r, final: 20),
            cycle(p, resetsAt: r, final: 30),
            cycle(codex, "window_10080m", resetsAt: r, final: 40),
            cycle(p, "session", resetsAt: r, final: 90, cadence: .rolling(5 * hour)),
            cycle(p, "spend", resetsAt: r, final: 5, cadence: .monthly),
        ], now: r + hour)
        XCTAssertEqual(series.map { "\($0.account.id) \($0.key)" }, [
            "claude:p@example.com weekly_all",
            "claude:p@example.com weekly_scoped/Fable",
            "claude:w@example.com weekly_all",
            "codex:p@example.com window_10080m",
        ])
    }

    /// Heatmap: windows resetting on different days share a calendar-week column; missing cycles stay "no data"
    func testHeatmapAlignsRowsByCalendarWeek() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        calendar.firstWeekday = 2
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 5)))
        let tuesday = monday + day + 6 * hour
        let cells = AnalyticsModel.heatmap([
            cycle(p, resetsAt: monday, final: 100),
            cycle(p, resetsAt: monday + 2 * week, final: 70),
            cycle(w, resetsAt: tuesday, final: 20, lastObservedBefore: day),
        ], now: monday + 2 * week + hour, titles: titles, calendar: calendar)

        let pRow = cells.filter { $0.account == "P" }
        XCTAssertEqual(pRow.map(\.percent), [100, nil, 70])
        XCTAssertEqual(pRow.map(\.week), [monday, monday + week, monday + 2 * week].map {
            calendar.dateInterval(of: .weekOfYear, for: $0)!.start
        })
        let wRow = cells.filter { $0.account == "W" }
        XCTAssertEqual(wRow.first?.week, pRow.first?.week, "different reset days fall in the same column")
        XCTAssertEqual(wRow.first?.isLowerBound, true)
        XCTAssertEqual(Set(cells.map(\.window)), ["weekly_all"])
    }

    func testBurndownUsesElapsedShareAndProjection() {
        let reset = t0 + 4 * day
        let start = reset - week
        let weekly = window(percent: 40, resetsAt: reset)
        let session = window("session", percent: 50, resetsAt: t0 + 2.5 * hour, cadence: .rolling(5 * hour))
        let credits = window("spend", percent: 10, resetsAt: reset, cadence: .monthly, isLimit: false)
        let eta = start + 0.8 * week
        let live = [
            AnalyticsInput.LiveWindow(account: p, estimate: estimate(weekly, eta: eta),
                                      points: [(start + 0.25 * week, 10), (start + 0.5 * week, 40)]),
            AnalyticsInput.LiveWindow(account: p, estimate: estimate(session, eta: nil),
                                      points: [(t0, 50)]),
            AnalyticsInput.LiveWindow(account: p, estimate: estimate(credits, eta: nil), points: [(t0, 10)]),
        ]
        let points = AnalyticsModel.burndown(live, titles: titles)

        let observed = points.filter { $0.kind == .observed }
        XCTAssertEqual(observed.map(\.elapsed), [25, 50, 50])
        XCTAssertEqual(observed.map(\.label), ["P · weekly_all", "P · weekly_all", "P · session"])
        let projected = points.filter { $0.kind == .projected }
        XCTAssertEqual(projected.map(\.elapsed), [50, 80])
        XCTAssertEqual(projected.map(\.percent), [40, 100])
    }

    func testLimitMarksAreTheProjectedLimitsEarliestFirst() {
        let reset = t0 + 4 * day
        let start = reset - week
        let live = [("a", 0.9), ("b", 0.3), ("c", nil)].map { key, share in
            AnalyticsInput.LiveWindow(account: p, estimate: estimate(window(key, percent: 20, resetsAt: reset),
                                                                     eta: share.map { start + $0 * week }),
                                      points: [(start + 0.1 * week, 10), (start + 0.2 * week, 20)])
        }
        let marks = AnalyticsModel.limitMarks(AnalyticsModel.burndown(live, titles: titles))
        XCTAssertEqual(marks.map(\.series), ["b", "a"].map { "\(p.id) \($0)" })
        XCTAssertEqual(marks.first?.at, start + 0.3 * week)
        XCTAssertEqual(marks.first?.resetsAt, reset)
    }

    func testSpreadMovesOnlyOverlappingLabels() {
        // Far apart: untouched
        XCTAssertEqual(AnalyticsModel.spread([100, 300, 200], width: 50, within: 0...500), [100, 300, 200])
        // 200 and 220 overlap: pushed apart evenly around their middle; 400 stays
        XCTAssertEqual(AnalyticsModel.spread([220, 400, 200], width: 50, within: 0...500), [235, 400, 185])
        // 200 and 220 push apart to 185 and 235, which now overlaps 150 (50 apart before): all three form one run
        XCTAssertEqual(AnalyticsModel.spread([150, 200, 220], width: 50, within: 0...500), [140, 190, 240])
        // Kept inside: the right edge holds the last label at 475
        XCTAssertEqual(AnalyticsModel.spread([480, 490], width: 50, within: 0...500), [425, 475])
        // Too many to fit: spread evenly across the whole width, overlapping as little as possible
        XCTAssertEqual(AnalyticsModel.spread([50, 50, 50], width: 50, within: 0...100), [25, 50, 75])
    }

    func testDuration() {
        L10n.apply("en")
        XCTAssertEqual(L10n.duration(42 * hour + 59 * 60), "1d 18h")
        XCTAssertEqual(L10n.duration(5 * hour + 3 * 60), "5h 3m")
        XCTAssertEqual(L10n.duration(9 * 60), "9m")
        L10n.apply("ja")
        XCTAssertEqual(L10n.duration(42 * hour), "1日18時間")
        L10n.apply(nil)
    }

    func estimate(_ w: WindowObservation, eta: Date?) -> WindowEstimate {
        WindowEstimate(window: w, value: .exact(w.percent), nextReset: .known(w.resetsAt ?? t0),
                       observedAt: t0, limitETA: eta)
    }
}
