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

    /// AC-4: a week where only one account has a summary has only that account's bar
    func testBalanceDrawsOnlyTheAccountWithData() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        calendar.firstWeekday = 2
        // Resets on different days of the same week (P on Monday 05:00, W on Tuesday 11:00 JST)
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 5)))
        let tuesday = monday + day + 6 * hour
        let bars = AnalyticsModel.balance([
            cycle(p, resetsAt: monday, final: 90),
            cycle(w, resetsAt: tuesday, final: 20, lastObservedBefore: day),
            cycle(p, resetsAt: monday + week, final: 70),          // W has no summary this week
            cycle(w, "weekly_scoped/Fable", resetsAt: tuesday + week, final: 50),
            cycle(codex, "window_10080m", resetsAt: monday + week, final: 30),
        ], titles: titles, calendar: calendar)

        XCTAssertEqual(bars.map(\.title), ["P", "W", "P"])
        XCTAssertEqual(bars.map(\.percent), [90, 20, 70])
        XCTAssertEqual(bars[0].week, bars[1].week, "different reset days fall in the same week")
        XCTAssertEqual(bars[2].week, bars[0].week + week)
        XCTAssertEqual(bars.map(\.isLowerBound), [false, true, false])
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

    func estimate(_ w: WindowObservation, eta: Date?) -> WindowEstimate {
        WindowEstimate(window: w, value: .exact(w.percent), nextReset: .known(w.resetsAt ?? t0),
                       observedAt: t0, limitETA: eta)
    }
}
