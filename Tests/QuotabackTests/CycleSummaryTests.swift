import XCTest
@testable import Quotaback

final class CycleSummaryTests: XCTestCase {
    let p = AccountKey(provider: "claude", account: "p@example.com")
    let w = AccountKey(provider: "claude", account: "w@example.com")

    func batch(_ account: AccountKey, at: Date, _ windows: [WindowObservation]) -> ObservationBatch {
        ObservationBatch(account: account, observedAt: at, source: "test", windows: windows)
    }

    func fileLines(_ log: ObservationLog) throws -> Int {
        guard FileManager.default.fileExists(atPath: log.cyclesURL.path) else { return 0 }
        return try String(contentsOf: log.cyclesURL, encoding: .utf8).split(separator: "\n").count
    }

    /// AC-1: observing the next cycle (resetsAt 7 days later) summarizes the previous one
    func testNewCycleSummarizesThePreviousOne() throws {
        let dir = try tempDirectory()
        var log = ObservationLog.load(directory: dir, now: t0)
        let r1 = t0 + 2 * day
        log.record(batch(p, at: t0, [window(percent: 40, resetsAt: r1)]))
        log.record(batch(p, at: t0 + hour, [window(percent: 55, resetsAt: r1)]))
        // Same values: only latest is updated, but it is still the cycle's last observation
        log.record(batch(p, at: t0 + 2 * hour, [window(percent: 55, resetsAt: r1 + 0.4)]))
        XCTAssertTrue(log.cycles.isEmpty, "the cycle is still open")

        // Observed 30 seconds after the reset: closed by the later cycle, not by time
        log.record(batch(p, at: r1 + 30, [window(percent: 3, resetsAt: r1 + 7 * day)]))

        XCTAssertEqual(log.cycles.count, 1)
        let s = try XCTUnwrap(log.cycles.first)
        XCTAssertEqual(s.account, p)
        XCTAssertEqual(s.key, "weekly_all")
        XCTAssertEqual(s.cadence, .fixed(7 * day))
        XCTAssertEqual(s.finalPercent, 55)
        XCTAssertEqual(s.peakPercent, 55)
        XCTAssertEqual(s.firstObservedAt, t0)
        XCTAssertEqual(s.lastObservedAt, t0 + 2 * hour)
        XCTAssertEqual(s.observations, 3)
        XCTAssertEqual(try fileLines(log), 1)
        let reloaded = ObservationLog.load(directory: dir, now: r1 + hour).cycles
        XCTAssertEqual(reloaded.map(\.lastObservedAt), [t0 + 2 * hour], "survives a reload without duplicating")
    }

    func testFinalAndPeakDiffer() throws {
        var log = ObservationLog.load(directory: try tempDirectory(), now: t0)
        let r1 = t0 + day
        log.record(batch(p, at: t0, [window(percent: 80, resetsAt: r1)]))
        // A value lower than before (e.g. a correction) is still the final one
        log.record(batch(p, at: t0 + hour, [window(percent: 60, resetsAt: r1)]))
        log.record(batch(p, at: r1 + hour, [window(percent: 1, resetsAt: r1 + 7 * day)]))

        XCTAssertEqual(log.cycles.map(\.finalPercent), [60])
        XCTAssertEqual(log.cycles.map(\.peakPercent), [80])
    }

    /// AC-2: reset times 40 seconds apart are one cycle
    func testResetJitterIsOneCycle() throws {
        var log = ObservationLog.load(directory: try tempDirectory(), now: t0)
        let r1 = t0 + day + 10
        log.record(batch(p, at: t0, [window(percent: 10, resetsAt: r1)]))
        log.record(batch(p, at: t0 + hour, [window(percent: 20, resetsAt: r1 + 40)]))
        log.summarizeClosedCycles(now: r1 + 40 + 120)

        XCTAssertEqual(log.cycles.count, 1)
        XCTAssertEqual(log.cycles.first?.observations, 2)
        XCTAssertEqual(log.cycles.first?.finalPercent, 20)
    }

    /// AC-3: windows without resetsAt (an unused session window) aren't summarized
    func testWindowsWithoutResetAreNotSummarized() throws {
        let dir = try tempDirectory()
        var log = ObservationLog.load(directory: dir, now: t0)
        log.record(batch(p, at: t0, [window("session", percent: 0, resetsAt: nil, cadence: .rolling(5 * hour))]))
        log.record(batch(p, at: t0 + day, [window("session", percent: 0, resetsAt: nil, cadence: .rolling(5 * hour))]))
        log.summarizeClosedCycles(now: t0 + 30 * day)

        XCTAssertTrue(log.cycles.isEmpty)
        XCTAssertTrue(ObservationLog.load(directory: dir, now: t0 + 30 * day).cycles.isEmpty)
    }

