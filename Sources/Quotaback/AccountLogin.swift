import AppKit

/// CLI の認証を cmux の新しいワークスペースで開始する。
enum AccountLogin {
    static func showMenu(for key: AccountKey) {
        guard let command = command(for: key) else { return }
        let actions = LoginMenuActions(command: command, executable: cmuxURL)
        let menu = NSMenu()
        menu.addItem(withTitle: key.account, action: nil, keyEquivalent: "")
        if actions.executable != nil {
            let item = menu.addItem(withTitle: "\(clientName(for: key)) にログイン…（cmux）",
                                    action: #selector(LoginMenuActions.login), keyEquivalent: "")
            item.target = actions
        } else {
            menu.addItem(withTitle: "cmux が見つかりません", action: nil, keyEquivalent: "")
        }
        let copy = menu.addItem(withTitle: "ログインコマンドをコピー",
                                action: #selector(LoginMenuActions.copyCommand), keyEquivalent: "")
        copy.target = actions
        menu.addItem(.separator())
        menu.addItem(withTitle: key.provider == ClaudeProvider.id
                     ? "ブラウザで認証を完了してください"
                     : "ブラウザで対象アカウントを選んでください", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "対象は CLI のログインです", action: nil, keyEquivalent: "")
        _ = withExtendedLifetime(actions) {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    static func command(for key: AccountKey) -> String? {
        switch key.provider {
        case ClaudeProvider.id: return "claude auth login --email \(quote(key.account))"
        case CodexProvider.id: return "codex login"
        default: return nil
        }
    }

    static func clientName(for key: AccountKey) -> String {
        key.provider == ClaudeProvider.id ? "Claude Code" : "Codex CLI"
    }

    static var cmuxURL: URL? {
        let workspace = NSWorkspace.shared
        let app = workspace.runningApplications.first { $0.bundleIdentifier == "com.cmuxterm.app" }?.bundleURL
            ?? workspace.urlForApplication(withBundleIdentifier: "com.cmuxterm.app")
        let candidates = [app, URL(fileURLWithPath: "/Applications/cmux.app"),
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/cmux.app")]
        return candidates.compactMap { $0?.appendingPathComponent("Contents/Resources/bin/cmux") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func open(command: String, using executable: URL) {
        // 既存の作業ペインには入力しない。シェルの解釈は新しいワークスペース内だけで行う。
        let appURL = executable.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: appURL, configuration: .init()) { _, error in
            if let error { showError(error.localizedDescription); return }
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = ["new-workspace", "--name", "Quotaback ログイン", "--command", command, "--focus", "true"]
                // 呼び出し元のワークスペースやソケット指定を引き継がない。
                process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CMUX_") }
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        showError("cmux に接続できませんでした。cmux のソケット制御設定を確認するか、ログインコマンドをコピーしてください。")
                    }
                } catch { showError(error.localizedDescription) }
            }
        }
    }

    private static func showError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "ログイン画面を開けませんでした"
            alert.informativeText = message
            alert.runModal()
        }
    }
}

/// メニュー表示中のアクションを保持する。アイコン描画は SwiftUI の元の表示を使う。
private final class LoginMenuActions: NSObject {
    let command: String
    let executable: URL?

    init(command: String, executable: URL?) {
        self.command = command
        self.executable = executable
    }

    @objc func login() {
        guard let executable else { return }
        AccountLogin.open(command: command, using: executable)
    }

    @objc func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
