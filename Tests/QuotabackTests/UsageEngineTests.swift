import XCTest
@testable import Quotaback

/// テスト用の観測対象。持ち主と認証情報を別々に差し替えられる（= /login の途中を再現できる）
final class FakeTarget: @unchecked Sendable {
    var owner: String?
    var stamp: Date?
    var token = "token-a"
    var percent: Double = 10
    var ownerAfterFetch: String??   // 取得中に持ち主が変わる状況を再現
    var error: Error?

    init(owner: String?) { self.owner = owner; self.stamp = t0 }

    var target: PollTarget {
        PollTarget(provider: "claude", id: "fake", description: "Fake",
                   owner: { self.owner }, ownerStamp: { self.stamp },
                   fetch: {
                       if let e = self.error { throw e }
                       if let o = self.ownerAfterFetch { self.owner = o }
                       return FetchedUsage(windows: [window(percent: self.percent, resetsAt: t0 + day)],
                                           credentialFingerprint: CredentialSource.fingerprint(self.token))
                   })
    }
}

final class UsageEngineTests: XCTestCase {
    let accounts = [AccountConfig(label: "P", name: "p@example.com"),
                    AccountConfig(label: "W", name: "w@example.com")]

    func engine() throws -> UsageEngine {
        UsageEngine(log: ObservationLog.load(directory: try tempDirectory(), now: t0))
    }

    func testSwitchingLoginKeepsLastValueAsLowerBound() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "w@example.com")
        f.percent = 40
        await e.refresh([f.target], now: { t0 })

        // P にログインし直す（持ち主も認証情報も更新された）
        f.owner = "p@example.com"; f.token = "token-b"; f.percent = 15
        await e.refresh([f.target], now: { t0 + 600 })

        let views = await e.accountViews(config: accounts, now: t0 + 700)
        XCTAssertEqual(views.map(\.menuBarText), ["P 15%", "W ≥40%"])
        XCTAssertEqual(views[1].observedAt, t0)
    }

    func testSkipsWhenCredentialStillBelongsToPreviousOwner() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "w@example.com")
        f.percent = 40
        await e.refresh([f.target], now: { t0 })

        // .claude.json は P に変わったが、Keychain のトークンはまだ W のまま
        f.owner = "p@example.com"; f.percent = 41
        let reports = await e.refresh([f.target], now: { t0 + 600 })

        guard case .skipped = reports[0].outcome else { return XCTFail("\(reports[0].outcome)") }
        let views = await e.accountViews(config: accounts, now: t0 + 700)
        XCTAssertNil(views[0].observedAt, "P には記録されない")
        XCTAssertEqual(views[1].windows.first?.window.percent, 40)
    }

    func testSkipsWhenOwnerChangesDuringFetch() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "w@example.com")
        f.ownerAfterFetch = .some("p@example.com")
        let reports = await e.refresh([f.target], now: { t0 })

        guard case .skipped = reports[0].outcome else { return XCTFail("\(reports[0].outcome)") }
        let views = await e.accountViews(config: accounts, now: t0)
        XCTAssertTrue(views.allSatisfy { $0.observedAt == nil })
    }

    func testFailureKeepsPreviousValueAndShowsError() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "w@example.com")
        f.percent = 40
        await e.refresh([f.target], now: { t0 })
        f.error = UsageError.tokenExpired
        await e.refresh([f.target], now: { t0 + 600 })

        let w = await e.accountViews(config: accounts, now: t0 + 700)[1]
        XCTAssertFalse(w.isLive)
        XCTAssertNotNil(w.error)
        XCTAssertEqual(w.menuBarText, "W ≥40%")
    }

    func testUnknownOwnerAndUnconfiguredAccountAreListed() async throws {
        let e = try engine()
        let unknown = FakeTarget(owner: nil)
        await e.refresh([unknown.target], now: { t0 })
        let other = FakeTarget(owner: "x@example.com")
        other.token = "token-x"
        await e.refresh([other.target], now: { t0 + 1 })

        let views = await e.accountViews(config: accounts, now: t0 + 2)
        XCTAssertEqual(views.count, 4)
        XCTAssertEqual(views.dropFirst(2).map(\.label), ["?", "?"])
    }

    func testChangedTargetsDetectsLoginSwitch() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "w@example.com")
        await e.refresh([f.target], now: { t0 })

        var changed = await e.changedTargets([f.target])
        XCTAssertTrue(changed.isEmpty, "何も変わっていない")

        f.stamp = t0 + 10   // .claude.json が書き換わったが持ち主は同じ
        changed = await e.changedTargets([f.target])
        XCTAssertTrue(changed.isEmpty)

        f.stamp = t0 + 20; f.owner = "p@example.com"
        changed = await e.changedTargets([f.target])
        XCTAssertEqual(changed.map(\.id), ["fake"])

        changed = await e.changedTargets([f.target])
        XCTAssertTrue(changed.isEmpty, "一度検知したら繰り返さない")
    }

    func testResetTransitionsWithoutFetching() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "w@example.com")
        f.percent = 90
        await e.refresh([f.target], now: { t0 })

        let later = await e.accountViews(config: accounts, now: t0 + 2 * day)[1]
        XCTAssertEqual(later.windows.first?.value, .reset)
        XCTAssertEqual(later.windows.first?.nextReset, .projected(t0 + 8 * day))
    }
}
