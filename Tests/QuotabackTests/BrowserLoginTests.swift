import XCTest
@testable import Quotaback

@MainActor
final class BrowserLoginTests: XCTestCase {
    private let key = AccountKey(provider: "claude", account: "user@example.com")

    private func script(_ body: String) throws -> URL {
        let url = try tempDirectory().appendingPathComponent("fake-cli")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func waitForExit(_ login: BrowserLogin) async throws {
        for _ in 0..<100 {
            if !login.running { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        login.cancel()
        XCTFail("認証プロセスが終了しませんでした")
    }

    func testManualCodeAndDuplicateStart() async throws {
        let url = try script("printf 'Paste code here if prompted > '\nread -r code\n[ \"$code\" = 'test#state' ]\n")
        var starts = 0
        let login = BrowserLogin(presentsWindow: false, resolveExecutable: { _ in starts += 1; return url })
        login.start(key: key)
        XCTAssertTrue(login.running)
        login.start(key: key)
        XCTAssertEqual(starts, 1)
        for _ in 0..<100 {
            if login.readyForCode { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(login.readyForCode)
        login.code = "incomplete"
        login.submitCode()
        XCTAssertNotNil(login.codeError)
        XCTAssertEqual(login.code, "incomplete")
        XCTAssertFalse(login.submittingCode)
        login.code = "test#state"
        login.submitCode()
        try await waitForExit(login)
        XCTAssertTrue(login.message.contains("ログインが完了"))
        XCTAssertEqual(login.code, "")
    }

    func testFailureAndCancellation() async throws {
        let failure = try script("exit 7\n")
        let login = BrowserLogin(presentsWindow: false, resolveExecutable: { _ in failure })
        login.start(key: key)
        try await waitForExit(login)
        XCTAssertTrue(login.message.contains("終了コード 7"))
        let waiting = try script("exec /bin/sleep 30\n")
        let cancelled = BrowserLogin(presentsWindow: false, resolveExecutable: { _ in waiting })
        cancelled.start(key: key)
        cancelled.cancel()
        try await waitForExit(cancelled)
        XCTAssertTrue(cancelled.message.contains("キャンセル"))
    }

    func testCLIInputErrorAllowsResubmissionWithoutExposingOutput() async throws {
        let url = try script("""
        printf 'Paste code here if prompted > '
        read -r code
        printf 'private-output Invalid code. Please make sure '
        /bin/sleep 0.05
        printf 'the full code was copied.\n'
        read -r code
        [ "$code" = 'retry#state' ]
        """)
        let login = BrowserLogin(presentsWindow: false, resolveExecutable: { _ in url })
        login.start(key: key)
        for _ in 0..<100 {
            if login.readyForCode { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        login.code = "first#state"
        login.submitCode()
        for _ in 0..<100 {
            if login.codeError != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(login.codeError)
        XCTAssertFalse(login.submittingCode)
        XCTAssertFalse(login.codeError?.contains("private-output") ?? true)
        login.code = "retry#state"
        login.submitCode()
        try await waitForExit(login)
        XCTAssertTrue(login.message.contains("ログインが完了"))
    }

    func testTimeoutAndMissingCLI() async throws {
        let waiting = try script("exec /bin/sleep 30\n")
        let login = BrowserLogin(presentsWindow: false, resolveExecutable: { _ in waiting },
                                 timeoutNanoseconds: 50_000_000)
        login.start(key: key)
        try await waitForExit(login)
        XCTAssertTrue(login.message.contains("待機時間"))
        let missing = BrowserLogin(presentsWindow: false, resolveExecutable: { _ in nil })
        missing.start(key: key)
        XCTAssertFalse(missing.running)
        XCTAssertTrue(missing.message.contains("見つかりません"))
    }
}
