import AppKit

/// Entry point. With `--once`, observes and records once without UI and prints the results to stdout.
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

    /// For checking behavior. Observes and records through the same path as the app (never prints tokens)
    private static func runOnce() -> Int32 {
        let config = AppConfig.load()
        L10n.apply(config.language)
        let targets = Providers.targets(config: config)
        let done = DispatchSemaphore(value: 0)
        var failed = false
        Task.detached {
            let engine = UsageEngine(log: ObservationLog.load())
            print(L10n.onceObserve)
            for r in await engine.refresh(targets) {
                print("\(r.target.description) → \(r.owner ?? L10n.unknownOwner)")
                switch r.outcome {
                case .recorded(let b): print("  " + L10n.recorded(b.windows.count))
                case .skipped(let m): print("  " + L10n.skipped(m))
                case .failed(let m): failed = true; print("  error: \(m)")
                case .unchanged(let m): print("  " + L10n.noNewObservation(m))
                }
            }
            var accounts = config.accounts
            if let new = AppConfig.registerAccounts(await engine.observedAccounts) {
                let added = new.accounts.dropFirst(accounts.count)
                print("\n" + L10n.onceAdded + added.map { "\($0.key.id)" }.joined(separator: ", "))
                accounts = new.accounts
            }
            print("\n" + L10n.onceEstimates)
            for a in await engine.accountViews(config: accounts) {
                print("[\(a.label)] \(a.key.account)  \(a.isLive ? L10n.loggedIn : L10n.notLoggedIn)  \(a.menuBarText)")
                if let t = a.observedAt { print("  " + L10n.lastObservedShort(t.formatted()) + " (\(a.source ?? "-"))") }
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
        case .reset: value = L10n.resetDone
        }
        let reset: String
        switch e.nextReset {
        case .known(let d): reset = " resets \(d.formatted())"
        case .projected(let d): reset = " resets \(d.formatted())" + L10n.projectedSuffix
        case .unknown: reset = ""
        }
        let detail = e.window.detail.map { " (\($0))" } ?? ""
        let eta = e.limitETA.map { L10n.limitETA($0.formatted()) } ?? ""
        return "\(e.window.title) [\(e.window.key)]: \(value)\(detail)\(reset)\(eta)"
    }
}
