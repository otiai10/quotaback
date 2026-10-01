import XCTest
@testable import Quotaback

final class CredentialsTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotaback-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testEmailFromProfile() {
        let json = #"{"numStartups": 3, "oauthAccount": {"emailAddress": "work@example.com", "organizationName": "x"}}"#
        XCTAssertEqual(CredentialSource.email(fromProfile: Data(json.utf8)), "work@example.com")
        XCTAssertNil(CredentialSource.email(fromProfile: Data(#"{"numStartups": 3}"#.utf8)))
        XCTAssertNil(CredentialSource.email(fromProfile: Data("not json".utf8)))
    }

    func testProfilePathResolution() {
        let home = NSHomeDirectory()
        XCTAssertEqual(CredentialSource.defaultKeychain.resolvedProfilePath, home + "/.claude.json")
        XCTAssertEqual(CredentialSource(credentialsPath: "~/.claude-work/.credentials.json").resolvedProfilePath,
                       home + "/.claude-work/.claude.json")
        XCTAssertEqual(CredentialSource(credentialsPath: "~/.claude/.credentials.json").resolvedProfilePath,
                       home + "/.claude.json")
        XCTAssertNil(CredentialSource(keychainService: "Claude Code-credentials-abcd1234").resolvedProfilePath)
        XCTAssertEqual(CredentialSource(keychainService: "x", profilePath: "~/p.json").resolvedProfilePath,
                       home + "/p.json")
    }

    func testOwnerEmailReadsProfileNextToCredentials() throws {
        let dir = tmp.appendingPathComponent(".claude-work")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount": {"emailAddress": "w@example.com"}}"#.utf8)
            .write(to: dir.appendingPathComponent(".claude.json"))
        let source = CredentialSource(credentialsPath: dir.appendingPathComponent(".credentials.json").path)
        XCTAssertEqual(source.ownerEmail(), "w@example.com")
        XCTAssertEqual(CredentialSource(keychainService: "x", email: "Manual@Example.com").ownerEmail(),
                       "manual@example.com")
    }

    func testDiscoverFindsCredentialFiles() throws {
        let fm = FileManager.default
        for name in [".claude-work", ".claude", ".claude-empty", ".other"] {
            try fm.createDirectory(at: tmp.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        for name in [".claude-work", ".claude", ".other"] {
            try Data("{}".utf8).write(to: tmp.appendingPathComponent("\(name)/.credentials.json"))
        }
        let envDir = tmp.appendingPathComponent("custom")
        try fm.createDirectory(at: envDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: envDir.appendingPathComponent(".credentials.json"))

        let found = CredentialSource.discover(environment: ["CLAUDE_CONFIG_DIR": envDir.path], home: tmp)

        XCTAssertEqual(found.first, .defaultKeychain)
        XCTAssertEqual(found.dropFirst().compactMap(\.credentialsPath).map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent
        }, ["custom", ".claude", ".claude-work"])
    }

    func testLegacyConfigMigratesToSources() throws {
        // 以前の形式（accounts に keychainService を直接書く）
        let json = """
        {"refreshSeconds": 300, "accounts": [
          {"label": "P", "name": "personal@example.com", "keychainService": "Claude Code-credentials"},
          {"label": "W", "name": "work@example.com", "keychainService": "Claude Code-credentials-<SUFFIX>"}
        ]}
        """
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        let extra = CredentialSource(credentialsPath: "/tmp/x/.credentials.json")
        let sources = cfg.effectiveSources(discovered: [.defaultKeychain, extra])

        XCTAssertEqual(sources, [.defaultKeychain, extra], "プレースホルダは除外、重複は1つに")
        XCTAssertEqual(cfg.accounts.map(\.id), ["claude:personal@example.com", "claude:work@example.com"])

        var explicit = cfg
        explicit.sources = [extra]
        XCTAssertEqual(explicit.effectiveSources(discovered: [.defaultKeychain]), [extra], "sources 指定時は自動検出しない")
    }

    func testFingerprintIsStableAndShort() {
        XCTAssertEqual(CredentialSource.fingerprint("abc"), CredentialSource.fingerprint("abc"))
        XCTAssertNotEqual(CredentialSource.fingerprint("abc"), CredentialSource.fingerprint("abd"))
        XCTAssertEqual(CredentialSource.fingerprint("abc").count, 16)
    }
}

final class AppConfigTests: XCTestCase {
    let base = AppConfig(refreshSeconds: 300, accounts: [
        AccountConfig(label: "P", name: "p@example.com"),
        AccountConfig(label: "W", name: "w@example.com"),
    ])

    func testLabelOnlyChangeDoesNotNeedRefetch() {
        var new = base
        new.accounts[0].label = "🏠"
        new.accounts[1].label = "💼"
        XCTAssertNotEqual(new, base)
        XCTAssertFalse(new.needsRefetch(comparedTo: base))
    }

    func testSourceOrIntervalChangeNeedsRefetch() {
        var interval = base
        interval.refreshSeconds = 120
        XCTAssertTrue(interval.needsRefetch(comparedTo: base))

        var sources = base
        sources.sources = [CredentialSource(credentialsPath: "~/.claude-work/.credentials.json")]
        XCTAssertTrue(sources.needsRefetch(comparedTo: base))

        var account = base
        account.accounts.append(AccountConfig(label: "X", name: "x@example.com"))
        XCTAssertTrue(account.needsRefetch(comparedTo: base))
    }

    func testReadFailsOnBrokenJSONInsteadOfFallingBack() throws {
        let url = try tempDirectory().appendingPathComponent("config.json")
        try Data(#"{"refreshSeconds": 300, "accounts": [{"label": "🏠", "name": "p@example.com"#.utf8).write(to: url)
        guard case .failure = AppConfig.read(from: url) else { return XCTFail("壊れた JSON は失敗にする") }

        try Data(#"{"refreshSeconds": 300, "accounts": [{"label": "🏠", "name": "p@example.com"}]}"#.utf8).write(to: url)
        guard case .success(let cfg) = AppConfig.read(from: url) else { return XCTFail() }
        XCTAssertEqual(cfg.accounts.first?.label, "🏠")
    }
}
