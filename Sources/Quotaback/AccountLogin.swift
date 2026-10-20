import AppKit

/// ブラウザを使った CLI 認証と、コマンドのコピーを提供する。
enum AccountLogin {
    static func showMenu(for key: AccountKey) {
        guard let command = command(for: key) else { return }
        let actions = LoginMenuActions(key: key, command: command)
        let menu = NSMenu()
        menu.addItem(withTitle: key.account, action: nil, keyEquivalent: "")
        let item = menu.addItem(withTitle: "ブラウザで \(clientName(for: key)) にログイン…",
                                action: #selector(LoginMenuActions.login), keyEquivalent: "")
        item.target = actions
        let copy = menu.addItem(withTitle: "ログインコマンドをコピー",
                                action: #selector(LoginMenuActions.copyCommand), keyEquivalent: "")
        copy.target = actions
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

    static func arguments(for key: AccountKey) -> [String]? {
        switch key.provider {
        case ClaudeProvider.id: return ["auth", "login", "--claudeai", "--email", key.account]
        case CodexProvider.id: return ["login"]
        default: return nil
        }
    }

    static func executable(for key: AccountKey) -> URL? {
        let name = key.provider == ClaudeProvider.id ? "claude" : "codex"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [home.appendingPathComponent(".local/bin").path,
                     home.appendingPathComponent(".npm-global/bin").path,
                     home.appendingPathComponent("Library/pnpm/bin").path,
                     home.appendingPathComponent(".volta/bin").path,
                     "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        return paths.filter { $0.hasPrefix("/") && !$0.contains("cmux-cli-shims") }
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private final class LoginMenuActions: NSObject {
    let key: AccountKey
    let command: String

    init(key: AccountKey, command: String) {
        self.key = key
        self.command = command
    }

    @objc func login() {
        Task { @MainActor in BrowserLogin.shared.start(key: key) }
    }

    @objc func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }
}
