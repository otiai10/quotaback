import XCTest
@testable import Quotaback

final class UsageClientTests: XCTestCase {
    /// A trimmed real response (2026-10, personal account)
    static let real = """
    {
      "five_hour": {"utilization": 13.0, "resets_at": "2026-10-01T05:40:00.195640+00:00"},
      "seven_day": {"utilization": 58.0, "resets_at": "2026-10-06T02:00:00.195662+00:00"},
      "seven_day_opus": null,
      "extra_usage": {"is_enabled": true, "monthly_limit": 0, "used_credits": 0.0, "utilization": null},
      "limits": [
        {"kind": "session", "group": "session", "percent": 13, "severity": "normal",
         "resets_at": "2026-10-01T05:40:00.195640+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_all", "group": "weekly", "percent": 58, "severity": "normal",
         "resets_at": "2026-10-06T02:00:00.195662+00:00", "scope": null, "is_active": true},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 19, "severity": "normal",
         "resets_at": "2026-10-06T02:00:00.195858+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false}
      ],
      "spend": {
        "used": {"amount_minor": 0, "currency": "USD", "exponent": 2},
        "limit": {"amount_minor": 0, "currency": "USD", "exponent": 2},
        "percent": 0, "enabled": true
      }
    }
    """

    func testParseLimits() throws {
        let windows = try UsageClient.parse(Data(Self.real.utf8))

        XCTAssertEqual(windows.map(\.title),
                       ["Current session", "Current week (all models)", "Current week (Fable)"])
        XCTAssertEqual(windows.map(\.utilization), [13, 58, 19])
        XCTAssertEqual(windows.map(\.key), ["session", "weekly_all", "weekly_scoped/Fable"])
        XCTAssertTrue(windows.allSatisfy(\.isLimit))
        XCTAssertTrue(windows.allSatisfy { $0.resetsAt != nil })
    }

    func testSpendWithLimitBecomesCreditsRow() throws {
        let json = """
        {"limits": [],
         "spend": {"used": {"amount_minor": 5797, "currency": "USD", "exponent": 2},
                   "limit": {"amount_minor": 20000, "currency": "USD", "exponent": 2},
                   "percent": 29, "enabled": true}}
        """
        let windows = try UsageClient.parse(Data(json.utf8))

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].title, "Usage credits")
        XCTAssertEqual(windows[0].detail, "$57.97 / $200.00")
        XCTAssertEqual(windows[0].utilization, 29)
        XCTAssertFalse(windows[0].isLimit)
    }

    func testLegacyFallbackWithoutLimits() throws {
        let json = """
        {"seven_day": {"utilization": 43, "resets_at": "2026-10-04T00:00:00Z"},
         "five_hour": {"utilization": 13.0, "resets_at": "2026-10-01T05:00:00.123+00:00"},
         "seven_day_fable": {"utilization": 20.5, "resets_at": null}}
        """
        let windows = try UsageClient.parse(Data(json.utf8))

        XCTAssertEqual(windows.map(\.title),
                       ["Current session", "Current week (all models)", "Current week (Fable)"])
        XCTAssertNotNil(windows[0].resetsAt)
        XCTAssertNotNil(windows[1].resetsAt)
        XCTAssertNil(windows[2].resetsAt)
    }

    func testResetTimesRoundToNearestMinute() {
        let a = UsageClient.parseDate("2026-10-05T19:59:59.845644+00:00")
        let b = UsageClient.parseDate("2026-10-05T20:00:00+00:00")
        let c = UsageClient.parseDate("2026-10-05T20:00:00.195640+00:00")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
        XCTAssertNil(UsageClient.parseDate(nil))
    }

    func testParseRejectsNonObject() {
        XCTAssertThrowsError(try UsageClient.parse(Data("[]".utf8)))
    }
}
