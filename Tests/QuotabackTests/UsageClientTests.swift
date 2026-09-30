import XCTest
@testable import Quotaback

/// レスポンス形式は推測ベース（CLAUDE.md 参照）。実レスポンスが取れたらここのサンプルも差し替える。
final class UsageClientTests: XCTestCase {
    func testParsePicksUpObjectsWithUtilization() throws {
        let json = """
        {
          "five_hour": {"utilization": 13.0, "resets_at": "2026-10-01T05:00:00.123+00:00"},
          "seven_day": {"utilization": 43, "resets_at": "2026-10-04T00:00:00Z"},
          "seven_day_fable": {"utilization": 20.5, "resets_at": null},
          "extra_usage": {"utilization": 28.9},
          "unrelated": {"foo": 1},
          "plan": "max"
        }
        """.data(using: .utf8)!

        let windows = try UsageClient.parse(json)

        XCTAssertEqual(windows.map(\.key).prefix(3), ["five_hour", "seven_day", "seven_day_fable"])
        XCTAssertEqual(windows.last?.key, "extra_usage")
        XCTAssertEqual(windows.count, 4)
        XCTAssertEqual(windows[0].utilization, 13.0)
        XCTAssertNotNil(windows[0].resetsAt, "fractional seconds")
        XCTAssertNotNil(windows[1].resetsAt, "no fractional seconds")
        XCTAssertNil(windows[2].resetsAt)
    }

    func testParseRejectsNonObject() {
        XCTAssertThrowsError(try UsageClient.parse("[]".data(using: .utf8)!))
    }

    func testTitlesAndLimits() {
        func w(_ key: String) -> UsageWindow { UsageWindow(key: key, utilization: 0, resetsAt: nil) }
        XCTAssertEqual(w("five_hour").title, "Current session")
        XCTAssertEqual(w("seven_day").title, "Current week (all models)")
        XCTAssertEqual(w("seven_day_fable").title, "Current week (Fable)")
        XCTAssertEqual(w("extra_usage").title, "Usage credits")
        XCTAssertTrue(w("five_hour").isLimit)
        XCTAssertTrue(w("seven_day_fable").isLimit)
        XCTAssertFalse(w("extra_usage").isLimit)
    }
}
