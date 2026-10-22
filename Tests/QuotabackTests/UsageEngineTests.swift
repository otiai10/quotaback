import XCTest
@testable import Quotaback

/// A test poll target. Owner and credentials can be swapped independently (to reproduce a /login in progress)
final class FakeTarget: @unchecked Sendable {
    var owner: String?
    var stamp: Date?
    var token = "token-a"
    var percent: Double = 10
    var resetsAt = t0 + day
    var asOf: Date?
    var ownerAfterFetch: String??   // Simulates the owner changing during a fetch
    var error: Error?

    init(owner: String?) { self.owner = owner; self.stamp = t0 }

    var target: PollTarget {
        PollTarget(provider: "claude", id: "fake", description: "Fake",
                   owner: { self.owner }, ownerStamp: { self.stamp },
                   fetch: {
                       if let e = self.error { throw e }
                       if let o = self.ownerAfterFetch { self.owner = o }
                       return FetchedUsage(windows: [window(percent: self.percent, resetsAt: self.resetsAt)],
                                           credentialFingerprint: CredentialSource.fingerprint(self.token),
                                           asOf: self.asOf)
                   })
    }
}

final class UsageEngineTests: XCTestCase {
    let accounts = [AccountConfig(email: "p@example.com", label: "P"),
                    AccountConfig(email: "w@example.com", label: "W")]

    override func setUpWithError() throws {
        ActivityLog.url = try tempDirectory().appendingPathComponent("activity.log")
    }

