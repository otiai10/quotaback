import XCTest
@testable import Quotaback

/// テスト用の観測対象。持ち主と認証情報を別々に差し替えられる（= /login の途中を再現できる）
final class FakeTarget: @unchecked Sendable {
    var owner: String?
    var stamp: Date?
    var token = "token-a"
    var percent: Double = 10
    var asOf: Date?
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
        XCTAssertFalse(text.contains("token-"), "トークンは書かない")
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
        XCTAssertTrue(text.hasPrefix("x"), "行の途中から始まらない")
    }

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

    /// Keychain が先に書き換わった場合: P の新しいトークンが W として記録されてしまうが、
    /// 同じトークンが P を名乗り続ければ P を正とし、W に記録した分は取り消す
    func testCredentialWrittenBeforeOwnerIsCorrected() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "w@example.com")
        f.percent = 40
        await e.refresh([f.target], now: { t0 })
        // Keychain だけ P の新しいトークンになった状態で取得 → W として記録されてしまう
        f.token = "token-p"; f.percent = 15
        await e.refresh([f.target], now: { t0 + 300 })
        // .claude.json も P に
        f.owner = "p@example.com"
        let first = await e.refresh([f.target], now: { t0 + 310 })
        guard case .skipped = first[0].outcome else { return XCTFail("\(first[0].outcome)") }
        // 少し後でも同じ組み合わせ → P として記録し、W の取り違えを取り消す
        let second = await e.refresh([f.target], now: { t0 + 310 + UsageEngine.conflictSettle })
        guard case .recorded = second[0].outcome else { return XCTFail("\(second[0].outcome)") }

        let views = await e.accountViews(config: accounts, now: t0 + 400)
        XCTAssertEqual(views.map(\.menuBarText), ["P 15%", "W ≥40%"])
        XCTAssertEqual(views[1].observedAt, t0, "W は取り違える前の観測に戻る")
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
        XCTAssertEqual(views.dropFirst(2).map(\.label).sorted(), ["?", "X"], "持ち主不明は ?、設定に無いアカウントは頭文字")
        XCTAssertEqual(views.first?.title, "P", "ラベルがあればメールアドレスの代わりに出す")
        XCTAssertEqual(views.first { $0.label == "X" }?.title, "x", "ラベルが無ければメールの @ より前")
    }

    func testEmojiIsMenuBarMarkAndPrefixesTitle() async throws {
        let e = try engine()
        let config = [AccountConfig(email: "p@example.com", emoji: "🏈", label: "Personal"),
                      AccountConfig(email: "w@example.com", emoji: "💼"),
                      AccountConfig(email: "x@example.com", label: "Extra")]
        let views = await e.accountViews(config: config, now: t0)
        XCTAssertEqual(views.map(\.label), ["🏈", "💼", "Extra"], "メニューバーは emoji、無ければ label")
        XCTAssertEqual(views.map(\.title), ["🏈 Personal", "💼 w", "Extra"])
    }

    func testTitleFallsBackToFullEmailWhenLocalPartsCollide() async throws {
        let e = try engine()
        let config = [AccountConfig(email: "me@home.example"),
                      AccountConfig(email: "me@work.example"),
                      AccountConfig(email: "me@home.example", provider: "codex"),   // 同じメールなら重なりではない
                      AccountConfig(email: "solo@example.com")]
        let views = await e.accountViews(config: config, now: t0)
        XCTAssertEqual(views.map(\.title), ["me@home.example", "me@work.example", "me@home.example", "solo"])
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
        XCTAssertEqual(view([session, weekly, credits]).representative?.window.key, "weekly_all", "credits は対象外")
        XCTAssertEqual(view([session, weekly]).peak, 61)

        let tieSession = est("session", 40, reset: t0 + hour)
        let tieWeekly = est("weekly_all", 40, reset: t0 + 5 * day)
        XCTAssertEqual(view([tieSession, tieWeekly]).representative?.window.key, "weekly_all", "同値ならリセットが遠い方")
        XCTAssertNil(view([credits]).representative)
    }

    func testLiveButStaleValueIsLowerBound() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "p@example.com")
        f.percent = 30
        f.asOf = t0 - hour   // ログから読んだ1時間前の記録
        await e.refresh([f.target], now: { t0 })

        let p = await e.accountViews(config: accounts, now: t0)[0]
        XCTAssertTrue(p.isLive, "ログイン中ではある")
        XCTAssertEqual(p.observedAt, t0 - hour, "観測時刻は記録の時刻")
        XCTAssertEqual(p.windows.first?.value, .atLeast(30))
        XCTAssertEqual(p.menuBarText, "P ≥30%")

        f.asOf = t0 - 60
        await e.refresh([f.target], now: { t0 })
        let fresh = await e.accountViews(config: accounts, now: t0)[0]
        XCTAssertEqual(fresh.windows.first?.value, .exact(30), "10分以内の記録なら今の値とみなす")
    }

    func testNoObservationKeepsAccountLiveWithoutError() async throws {
        let e = try engine()
        let f = FakeTarget(owner: "p@example.com")
        f.percent = 30
        await e.refresh([f.target], now: { t0 })
        f.error = UsageError.noObservation("まだ記録なし")
        let r = await e.refresh([f.target], now: { t0 + hour })
        guard case .unchanged = r[0].outcome else { return XCTFail("\(r[0].outcome)") }

        let p = await e.accountViews(config: accounts, now: t0 + hour)[0]
        XCTAssertTrue(p.isLive)
        XCTAssertNil(p.error)
        XCTAssertEqual(p.windows.first?.value, .atLeast(30), "前回の観測は古いので下限")
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
