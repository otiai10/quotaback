import XCTest
@testable import Quotaback

final class ObservationLogTests: XCTestCase {
    let p = AccountKey(provider: "claude", account: "P@example.com")
    let w = AccountKey(provider: "claude", account: "w@example.com")

    func batch(_ account: AccountKey, at: Date, _ windows: [WindowObservation]) -> ObservationBatch {
        ObservationBatch(account: account, observedAt: at, source: "test", windows: windows)
    }

    func testAccountKey() {
        XCTAssertEqual(p.id, "claude:p@example.com")
        XCTAssertEqual(AccountKey(id: "claude:p@example.com"), p)
        XCTAssertNil(AccountKey(id: "nocolon"))
    }

    func testRecordPersistsLatestAndDedupesHistory() throws {
        let dir = try tempDirectory()
        var log = ObservationLog.load(directory: dir, now: t0)
        let reset = t0 + day
        log.record(batch(p, at: t0, [window(percent: 10, resetsAt: reset)]))
        // 値が同じ（resets_at の秒未満の揺れだけ）→ 履歴には足さないが latest は更新
        log.record(batch(p, at: t0 + 300, [window(percent: 10, resetsAt: reset + 0.2)]))
        log.record(batch(p, at: t0 + 600, [window(percent: 12, resetsAt: reset)]))
        log.record(batch(w, at: t0 + 600, [window(percent: 50, resetsAt: reset)]))

        XCTAssertEqual(log.history.count, 3)
        XCTAssertEqual(log.latest[p]?.observedAt, t0 + 600)

        let reloaded = ObservationLog.load(directory: dir, now: t0 + hour)
        XCTAssertEqual(reloaded.latest, log.latest)
        XCTAssertEqual(reloaded.history.count, 3)
        XCTAssertEqual(reloaded.latest[p]?.observedAt, t0 + 600, "鮮度は再起動後も残る")
    }

    func testPointsStayWithinResetCycle() throws {
        var log = ObservationLog.load(directory: try tempDirectory(), now: t0)
        let cycle1 = t0 + day, cycle2 = t0 + 8 * day
        log.record(batch(p, at: t0, [window(percent: 70, resetsAt: cycle1)]))
        log.record(batch(p, at: t0 + 2 * day, [window(percent: 5, resetsAt: cycle2)]))
        log.record(batch(p, at: t0 + 2 * day + hour, [window(percent: 9, resetsAt: cycle2 + 0.3)]))

        let pts = log.points(account: p, window: window(percent: 9, resetsAt: cycle2))
        XCTAssertEqual(pts.map(\.1), [5, 9])
    }

    func testPrunesOldHistory() throws {
        let dir = try tempDirectory()
        var log = ObservationLog.load(directory: dir, now: t0)
        log.record(batch(p, at: t0, [window(percent: 1, resetsAt: nil)]))
        log.record(batch(p, at: t0 + 40 * day, [window(percent: 2, resetsAt: nil)]))

        let reloaded = ObservationLog.load(directory: dir, now: t0 + 40 * day)
        XCTAssertEqual(reloaded.history.map(\.observedAt), [t0 + 40 * day])
        let text = try String(contentsOf: reloaded.historyURL, encoding: .utf8)
        XCTAssertEqual(text.split(separator: "\n").count, 1, "ファイルも間引かれる")
    }

    func testImportsLegacyStateJSON() throws {
        let dir = try tempDirectory()
        let json = """
        {"W@Example.com": {"fetchedAt": "2026-10-01T02:00:00Z",
          "windows": [{"key": "weekly_scoped/Fable", "title": "Current week (Fable)", "utilization": 19,
                       "resetsAt": "2026-10-06T02:00:00Z", "isLimit": true}]}}
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("state.json"))

        let log = ObservationLog.load(directory: dir)

        let b = try XCTUnwrap(log.latest[w])
        XCTAssertEqual(b.windows.first?.percent, 19)
        XCTAssertEqual(b.windows.first?.cadence, .fixed(7 * day))
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.latestURL.path))
    }
}