    func testActivityLogRecordsSwitchAndOutcome() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "w@example.com")
        await e.refresh([f.target], reason: "start", now: { t0 })
        f.stamp = t0 + 10; f.owner = "p@example.com"; f.token = "token-p"
        _ = await e.changedTargets([f.target])
        ActivityLog.flush()

        let text = try String(contentsOf: ActivityLog.url, encoding: .utf8)
        XCTAssertTrue(text.contains("refresh(start) Fake owner=w@example.com → recorded weekly_all=10"), text)
        XCTAssertTrue(text.contains("switch Fake w@example.com → p@example.com"), text)
        XCTAssertFalse(text.contains("token-"), "tokens are not written")
    }

    func testActivityLogTrimsOldHalf() throws {
        ActivityLog.url = try tempDirectory().appendingPathComponent("activity.log")
        let line = String(repeating: "x", count: 99) + "\n"
        try Data(String(repeating: line, count: ActivityLog.maxBytes / 100 + 10).utf8).write(to: ActivityLog.url)
        ActivityLog.write("newest")
        ActivityLog.flush()

        let text = try String(contentsOf: ActivityLog.url, encoding: .utf8)
        XCTAssertLessThan(text.utf8.count, ActivityLog.maxBytes)
        XCTAssertTrue(text.hasSuffix("newest\n"))
        XCTAssertTrue(text.hasPrefix("x"), "does not start mid-line")
    }

    func engine() throws -> UsageEngine {
        UsageEngine(log: ObservationLog.load(directory: try tempDirectory(), now: t0))
    }

    func testThrottlingKeepsConfirmedOwnerButDoesNotInventNewOwner() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "p@example.com")
        await e.refresh([f.target], now: { t0 })
        f.error = UsageError.deferred(t0 + 300, rateLimited: true)
        await e.refresh([f.target], now: { t0 + 20 })
        let views = await e.accountViews(config: accounts, now: t0 + 20)
        XCTAssertTrue(views[0].isLive)
        XCTAssertEqual(views[0].observedAt, t0)
        XCTAssertNil(views[0].error, "waiting is not an error")
        XCTAssertEqual(views[0].pausedUntil, t0 + 300)
        f.owner = "w@example.com"
        await e.refresh([f.target], now: { t0 + 30 })
        let switched = await e.accountViews(config: accounts, now: t0 + 30)
        XCTAssertFalse(switched[0].isLive)
        XCTAssertFalse(switched[1].isLive)
        XCTAssertNil(switched[0].error)
        XCTAssertNil(switched[0].pausedUntil, "the pause follows the target, not the previous owner")
        XCTAssertEqual(switched[1].pausedUntil, t0 + 300, "the gate holds every account back, so W shows the pause too")
    }

    func testRateLimitIsShownAsPauseNotErrorAndExpiresOnItsOwn() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "p@example.com")
        await e.refresh([f.target], now: { t0 })
        f.error = UsageError.http(500, "boom")
        await e.refresh([f.target], now: { t0 + 10 })
        let errored = await e.accountViews(config: accounts, now: t0 + 10)[0]
        XCTAssertNotNil(errored.error)

        f.error = UsageError.rateLimited(until: t0 + 3600, retryAfter: "3600")
        let reports = await e.refresh([f.target], now: { t0 + 20 })
        guard case .unchanged(let message) = reports[0].outcome else { return XCTFail("a 429 is not a failure") }
        XCTAssertTrue(message.contains("429") && message.contains("Retry-After: 3600"), message)
        let paused = await e.accountViews(config: accounts, now: t0 + 20)[0]
        XCTAssertNil(paused.error, "the pause supersedes the earlier error")
        XCTAssertEqual(paused.pausedUntil, t0 + 3600)
        XCTAssertEqual(paused.observedAt, t0, "the last value stays")

        // The gate's own skips keep the pause but never mention 429
        f.error = UsageError.deferred(t0 + 3600, rateLimited: true)
        let skipped = await e.refresh([f.target], now: { t0 + 40 })
        guard case .unchanged(let skip) = skipped[0].outcome else { return XCTFail() }
        XCTAssertFalse(skip.contains("429"), skip)
        let stillPaused = await e.accountViews(config: accounts, now: t0 + 40)[0]
        XCTAssertEqual(stillPaused.pausedUntil, t0 + 3600)

        // Past the pause and before the next fetch, the note is gone
        let expired = await e.accountViews(config: accounts, now: t0 + 3601)[0]
        XCTAssertNil(expired.pausedUntil)

        f.error = nil
        await e.refresh([f.target], now: { t0 + 3700 })
        let back = await e.accountViews(config: accounts, now: t0 + 3700)[0]
        XCTAssertNil(back.pausedUntil)
        XCTAssertNil(back.error)
    }

    func testSwitchingLoginKeepsLastValueAsLowerBound() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "w@example.com")
        f.percent = 40
        await e.refresh([f.target], now: { t0 })

        // Log back in to P (both owner and credentials updated)
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

        // .claude.json switched to P, but the Keychain token is still W's
        f.owner = "p@example.com"; f.percent = 41
        let reports = await e.refresh([f.target], now: { t0 + 600 })

        guard case .skipped = reports[0].outcome else { return XCTFail("\(reports[0].outcome)") }
        let views = await e.accountViews(config: accounts, now: t0 + 700)
        XCTAssertNil(views[0].observedAt, "nothing is recorded for P")
        XCTAssertEqual(views[1].windows.first?.window.percent, 40)
    }

    /// When the Keychain is updated first: P's new token gets recorded as W,
    /// but if the same token keeps claiming P, P wins and the record under W is retracted
    func testCredentialWrittenBeforeOwnerIsCorrected() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "w@example.com")
        f.percent = 40
        await e.refresh([f.target], now: { t0 })
        // Fetch with only the Keychain holding P's new token → recorded as W
        f.token = "token-p"; f.percent = 15
        await e.refresh([f.target], now: { t0 + 300 })
        // .claude.json switches to P too
        f.owner = "p@example.com"
        let first = await e.refresh([f.target], now: { t0 + 310 })
        guard case .skipped = first[0].outcome else { return XCTFail("\(first[0].outcome)") }
        // Same pairing a bit later → record as P and retract the mix-up under W
        let second = await e.refresh([f.target], now: { t0 + 310 + UsageEngine.conflictSettle })
        guard case .recorded = second[0].outcome else { return XCTFail("\(second[0].outcome)") }

        let views = await e.accountViews(config: accounts, now: t0 + 400)
        XCTAssertEqual(views.map(\.menuBarText), ["P 15%", "W ≥40%"])
        XCTAssertEqual(views[1].observedAt, t0, "W reverts to its observation before the mix-up")
    }

    /// Issue #13: P's token was refreshed (new hash), then only .claude.json switched to W.
    /// The new token's weekly reset time is P's, not W's, so it is not recorded as W
    func testRefreshedTokenOfPreviousOwnerIsNotRecordedAfterSwitch() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "w@example.com")
        let pReset = t0 + day, wReset = t0 + day + 6 * hour
        f.token = "token-w"; f.resetsAt = wReset; f.percent = 25
        await e.refresh([f.target], now: { t0 })
        f.owner = "p@example.com"; f.token = "token-p-old"; f.resetsAt = pReset; f.percent = 60
        await e.refresh([f.target], now: { t0 + hour })
        f.error = UsageError.tokenExpired
        await e.refresh([f.target], now: { t0 + 2 * hour })

        // P's token got refreshed, then /login left only .claude.json pointing at W
        f.error = nil; f.token = "token-p-new"; f.percent = 61; f.stamp = t0 + 3 * hour; f.owner = "w@example.com"
        _ = await e.changedTargets([f.target])
        for dt in [3 * hour, 3 * hour + 300, 4 * hour] {
            let r = await e.refresh([f.target], reason: "switch", now: { t0 + dt })
            guard case .skipped = r[0].outcome else { return XCTFail("\(dt): \(r[0].outcome)") }
        }
        var views = await e.accountViews(config: accounts, now: t0 + 4 * hour)
        XCTAssertEqual(views[1].observedAt, t0, "W keeps its own last observation")
        XCTAssertEqual(views[1].menuBarText, "W ≥25%")
        XCTAssertFalse(views[1].isLive)

        // The skip didn't tie the token to W: back on P, it is recorded right away (no 30s conflict)
        f.owner = "p@example.com"
        let back = await e.refresh([f.target], now: { t0 + 4 * hour + 10 })
        guard case .recorded = back[0].outcome else { return XCTFail("\(back[0].outcome)") }
        views = await e.accountViews(config: accounts, now: t0 + 4 * hour + 10)
        XCTAssertEqual(views.map(\.menuBarText), ["P 61%", "W ≥25%"])

        ActivityLog.flush()
        let text = try String(contentsOf: ActivityLog.url, encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("refresh(switch)") }, text)
        XCTAssertTrue(line.contains("owner=w@example.com → skipped: "), String(line))
        XCTAssertTrue(line.contains("p@example.com"), "the reason names the account the reset time belongs to: \(line)")
    }

    /// A new token whose weekly reset matches the account's own (or its projection after a reset) is recorded
    func testNewTokenWithOwnResetTimeIsRecorded() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "p@example.com")
        let pReset = t0 + day, wReset = t0 + day + 6 * hour
        f.resetsAt = pReset
        await e.refresh([f.target], now: { t0 })
        f.owner = "w@example.com"; f.token = "token-w"; f.resetsAt = wReset
        await e.refresh([f.target], now: { t0 + hour })

        f.token = "token-w-new"; f.percent = 30
        var r = await e.refresh([f.target], now: { t0 + 2 * hour })
        guard case .recorded = r[0].outcome else { return XCTFail("\(r[0].outcome)") }

        // After both resets passed, W's next cycle is still told apart from P's projected one
        f.token = "token-w-next"; f.resetsAt = wReset + 7 * day; f.percent = 1
        r = await e.refresh([f.target], now: { t0 + 2 * day })
        guard case .recorded = r[0].outcome else { return XCTFail("\(r[0].outcome)") }
        f.token = "token-p-leak"; f.resetsAt = pReset + 7 * day
        r = await e.refresh([f.target], now: { t0 + 2 * day + 600 })
        guard case .skipped = r[0].outcome else { return XCTFail("\(r[0].outcome)") }
    }

    /// When P's token, recorded as W over several polls, later claims P and settles, every batch it left under W is retracted
    func testSettledConflictRetractsEveryBatchRecordedWithThatToken() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "w@example.com")
        f.percent = 40
        await e.refresh([f.target], now: { t0 })
        // Nothing of P observed yet, so the reset time can't tell: recorded as W, values changing
        f.token = "token-p"
        for (i, v) in [50.0, 55, 60].enumerated() {
            f.percent = v
            await e.refresh([f.target], now: { t0 + hour * Double(i + 1) })
        }
        f.owner = "p@example.com"
        await e.refresh([f.target], now: { t0 + 4 * hour })
        let settled = await e.refresh([f.target], now: { t0 + 4 * hour + UsageEngine.conflictSettle })
        guard case .recorded = settled[0].outcome else { return XCTFail("\(settled[0].outcome)") }

        let wKey = AccountKey(provider: "claude", account: "w@example.com")
        let log = await e.log
        XCTAssertEqual(log.history.filter { $0.account == wKey }.map(\.observedAt), [t0])
        let views = await e.accountViews(config: accounts, now: t0 + 4 * hour + 60)
        XCTAssertEqual(views.map(\.menuBarText), ["P 60%", "W ≥40%"])
        XCTAssertEqual(views[1].observedAt, t0)
    }

    func testConflictIsNotAcceptedBeforeSettling() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "w@example.com")
        await e.refresh([f.target], now: { t0 })
        f.owner = "p@example.com"
        for dt in [10.0, 20.0] {
            let r = await e.refresh([f.target], now: { t0 + dt })
            guard case .skipped = r[0].outcome else { return XCTFail("\(r[0].outcome)") }
        }
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
        XCTAssertEqual(views.dropFirst(2).map(\.label).sorted(), ["?", "X"], "unknown owner is ?, unconfigured accounts use the initial")
        XCTAssertEqual(views.first?.title, "P", "the label replaces the email when set")
        XCTAssertEqual(views.first { $0.label == "X" }?.title, "x", "without a label, the part of the email before @")
    }

    func testEmojiIsMenuBarMarkAndPrefixesTitle() async throws {
        let e = try engine()
        let config = [AccountConfig(email: "p@example.com", emoji: "🏈", label: "Personal"),
                      AccountConfig(email: "w@example.com", emoji: "💼"),
                      AccountConfig(email: "x@example.com", label: "Extra")]
        let views = await e.accountViews(config: config, now: t0)
        XCTAssertEqual(views.map(\.label), ["🏈", "💼", "Extra"], "menu bar uses emoji, else label")
        XCTAssertEqual(views.map(\.title), ["🏈 Personal", "💼 w", "Extra"])
    }

    func testTitleFallsBackToFullEmailWhenLocalPartsCollide() async throws {
        let e = try engine()
        let config = [AccountConfig(email: "me@home.example"),
                      AccountConfig(email: "me@work.example"),
                      AccountConfig(email: "me@home.example", provider: "codex"),   // The same email is not a collision
                      AccountConfig(email: "solo@example.com")]
        let views = await e.accountViews(config: config, now: t0)
        XCTAssertEqual(views.map(\.title), ["me@home.example", "me@work.example", "me@home.example", "solo"])
    }

    func testChangedTargetsDetectsLoginSwitch() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "w@example.com")
        await e.refresh([f.target], now: { t0 })

        var changed = await e.changedTargets([f.target])
        XCTAssertTrue(changed.isEmpty, "nothing changed")

        f.stamp = t0 + 10   // .claude.json was rewritten but the owner is the same
        changed = await e.changedTargets([f.target])
        XCTAssertTrue(changed.isEmpty)

        f.stamp = t0 + 20; f.owner = "p@example.com"
        changed = await e.changedTargets([f.target])
        XCTAssertEqual(changed.map(\.id), ["fake"])

        changed = await e.changedTargets([f.target])
        XCTAssertTrue(changed.isEmpty, "detected only once")
    }

    func testRepresentativeIsFullestLimitWindow() {
        func est(_ key: String, _ v: Double, reset: Date?, isLimit: Bool = true) -> WindowEstimate {
            Estimator.estimate(window(key, percent: v, resetsAt: reset, isLimit: isLimit),
                               observedAt: t0, isLive: true, now: t0)
        }
        func view(_ ws: [WindowEstimate]) -> AccountView {
            AccountView(key: AccountKey(provider: "claude", account: "p@example.com"), label: "P", title: "P",
                        isLive: true, observedAt: t0, source: nil, error: nil, windows: ws)
        }
        let session = est("session", 30, reset: t0 + hour)
        let weekly = est("weekly_all", 61, reset: t0 + 5 * day)
        let credits = est("spend", 90, reset: nil, isLimit: false)
        XCTAssertEqual(view([session, weekly, credits]).representative?.window.key, "weekly_all", "credits are excluded")
        XCTAssertEqual(view([session, weekly]).peak, 61)

        let tieSession = est("session", 40, reset: t0 + hour)
        let tieWeekly = est("weekly_all", 40, reset: t0 + 5 * day)
        XCTAssertEqual(view([tieSession, tieWeekly]).representative?.window.key, "weekly_all", "on a tie, the later reset wins")
        XCTAssertNil(view([credits]).representative)
    }

    func testLiveButStaleValueIsLowerBound() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "p@example.com")
        f.percent = 30
        f.asOf = t0 - hour   // A record from an hour ago, read from the log
        await e.refresh([f.target], now: { t0 })

        let p = await e.accountViews(config: accounts, now: t0)[0]
        XCTAssertTrue(p.isLive, "still logged in")
        XCTAssertEqual(p.observedAt, t0 - hour, "observed time is the record's time")
        XCTAssertEqual(p.windows.first?.value, .atLeast(30))
        XCTAssertEqual(p.menuBarText, "P ≥30%")

        f.asOf = t0 - 60
        await e.refresh([f.target], now: { t0 })
        let fresh = await e.accountViews(config: accounts, now: t0)[0]
        XCTAssertEqual(fresh.windows.first?.value, .exact(30), "a record within 10 minutes counts as current")
    }

    func testNoObservationKeepsAccountLiveWithoutError() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "p@example.com")
        f.percent = 30
        await e.refresh([f.target], now: { t0 })
        f.error = UsageError.noObservation("no record yet")
        let r = await e.refresh([f.target], now: { t0 + hour })
        guard case .unchanged = r[0].outcome else { return XCTFail("\(r[0].outcome)") }

        let p = await e.accountViews(config: accounts, now: t0 + hour)[0]
        XCTAssertTrue(p.isLive)
        XCTAssertNil(p.error)
        XCTAssertEqual(p.windows.first?.value, .atLeast(30), "the previous observation is stale, so it is a lower bound")
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
