import AppKit
import SwiftUI

/// 非 TTY の子プロセスを認証完了まで保持する。認証 URL・出力・コードは記録しない。
@MainActor
final class BrowserLogin: NSObject, ObservableObject, NSWindowDelegate {
    enum Presentation { case none, manualCode, failure }

    static let shared = BrowserLogin()
    @Published private(set) var activeKey: AccountKey?
    @Published private(set) var presentation: Presentation = .none
    @Published private(set) var clientName = ""
    @Published private(set) var account = ""
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
    private var failed = false
    private let presentsWindow: Bool
    private let resolveExecutable: (AccountKey) -> URL?
    private let timeoutNanoseconds: UInt64

    init(presentsWindow: Bool = true,
         resolveExecutable: @escaping (AccountKey) -> URL? = AccountLogin.executable,
         timeoutNanoseconds: UInt64 = 300_000_000_000) {
        self.presentsWindow = presentsWindow
        self.resolveExecutable = resolveExecutable
        self.timeoutNanoseconds = timeoutNanoseconds
        super.init()
    }

    func start(key: AccountKey) {
        guard !running else { return }
        dismissWindow()
        activeKey = key
        failed = false
        clientName = AccountLogin.clientName(for: key)
        account = key.account
        message = ""
        code = ""
        codeError = nil
        readyForCode = false
        submittingCode = false
        outputTail = ""
        failureHint = nil
        acceptsCode = key.provider == ClaudeProvider.id
        stopped = false
        guard let executable = resolveExecutable(key),
              let arguments = AccountLogin.arguments(for: key) else {
            message = "\(AccountLogin.clientName(for: key)) が見つかりません。CLI のインストール先を確認するか、メニューからログインコマンドをコピーしてください。"
            showWindow(.failure)
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
        message = "ブラウザでの操作を待っています"
        do {
            try child.run()
            running = true
            let limit = timeoutNanoseconds
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: limit)
                guard !Task.isCancelled else { return }
                self?.cancel(message: "認証の待機時間（5分）を超えました。もう一度お試しください。", showFailure: true)
            }
        } catch {
            message = "認証処理を開始できませんでした: \(error.localizedDescription)"
            cleanup()
            showWindow(.failure)
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
            cancel(message: "認証コードを送信できませんでした。もう一度お試しください。", showFailure: true)
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

    func cancel(message: String = "ログインをキャンセルしました。", showFailure: Bool = false) {
        guard running, let child = process else { return }
        stopped = true
        failed = showFailure
        dismissWindow()
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
            failed = child.terminationStatus != 0
            message = child.terminationStatus == 0
                ? "CLI のログインが完了しました。\n作業中のセッションへの反映は保証されません。CLI 側でアカウントを確認してください。"
                : "ログインを完了できませんでした（終了コード \(child.terminationStatus)）。\n"
                    + (failureHint ?? "今回開いたブラウザのコードを使っているか確認し、ログインを開始し直してください。コマンドをコピーして試すこともできます。")
        }
        cleanup()
        if failed { showWindow(.failure) } else { dismissWindow() }
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

    func showCodeEntry() {
        guard running, !stopped, acceptsCode else { return }
        showWindow(.manualCode)
    }

    private func dismissWindow() {
        presentation = .none
        window?.orderOut(nil)
    }

    private func showWindow(_ destination: Presentation) {
        presentation = destination
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
        window?.title = destination == .manualCode ? "認証コードを入力" : "ログインできませんでした"
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { dismissWindow() }
    func windowWillClose(_ notification: Notification) {
        presentation = .none
    }
}

private struct BrowserLoginView: View {
    @ObservedObject var login: BrowserLogin

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("\(login.clientName) にログイン")
                    .font(.system(size: 17, weight: .semibold))
                Text(login.account)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.top, 8)

            if login.presentation == .failure {
                Text(login.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if login.presentation == .manualCode {
                VStack(alignment: .leading, spacing: 12) {
                    Text("認可後に表示される、# を含むコードを貼り付けてください。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            SecureField("# を含むコード全体を貼り付け", text: $login.code)
                                .onSubmit { login.submitCode() }
                                .accessibilityLabel("CLI 用コード")
                            Button("送信") { login.submitCode() }
                                .disabled(!login.readyForCode || login.submittingCode || login.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    if let error = login.codeError {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if login.submittingCode {
                        Text("コードを確認しています…")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    Text("メールの6桁コードは、元のブラウザタブに入力してください。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("閉じる") { login.close() }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
