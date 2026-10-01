import XCTest
@testable import Quotaback

final class EstimatorTests: XCTestCase {
    func testLiveBeforeResetIsExact() {
        let e = Estimator.estimate(window(percent: 43, resetsAt: t0 + day), observedAt: t0, isLive: true, now: t0 + hour)
        XCTAssertEqual(e.value, .exact(43))
        XCTAssertEqual(e.nextReset, .known(t0 + day))
        XCTAssertEqual(e.lowerBound, 43)
    }

    func testNotLiveBeforeResetIsLowerBound() {
        let e = Estimator.estimate(window(percent: 43, resetsAt: t0 + day), observedAt: t0, isLive: false, now: t0 + hour)
        XCTAssertEqual(e.value, .atLeast(43))
        XCTAssertEqual(e.nextReset, .known(t0 + day))
    }

    func testFixedCadenceAfterResetProjectsNext() {
        let w = window(percent: 80, resetsAt: t0 + day, cadence: .fixed(7 * day))
        // 1回目のリセット直後 → 次は +7日
        let a = Estimator.estimate(w, observedAt: t0, isLive: false, now: t0 + 2 * day)
        XCTAssertEqual(a.value, .reset)
        XCTAssertEqual(a.nextReset, .projected(t0 + 8 * day))
        XCTAssertEqual(a.lowerBound, 0)
        // 2周以上経過 → 今より後の最初の周期
        let b = Estimator.estimate(w, observedAt: t0, isLive: false, now: t0 + 16 * day)
        XCTAssertEqual(b.nextReset, .projected(t0 + 22 * day))
        // ちょうどリセット時刻 → リセット済み、次は +7日
        let c = Estimator.estimate(w, observedAt: t0, isLive: true, now: t0 + day)
        XCTAssertEqual(c.value, .reset)
        XCTAssertEqual(c.nextReset, .projected(t0 + 8 * day))
    }

    func testRollingCadenceAfterResetIsUnknown() {
        let w = window("session", percent: 90, resetsAt: t0 + hour, cadence: .rolling(5 * hour))
        let e = Estimator.estimate(w, observedAt: t0, isLive: true, now: t0 + 2 * hour)
        XCTAssertEqual(e.value, .reset)
        XCTAssertEqual(e.nextReset, .unknown)
    }

    func testMonthlyCadenceProjectsByCalendarMonth() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let nov1 = cal.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let dec1 = cal.date(from: DateComponents(year: 2026, month: 12, day: 1))!
        let w = window("spend", percent: 10, resetsAt: nov1, cadence: .monthly, isLimit: false)
        let e = Estimator.estimate(w, observedAt: nov1 - day, isLive: false, now: nov1 + 3 * day, calendar: cal)
        XCTAssertEqual(e.nextReset, .projected(dec1))
    }

    func testNoResetTimeIsUnknown() {
        let e = Estimator.estimate(window(percent: 10, resetsAt: nil), observedAt: t0, isLive: true, now: t0)
        XCTAssertEqual(e.value, .exact(10))
        XCTAssertEqual(e.nextReset, .unknown)
    }

    func testLimitETA() {
        // 1時間で 40% → 60%: 残り 40% は 2時間後
        let pts = [(t0, 40.0), (t0 + hour, 60.0)]
        XCTAssertEqual(Estimator.limitETA(history: pts, resetsAt: t0 + day), t0 + 3 * hour)
        XCTAssertNil(Estimator.limitETA(history: pts, resetsAt: t0 + 2 * hour), "リセットの方が先")
        XCTAssertNil(Estimator.limitETA(history: [(t0, 40.0), (t0 + 300, 60.0)], resetsAt: nil), "10分未満")
        XCTAssertNil(Estimator.limitETA(history: [(t0, 40.0), (t0 + hour, 40.0)], resetsAt: nil), "増えていない")
        XCTAssertNil(Estimator.limitETA(history: [(t0, 40.0)], resetsAt: nil))
    }

    func testETAOnlyForLimitWindowsBeforeReset() {
        let pts = [(t0, 40.0), (t0 + hour, 60.0)]
        let limit = Estimator.estimate(window(percent: 60, resetsAt: t0 + day), observedAt: t0 + hour,
                                       isLive: true, history: pts, now: t0 + hour)
        XCTAssertEqual(limit.limitETA, t0 + 3 * hour)
        let credits = Estimator.estimate(window("spend", percent: 60, resetsAt: t0 + day, isLimit: false),
                                         observedAt: t0 + hour, isLive: true, history: pts, now: t0 + hour)
        XCTAssertNil(credits.limitETA)
        let notLive = Estimator.estimate(window(percent: 60, resetsAt: t0 + day), observedAt: t0 + hour,
                                         isLive: false, history: pts, now: t0 + hour)
        XCTAssertNil(notLive.limitETA, "ログインしていないアカウントのペースは出さない")
        let past = Estimator.estimate(window(percent: 60, resetsAt: t0 + day), observedAt: t0 + hour,
                                      isLive: true, history: pts, now: t0 + 4 * hour)
        XCTAssertNil(past.limitETA, "見込み時刻を過ぎていたら出さない")
    }
}
