import XCTest
@testable import Quotaback

final class PollScheduleTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let p = AccountKey(provider: "claude", account: "p@example.com")

    func batch(_ windows: [WindowObservation]) -> ObservationBatch {
        ObservationBatch(account: p, observedAt: now, source: "test", windows: windows)
    }

    func window(_ key: String, _ percent: Double, resetsIn: TimeInterval? = 3600, isLimit: Bool = true) -> WindowObservation {
        WindowObservation(key: key, title: key, percent: percent, resetsAt: resetsIn.map { now + $0 },
                          isLimit: isLimit, detail: nil, cadence: .fixed(7 * 86400))
    }

    func testRegularBelowThreshold() {
        XCTAssertEqual(PollSchedule.interval(after: batch([window("session", 69), window("weekly_all", 40)]), now: now),
                       PollSchedule.regular)
    }

    func testNearLimitAtThreshold() {
        XCTAssertEqual(PollSchedule.interval(after: batch([window("session", 10), window("weekly_all", 70)]), now: now),
                       PollSchedule.nearLimit)
    }

    func testNoObservationIsRegular() {
        XCTAssertEqual(PollSchedule.interval(after: nil, now: now), PollSchedule.regular)
    }

    /// Usage credits (not a usage limit) and windows already past their reset don't tighten the schedule
    func testIgnoresNonLimitAndResetWindows() {
        let b = batch([window("spend", 95, isLimit: false), window("session", 90, resetsIn: -60)])
        XCTAssertEqual(PollSchedule.interval(after: b, now: now), PollSchedule.regular)
    }

    /// A logged-in value observed on the regular schedule must still count as exact until the next observation
    func testFreshnessCoversRegularInterval() {
        XCTAssertGreaterThan(UsageEngine.freshness, PollSchedule.regular)
        XCTAssertGreaterThan(AnalyticsModel.lowerBoundGap, PollSchedule.regular)
    }
}
