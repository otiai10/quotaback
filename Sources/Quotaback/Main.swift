import Foundation

/// エントリポイント。`--once` なら UI を出さずに全アカウントを1回取得して標準出力に出す。
@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--once") {
            exit(runOnce())
        }
        QuotabackApp.main()
    }

    /// 動作確認用: 認証情報の読み取り・API・パーサーを UI 抜きで通す
    private static func runOnce() -> Int32 {
        let config = AppConfig.load()
        let done = DispatchSemaphore(value: 0)
        var failed = false
        Task.detached {
            for account in config.accounts {
                print("[\(account.label)] \(account.name)")
                do {
                    let windows = try await UsageClient.fetch(account: account)
                    if windows.isEmpty { print("  (枠なし: last-response-\(account.label).json を確認)") }
                    for w in windows {
                        let reset = w.resetsAt.map { " resets \($0.formatted())" } ?? ""
                        print("  \(w.title) [\(w.key)]: \(Int(w.utilization.rounded()))%\(reset)")
                    }
                } catch {
                    failed = true
                    print("  error: \(error.localizedDescription)")
                }
            }
            done.signal()
        }
        done.wait()
        return failed ? 1 : 0
    }
}
