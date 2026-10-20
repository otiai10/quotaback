import AppKit
import SwiftUI

/// 非 TTY の子プロセスを認証完了まで保持する。認証 URL・出力・コードは記録しない。
@MainActor
final class BrowserLogin: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = BrowserLogin()
    @Published private(set) var message = ""
    @Published private(set) var running = false
    @Published private(set) var acceptsCode = false
    @Published var code = ""
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
        // パイプの詰まりを防ぐ。認証 URL やトークンを UI・ログへ転送しない。
        stdout.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
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
        guard running, !stopped, !value.isEmpty else { return }
        do {
            try input?.fileHandleForWriting.write(contentsOf: Data((value + "\n").utf8))
            code = ""
        } catch {
            cancel(message: "認証コードを送信できませんでした。もう一度お試しください。")
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
                : "ログインを完了できませんでした（終了コード \(child.terminationStatus)）。\n別の認証処理が動いていないか確認してください。コマンドをコピーして試すこともできます。"
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
                    DisclosureGroup("ブラウザに認証コードが表示された場合") {
                        HStack {
                            SecureField("認証コード", text: $login.code)
                                .onSubmit { login.submitCode() }
                            Button("送信") { login.submitCode() }
                                .disabled(login.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }.padding(.top, 8)
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
