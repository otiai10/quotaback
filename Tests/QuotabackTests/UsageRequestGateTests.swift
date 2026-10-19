import XCTest
@testable import Quotaback

final class UsageRequestGateTests: XCTestCase {
    func testThrottleSurvivesRestartAndDoesNotSlide() async throws {
        let url = try tempDirectory().appendingPathComponent("throttle.json")
        let gate = UsageRequestGate(url: url)
        try await gate.acquire(account: "p@example.com", now: t0)
        let restarted = UsageRequestGate(url: url)
        do {
            try await restarted.acquire(account: "p@example.com", now: t0 + 30)
            XCTFail("待機中のリクエストが通った")
        } catch UsageError.deferred(let until, let limited) {
            XCTAssertEqual(until, t0 + 60)
            XCTAssertFalse(limited)
        }
        try await restarted.acquire(account: "w@example.com", now: t0 + 30)
        try await restarted.acquire(account: "p@example.com", now: t0 + 60)
    }

    func test429BackoffPersistsAndAppliesToOtherAccounts() async throws {
        let url = try tempDirectory().appendingPathComponent("throttle.json")
        let gate = UsageRequestGate(url: url)
        let first = await gate.received(status: 429, retryAfter: nil, now: t0)
        XCTAssertEqual(first, t0 + 300)
        let restarted = UsageRequestGate(url: url)
        do {
            try await restarted.acquire(account: "other@example.com", now: t0 + 299)
            XCTFail("429 の待機を別アカウントで迂回した")
        } catch UsageError.deferred(let until, let limited) {
            XCTAssertEqual(until, t0 + 300)
            XCTAssertTrue(limited)
        }
        try await restarted.acquire(account: "other@example.com", now: t0 + 300)
        let second = await restarted.received(status: 429, retryAfter: nil, now: t0 + 300)
        XCTAssertEqual(second, t0 + 900)
        _ = await restarted.received(status: 200, retryAfter: nil, now: t0 + 900)
        let reset = await restarted.received(status: 429, retryAfter: nil, now: t0 + 960)
        XCTAssertEqual(reset, t0 + 1260)
    }

    func testRetryAfterAndBackoffCap() async throws {
        let gate = UsageRequestGate(url: try tempDirectory().appendingPathComponent("throttle.json"))
        for i in 0..<6 {
            let until = await gate.received(status: 429, retryAfter: nil, now: t0 + Double(i) * 2000)
            XCTAssertEqual(until, t0 + Double(i) * 2000 + min(300 * pow(2, Double(i)), 1800))
        }
        let server = await gate.received(status: 429, retryAfter: "3600", now: t0 + 12000)
        XCTAssertEqual(server, t0 + 15600)
        XCTAssertEqual(UsageRequestGate.retryDate(" Thu, 01 Jan 1970 00:10:00 GMT ", now: t0),
                       Date(timeIntervalSince1970: 600))
        XCTAssertNil(UsageRequestGate.retryDate("invalid", now: t0))
        XCTAssertNil(UsageRequestGate.retryDate("-1", now: t0))
    }
}
