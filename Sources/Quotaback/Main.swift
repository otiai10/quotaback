import Foundation

/// エントリポイント。`--once` なら UI を出さずに全置き場所を1回取得して標準出力に出す。
@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--once") {
            exit(runOnce())
        }
        QuotabackApp.main()
    }

    /// 動作確認用: 認証情報の置き場所・持ち主の判定・API・パーサーを UI 抜きで通す（トークンは表示しない）
    private static func runOnce() -> Int32 {
        let config = AppConfig.load()
        let sources = config.effectiveSources(discovered: CredentialSource.discover())
        let done = DispatchSemaphore(value: 0)
        var failed = false
        Task.detached {
            for source in sources {
                let r = await UsageClient.poll(source)
                let label = r.email.flatMap { e in config.accounts.first { $0.id == e }?.label } ?? "?"
                print("[\(label)] \(source.description) → \(r.email ?? "持ち主不明（\(source.resolvedProfilePath ?? "-") を読めず）")")
                switch r.result {
                case .success(let windows):
                    if windows.isEmpty { print("  (枠なし: last-response-*.json を確認)") }
                    for w in windows {
                        let detail = w.detail.map { " (\($0))" } ?? ""
                        let reset = w.resetsAt.map { " resets \($0.formatted())" } ?? ""
                        print("  \(w.title) [\(w.key)]: \(Int(w.utilization.rounded()))%\(detail)\(reset)")
                    }
                case .failure(let error):
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
