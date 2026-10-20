import AppKit
import SwiftUI

/// 非 TTY の子プロセスを認証完了まで保持する。認証 URL・出力・コードは記録しない。
@MainActor
final class BrowserLogin: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = BrowserLogin()
    @Published private(set) var message = ""
    @Published private(set) var running = false
    @Published private(set) var acceptsCode = false
    @Published private(set) var readyForCode = false
    @Published private(set) var submittingCode = false
    @Published private(set) var codeError: String?
    @Published var code = ""
    private var outputTail = ""
    private var failureHint: String?
    private var window: NSWindow?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var timeout: Task<Void, Never>?
    private var stopped = false
    private let presentsWindow: Bool
    private let resolveExecutable: (AccountKey) -> URL?
    private let timeoutNanoseconds: UInt64

    init(presentsWindow: Bool = true,
         resolveExecutable: @escaping (AccountKey) -> URL? = AccountLogin.executable,
         timeoutNanoseconds: UInt64 = 600_000_000_000) {
        self.presentsWindow = presentsWindow
        self.resolveExecutable = resolveExecutable
        self.timeoutNanoseconds = timeoutNanoseconds
        super.init()
    }

    func start(key: AccountKey) {
        if running { showWindow(); return }
        code = ""
        codeError = nil
        readyForCode = false
        submittingCode = false
        outputTail = ""
        failureHint = nil
        acceptsCode = key.provider == ClaudeProvider.id
        stopped = false
        showWindow()
        guard let executable = resolveExecutable(key),
              let arguments = AccountLogin.arguments(for: key) else {
            message = "\(AccountLogin.clientName(for: key)) が見つかりません。CLI のインストール先を確認するか、メニューからログインコマンドをコピーしてください。"
            return
        }
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("CMUX_") && $0.key != "CLAUDECODE"
        }
        // GUI 起動時にも npm 等の CLI が必要なランタイムを見つけられるようにする。
        let home = FileManager.default.homeDirectoryForCurrentUser
        environment["PATH"] = [executable.deletingLastPathComponent().path,
                               home.appendingPathComponent(".local/share/mise/shims").path,
                               home.appendingPathComponent(".volta/bin").path,
                               "/opt/homebrew/bin", "/usr/local/bin",
                               environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        child.environment = environment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stdout
        // 既知の状態メッセージだけを分類し、出力本文や認証情報は表示・保存しない。
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor in
                guard self.process === child else { return }
                self.consumeOutput(data)
            }
        }
        child.terminationHandler = { child in
            Task { @MainActor in self.finished(child) }
        }
        process = child
        input = stdin
        output = stdout
        message = "\(AccountLogin.clientName(for: key)) の認証をブラウザで完了してください。\n対象: \(key.account)\nブラウザ上でもアカウントを確認してください。"
        do {
            try child.run()
            running = true
            let limit = timeoutNanoseconds
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: limit)
                guard !Task.isCancelled else { return }
                self?.cancel(message: "認証の待機時間（10分）を超えました。もう一度お試しください。")
            }
        } catch {
            message = "認証処理を開始できませんでした: \(error.localizedDescription)"
            cleanup()
        }
    }

    func submitCode() {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard running, !stopped, readyForCode, !submittingCode, !value.isEmpty else { return }
        if value.count == 6, value.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
            codeError = "その6桁はブラウザのログイン確認コードです。メールアドレスを入力した元のブラウザタブへ戻り、そちらに入力してください。"
            return
        }
        guard Self.isCompleteCode(value) else {
            codeError = "ここには Claude Code の認可後に表示される、# を含む CLI 用コードを入力してください。"
            return
        }
        do {
            guard let input else { return }
            try input.fileHandleForWriting.write(contentsOf: Data((value + "\n").utf8))
            submittingCode = true
            codeError = nil
            code = ""
        } catch {
            cancel(message: "認証コードを送信できませんでした。もう一度お試しください。")
        }
    }

    static func isCompleteCode(_ value: String) -> Bool {
        let parts = value.split(separator: "#", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
            && !value.contains(where: { $0.isWhitespace })
    }

    private func consumeOutput(_ data: Data) {
        outputTail = String((outputTail + String(decoding: data, as: UTF8.self)).suffix(4096))
        if outputTail.contains("Paste code here if prompted") { readyForCode = true }
        if outputTail.contains("Invalid code. Please make sure the full code was copied.") {
            codeError = "コードが受け付けられませんでした。# を含むコード全体をコピーして再送してください。"
            submittingCode = false
            outputTail = ""
        } else if outputTail.contains("That code is not from this sign-in") {
            codeError = "別のログイン操作のコードです。今回開いた認証画面のコードを入力してください。"
            submittingCode = false
            outputTail = ""
        } else if outputTail.contains("Token exchange failed") || outputTail.contains("invalid_grant") {
            failureHint = "コードが期限切れ・使用済み、または別の認証操作のものの可能性があります。ログインを開始し直してください。"
        }
    }

    func cancel(message: String = "ログインをキャンセルしました。") {
        guard running, let child = process else { return }
        stopped = true
        self.message = message
        code = ""
        timeout?.cancel()
        if child.isRunning { child.terminate() }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    private func finished(_ child: Process) {
        guard process === child else { return }
        if !stopped {
            message = child.terminationStatus == 0
                ? "CLI のログインが完了しました。\n作業中のセッションへの反映は保証されません。CLI 側でアカウントを確認してください。"
                : "ログインを完了できませんでした（終了コード \(child.terminationStatus)）。\n"
                    + (failureHint ?? "今回開いたブラウザのコードを使っているか確認し、ログインを開始し直してください。コマンドをコピーして試すこともできます。")
        }
        cleanup()
    }

    private func cleanup() {
        timeout?.cancel()
        timeout = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        input = nil
        output = nil
        process = nil
        running = false
        code = ""
        readyForCode = false
        submittingCode = false
        outputTail = ""
    }

    private func showWindow() {
        guard presentsWindow else { return }
        if window == nil {
            let view = NSHostingController(rootView: BrowserLoginView(login: self))
            let panel = NSWindow(contentViewController: view)
            panel.title = "ブラウザでログイン"
            panel.styleMask = [.titled, .closable]
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.center()
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }
    func windowWillClose(_ notification: Notification) { cancel() }
}

private struct BrowserLoginView: View {
    @ObservedObject var login: BrowserLogin
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(login.message).fixedSize(horizontal: false, vertical: true)
            if login.running {
                ProgressView().controlSize(.small)
                if login.acceptsCode {
                    DisclosureGroup("認可後に CLI 用コードが表示された場合") {
                        HStack {
                            SecureField("CLI 用コード（# を含む）", text: $login.code)
                                .onSubmit { login.submitCode() }
                            Button("送信") { login.submitCode() }
                                .disabled(!login.readyForCode || login.submittingCode || login.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }.padding(.top, 8)
                        if let error = login.codeError {
                            Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(login.submittingCode ? "コードを確認しています…" : "メールログインの6桁コードは、元のブラウザタブに入力してください。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(login.running ? "キャンセル" : "閉じる") {
                    if login.running { login.cancel() } else { login.close() }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
