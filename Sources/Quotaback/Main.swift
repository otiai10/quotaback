import AppKit

/// エントリポイント。`--once` なら UI を出さずに1回観測して記録し、結果を標準出力に出す。
@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--once") {
            exit(runOnce())
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    /// 動作確認用。アプリと同じ経路で観測・記録する（トークンは表示しない）
    private static func runOnce() -> Int32 {
        let config = AppConfig.load()
        let targets = Providers.targets(config: config)
        let done = DispatchSemaphore(value: 0)
        var failed = false
        Task.detached {
            let engine = UsageEngine(log: ObservationLog.load())
            print("== 観測")
            for r in await engine.refresh(targets) {
                print("\(r.target.description) → \(r.owner ?? "持ち主不明")")
                switch r.outcome {
                case .recorded(let b): print("  記録: \(b.windows.count) 枠")
                case .skipped(let m): print("  スキップ: \(m)")
                case .failed(let m): failed = true; print("  error: \(m)")
                case .unchanged(let m): print("  新しい観測なし: \(m)")
                }
            }
            var accounts = config.accounts
            if let new = AppConfig.registerAccounts(await engine.observedAccounts) {
                let added = new.accounts.dropFirst(accounts.count)
                print("\n== config.json に追加: " + added.map { "[\($0.label)] \($0.key.id)" }.joined(separator: ", "))
                accounts = new.accounts
            }
            print("\n== 推定（保存済みの観測を含む）")
            for a in await engine.accountViews(config: accounts) {
                print("[\(a.label)] \(a.key.account)  \(a.isLive ? "ログイン中" : "未ログイン")  \(a.menuBarText)")
                if let t = a.observedAt { print("  最終観測: \(t.formatted()) (\(a.source ?? "-"))") }
                for e in a.windows { print("  " + describe(e)) }
                if let err = a.error { print("  error: \(err)") }
            }
            done.signal()
        }
        done.wait()
        return failed ? 1 : 0
    }

    private static func describe(_ e: WindowEstimate) -> String {
        let value: String
        switch e.value {
        case .exact(let v): value = "\(Int(v.rounded()))%"
        case .atLeast(let v): value = "≥\(Int(v.rounded()))%"
        case .reset: value = "リセット済み"
        }
        let reset: String
        switch e.nextReset {
        case .known(let d): reset = " resets \(d.formatted())"
        case .projected(let d): reset = " resets \(d.formatted()) (推定)"
        case .unknown: reset = ""
        }
        let detail = e.window.detail.map { " (\($0))" } ?? ""
        let eta = e.limitETA.map { " · 上限到達見込み \($0.formatted())" } ?? ""
        return "\(e.window.title) [\(e.window.key)]: \(value)\(detail)\(reset)\(eta)"
    }
}
