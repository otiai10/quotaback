import XCTest
@testable import Quotaback

final class CodexTests: XCTestCase {
    /// Unsigned JWT (header.payload.signature)
    func jwt(_ claims: [String: Any]) -> String {
        func b64(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        return "\(b64(Data(#"{"alg":"none"}"#.utf8))).\(b64(payload)).sig"
    }

    func makeHome(email: String = "Codex.User@Example.com", lastRefresh: String? = "2026-10-01T00:00:00Z") throws -> CodexHome {
        let dir = try tempDirectory().appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var auth: [String: Any] = ["auth_mode": "chatgpt",
                                   "tokens": ["id_token": jwt(["email": email, "sub": "x"]),
                                              "access_token": "secret", "refresh_token": "secret"]]
        if let lastRefresh { auth["last_refresh"] = lastRefresh }
        try JSONSerialization.data(withJSONObject: auth).write(to: dir.appendingPathComponent("auth.json"))
        return CodexHome(url: dir)
    }

    func writeRollout(_ home: CodexHome, day: String, name: String, lines: [String]) throws {
        let dir = home.sessionsURL.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appendingPathComponent(name))
    }

    func tokenCount(_ ts: String, primary: String, secondary: String = "null") -> String {
        #"{"timestamp":"\#(ts)","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":\#(primary),"secondary":\#(secondary),"plan_type":"pro"}}}"#
    }

    // MARK: - auth.json

