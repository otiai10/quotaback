import XCTest
@testable import Quotaback

final class AccountLoginTests: XCTestCase {
    func testProviderCommands() {
        XCTAssertEqual(AccountLogin.command(for: AccountKey(provider: "claude", account: "user@example.com")),
                       "claude auth login --email 'user@example.com'")
        XCTAssertEqual(AccountLogin.command(for: AccountKey(provider: "codex", account: "user@example.com")),
                       "codex login")
        XCTAssertNil(AccountLogin.command(for: AccountKey(provider: "unknown", account: "user@example.com")))
    }

    func testShellPreservesAccountAsOneLiteralArgument() throws {
        // 設定にシェルの特殊文字があっても、展開・コマンド実行を起こさない。
        let account = "a'b;$(printf injected)`printf injected`\n@example.com"
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "printf '%s' \(AccountLogin.quote(account))"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), account)
    }
}