    /// AC-4: a cycle of an account that isn't logged in closes by time at load
    func testCycleClosesByTimeOnLoad() throws {
        let dir = try tempDirectory()
        var log = ObservationLog.load(directory: dir, now: t0)
        let r1 = t0 + day
        log.record(batch(w, at: t0, [window(percent: 70, resetsAt: r1)]))

        XCTAssertTrue(ObservationLog.load(directory: dir, now: r1 + 30).cycles.isEmpty, "within a minute of the reset")
        let loaded = ObservationLog.load(directory: dir, now: r1 + 120)
        XCTAssertEqual(loaded.cycles.map(\.account), [w])
        XCTAssertEqual(loaded.cycles.map(\.finalPercent), [70])
    }

    /// AC-5: cycles.jsonl is backfilled from observations.jsonl once
    func testBackfillsOnceFromHistory() throws {
        let dir = try tempDirectory()
        var log = ObservationLog.load(directory: dir, now: t0)
        let r1 = t0 + day, r2 = r1 + 7 * day
        log.record(batch(p, at: t0, [window(percent: 30, resetsAt: r1)]))
        log.record(batch(p, at: r1 + hour, [window(percent: 5, resetsAt: r2)]))
        log.record(batch(p, at: r1 + 2 * hour, [window(percent: 9, resetsAt: r2)]))
        try FileManager.default.removeItem(at: log.cyclesURL)

        let first = ObservationLog.load(directory: dir, now: r2 + hour)
        XCTAssertEqual(first.cycles.map(\.finalPercent), [30, 9])
        let second = ObservationLog.load(directory: dir, now: r2 + 2 * hour)
        XCTAssertEqual(second.cycles.count, 2)
        XCTAssertEqual(try fileLines(second), 2, "no duplicate rows")
    }

    /// AC-6: rebuildCycles replaces the summaries with ones made from the raw log
    func testRebuildReplacesSummariesFromRawLog() throws {
        let dir = try tempDirectory()
        var log = ObservationLog.load(directory: dir, now: t0)
        let r1 = t0 + day
        log.record(batch(p, at: t0, [window(percent: 30, resetsAt: r1)]))
        log.record(batch(p, at: r1 + hour, [window(percent: 5, resetsAt: r1 + 7 * day)]))

        // A wrong row within the raw log's range, and an old row the raw log no longer covers
        let wrong = CycleSummary(account: w, key: "weekly_all", title: "weekly_all", cadence: .fixed(7 * day),
                                 resetsAt: r1 + 6 * hour, firstObservedAt: t0 + hour, lastObservedAt: t0 + 2 * hour,
                                 finalPercent: 99, peakPercent: 99, observations: 2)
        var old = wrong
        old.account = p; old.resetsAt = t0 - 30 * day; old.firstObservedAt = t0 - 35 * day
        old.lastObservedAt = t0 - 31 * day; old.finalPercent = 77
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var text = try String(contentsOf: log.cyclesURL, encoding: .utf8)
        for s in [wrong, old] { text += String(decoding: try enc.encode(s), as: UTF8.self) + "\n" }
        try Data(text.utf8).write(to: log.cyclesURL)

        var reloaded = ObservationLog.load(directory: dir, now: r1 + 2 * hour)
        XCTAssertEqual(reloaded.cycles.count, 3)
        XCTAssertEqual(reloaded.rebuildCycles(now: r1 + 2 * hour), 2)

        XCTAssertEqual(reloaded.cycles.map(\.finalPercent).sorted(), [30, 77])
        XCTAssertFalse(reloaded.cycles.contains { $0.account == w }, "the wrong row is gone")
        XCTAssertEqual(try fileLines(reloaded), 2)
        XCTAssertEqual(ObservationLog.load(directory: dir, now: r1 + 3 * hour).cycles, reloaded.cycles)
    }

    /// AC-7: summaries aren't pruned with the raw log, and a cycle is summarized before its observations are pruned
    func testSummariesOutliveRetention() throws {
        let dir = try tempDirectory()
        var log = ObservationLog.load(directory: dir, now: t0)
        log.record(batch(p, at: t0, [window(percent: 42, resetsAt: t0 + day)]))

        // Loaded for the first time 40 days later: summarized from the observation, then the observation is pruned
        let later = ObservationLog.load(directory: dir, now: t0 + 40 * day)
        XCTAssertTrue(later.history.isEmpty)
        XCTAssertEqual(later.cycles.map(\.finalPercent), [42])
        XCTAssertEqual(ObservationLog.load(directory: dir, now: t0 + 400 * day).cycles.map(\.finalPercent), [42])
    }

    func testSeparatesAccountsAndWindows() throws {
        var log = ObservationLog.load(directory: try tempDirectory(), now: t0)
        let r = t0 + day
        log.record(batch(p, at: t0, [window(percent: 10, resetsAt: r), window("weekly_scoped/Fable", percent: 20, resetsAt: r)]))
        log.record(batch(w, at: t0, [window(percent: 30, resetsAt: r)]))
        log.summarizeClosedCycles(now: r + hour)

        XCTAssertEqual(log.cycles.map { "\($0.account.account) \($0.key) \(Int($0.finalPercent))" },
                       ["p@example.com weekly_all 10", "p@example.com weekly_scoped/Fable 20", "w@example.com weekly_all 30"])
    }
}