    func testEmailFromIdToken() throws {
        let home = try makeHome()
        XCTAssertEqual(home.ownerEmail(), "codex.user@example.com")
        XCTAssertNil(CodexHome.email(fromAuth: Data(#"{"OPENAI_API_KEY":"sk-x","tokens":null}"#.utf8)), "API-key-only login has no known owner")
        XCTAssertNil(CodexHome.email(fromAuth: Data(#"{"tokens":{"id_token":"not-a-jwt"}}"#.utf8)))
    }

    func testDiscoverPrefersCodexHomeAndRequiresAuth() throws {
        let tmp = try tempDirectory()
        let custom = tmp.appendingPathComponent("custom-codex")
        let def = tmp.appendingPathComponent(".codex")
        for d in [custom, def] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: d.appendingPathComponent("auth.json"))
        }
        XCTAssertEqual(CodexHome.discover(environment: ["CODEX_HOME": custom.path], home: tmp).map(\.url.lastPathComponent),
                       ["custom-codex", ".codex"])
        try FileManager.default.removeItem(at: def.appendingPathComponent("auth.json"))
        XCTAssertEqual(CodexHome.discover(environment: [:], home: tmp).count, 0, "no auth.json, no target")
    }

    // MARK: - rollout

    func testParseCurrentFormat() throws {
        let line = tokenCount("2026-10-01T09:26:48.152Z",
                              primary: #"{"used_percent":3.0,"window_minutes":10080,"resets_at":1791125902}"#)
        let e = try XCTUnwrap(CodexRolloutReader.parse(line: Data(line.utf8)))
        XCTAssertEqual(e.at, CodexRolloutReader.parseTimestamp("2026-10-01T09:26:48.152Z"))
        XCTAssertEqual(e.windows.map(\.title), ["Weekly limit"])
        XCTAssertEqual(e.windows[0].key, "window_10080m")
        XCTAssertEqual(e.windows[0].percent, 3)
        XCTAssertEqual(e.windows[0].cadence, .fixed(7 * day))
        XCTAssertEqual(e.windows[0].resetsAt, Date(timeIntervalSince1970: 1791125880), "rounded to the minute")
    }

    func testParseOlderFormatWithResetsInSeconds() throws {
        let line = tokenCount("2026-10-01T00:00:00Z",
                              primary: #"{"used_percent":40,"window_minutes":300,"resets_in_seconds":3600}"#,
                              secondary: #"{"used_percent":12.5,"window_minutes":10080,"resets_in_seconds":86400}"#)
        let e = try XCTUnwrap(CodexRolloutReader.parse(line: Data(line.utf8)))
        XCTAssertEqual(e.windows.map(\.title), ["5h limit", "Weekly limit"])
        XCTAssertEqual(e.windows[0].cadence, .rolling(5 * hour))
        XCTAssertEqual(e.windows[0].resetsAt, e.at + hour)
        XCTAssertTrue(e.windows.allSatisfy(\.isLimit))
    }

    func testParseNormalizesOffByOneWindowLengths() throws {
        // Actual values from versions around October 2025
        let line = tokenCount("2025-10-20T00:00:00Z",
                              primary: #"{"used_percent":10,"window_minutes":299,"resets_in_seconds":60}"#,
                              secondary: #"{"used_percent":20,"window_minutes":10079,"resets_in_seconds":60}"#)
        let e = try XCTUnwrap(CodexRolloutReader.parse(line: Data(line.utf8)))
        XCTAssertEqual(e.windows.map(\.key), ["window_300m", "window_10080m"])
        XCTAssertEqual(e.windows.map(\.title), ["5h limit", "Weekly limit"])
        XCTAssertEqual(CodexRolloutReader.normalize(1440), 1440, "unknown lengths are left as is")
    }

    func testParseIgnoresLinesWithoutLimits() {
        XCTAssertNil(CodexRolloutReader.parse(line: Data(tokenCount("2026-10-01T00:00:00Z", primary: "null").utf8)))
        XCTAssertNil(CodexRolloutReader.parse(line: Data(#"{"timestamp":"2026-10-01T00:00:00Z","payload":{"type":"agent_message"}}"#.utf8)))
    }

    func testLatestRateLimitsSearchesNewestFilesFirst() throws {
        let home = try makeHome()
        let weekly = { (p: Int) in #"{"used_percent":\#(p),"window_minutes":10080,"resets_at":1791125902}"# }
        try writeRollout(home, day: "2026/09/30", name: "rollout-a.jsonl",
                         lines: [tokenCount("2026-09-30T10:00:00Z", primary: weekly(1))])
        try writeRollout(home, day: "2026/10/01", name: "rollout-b.jsonl",
                         lines: [tokenCount("2026-10-01T10:00:00Z", primary: weekly(5)),
                                 tokenCount("2026-10-01T11:00:00Z", primary: weekly(7)),
                                 #"{"timestamp":"2026-10-01T11:01:00Z","type":"response_item","payload":{}}"#])
        // If the newest date has no record, look at earlier ones
        try writeRollout(home, day: "2026/10/02", name: "rollout-c.jsonl",
                         lines: [#"{"timestamp":"2026-10-02T00:00:00Z","type":"session_meta","payload":{}}"#])

        let e = try XCTUnwrap(CodexRolloutReader.latestRateLimits(sessions: home.sessionsURL))
        XCTAssertEqual(e.windows.first?.percent, 7)
    }

    func testTailReadSkipsPartialFirstLine() throws {
        let home = try makeHome()
        let filler = String(repeating: "x", count: 5000)
        try writeRollout(home, day: "2026/10/01", name: "rollout-a.jsonl",
                         lines: [#"{"filler":"\#(filler)"}"#,
                                 tokenCount("2026-10-01T10:00:00Z",
                                            primary: #"{"used_percent":9,"window_minutes":10080,"resets_at":1791125902}"#)])
        let e = CodexRolloutReader.latestRateLimits(sessions: home.sessionsURL, tailBytes: 1000)
        XCTAssertEqual(e?.windows.first?.percent, 9)
    }

    // MARK: - fetch

    func testFetchUsesRecordTimeAndIgnoresRecordsBeforeLogin() throws {
        let home = try makeHome(lastRefresh: "2026-10-01T10:30:00Z")
        let weekly = #"{"used_percent":7,"window_minutes":10080,"resets_at":1791125902}"#
        try writeRollout(home, day: "2026/10/01", name: "rollout-a.jsonl",
                         lines: [tokenCount("2026-10-01T10:00:00Z", primary: weekly)])
        XCTAssertThrowsError(try home.fetch(), "records from before the login are not used") { error in
            guard case UsageError.noObservation = error else { return XCTFail("\(error)") }
        }

        try writeRollout(home, day: "2026/10/01", name: "rollout-b.jsonl",
                         lines: [tokenCount("2026-10-01T11:00:00Z", primary: weekly)])
        let fetched = try home.fetch()
        XCTAssertEqual(fetched.asOf, CodexRolloutReader.parseTimestamp("2026-10-01T11:00:00Z"))
        XCTAssertNil(fetched.credentialFingerprint, "no token is used")
    }

    func testFetchWithoutAnyRecord() throws {
        let home = try makeHome()
        XCTAssertThrowsError(try home.fetch()) { error in
            guard case UsageError.noObservation = error else { return XCTFail("\(error)") }
        }
    }
}
