import XCTest
import SwiftUI
@testable import Quotaback

/// Renders the Analytics charts from synthetic data (no app, no real data). Images go to a temp directory, or to
/// `$QUOTABACK_RENDER_DIR` when set (for review)
@MainActor
final class AnalyticsRenderTests: XCTestCase {
    let p = AccountKey(provider: "claude", account: "p@example.com")
    let w = AccountKey(provider: "claude", account: "w@example.com")

    override func tearDown() {
        L10n.apply(nil)
        super.tearDown()
    }

    func sample() -> AnalyticsInput {
        let week: TimeInterval = 7 * day
        let reset = t0 + 3 * day
        func summary(_ a: AccountKey, _ key: String = "weekly_all", at r: Date, _ v: Double, gap: TimeInterval = 60) -> CycleSummary {
            CycleSummary(account: a, key: key, title: key == "weekly_all" ? "Current week (all models)" : "Current week (Fable)",
                         cadence: .fixed(week), resetsAt: r, firstObservedAt: r - 6 * day, lastObservedAt: r - gap,
                         finalPercent: v, peakPercent: v, observations: 5)
        }
        let shift: TimeInterval = 6 * hour
        // Twelve closed weeks, so that the heatmap is wider than the window and scrolls. nil = never observed that week;
        // a gap of days = ended while not logged in (a lower bound)
        let pAll: [Double?] = [92, 100, nil, 74, 38, 61, 15, 88, 100, 42, 57, 23]
        let wAll: [Double?] = [35, 48, 61, 22, 70, 9, 54, nil, 33, 81, 46, 28]
        let pFable: [Double?] = [nil, nil, 40, 55, 12, 47, 8, 66, 95, 30, 44, 19]
        var cycles: [CycleSummary] = []
        for i in 0..<12 {
            let r = reset - Double(12 - i) * week   // i = 11 is last week
            let pGap: TimeInterval = i % 3 == 0 ? 2 * day : 60
            let wGap: TimeInterval = i % 4 == 1 ? 3 * day : 60
            if let v = pAll[i] { cycles.append(summary(p, at: r, v, gap: pGap)) }
            if let v = wAll[i] { cycles.append(summary(w, at: r + shift, v, gap: wGap)) }
            if let v = pFable[i] { cycles.append(summary(p, "weekly_scoped/Fable", at: r, v, gap: pGap)) }
        }
        let weekly = WindowObservation(key: "weekly_all", title: "Current week (all models)", percent: 58, resetsAt: reset,
                                       isLimit: true, detail: nil, cadence: .fixed(week))
        let session = WindowObservation(key: "session", title: "Current session", percent: 35, resetsAt: t0 + 2 * hour,
                                        isLimit: true, detail: nil, cadence: .rolling(5 * hour))
        let fable = WindowObservation(key: "weekly_scoped/Fable", title: "Current week (Fable)", percent: 66, resetsAt: reset,
                                      isLimit: true, detail: nil, cadence: .fixed(week))
        let start = reset - week
        let live = [
            // Its limit label is close to weekly_all's, so one of them goes up a level
            AnalyticsInput.LiveWindow(
                account: p,
                estimate: WindowEstimate(window: fable, value: .exact(66), nextReset: .known(reset), observedAt: t0,
                                         limitETA: start + 0.79 * week),
                points: [(start + 0.1 * week, 9), (start + 0.25 * week, 30), (start + 0.4 * week, 50), (t0, 66)]),
            AnalyticsInput.LiveWindow(
                account: p,
                estimate: WindowEstimate(window: weekly, value: .exact(58), nextReset: .known(reset), observedAt: t0,
                                         limitETA: start + 0.85 * week),
                points: [(start + 0.1 * week, 5), (start + 0.25 * week, 21), (start + 0.4 * week, 40), (t0, 58)]),
            AnalyticsInput.LiveWindow(
                account: p,
                estimate: WindowEstimate(window: session, value: .exact(35), nextReset: .known(t0 + 2 * hour),
                                         observedAt: t0, limitETA: nil),
                points: [(t0 - 2 * hour, 4), (t0 - hour, 20), (t0, 35)]),
        ]
        return AnalyticsInput(cycles: cycles, titles: [p: "P", w: "W"], live: live, now: t0)
    }

    /// Draws through an `NSHostingView` in an offscreen window, not `ImageRenderer`: the latter leaves the
    /// heatmap's `ScrollView` blank. `publish` false keeps the image out of `$QUOTABACK_RENDER_DIR` (not a README image)
    func render(_ name: String, language: String?, scheme: ColorScheme, width: CGFloat = 640, publish: Bool = true) throws {
        L10n.apply(language)
        let view = AnalyticsCharts(input: sample())
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Lets the heatmap's onAppear scroll to the newest week before the snapshot
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertEqual(host.bounds.width, width)
        XCTAssertGreaterThan(host.bounds.height, 400)
        let dir = try (publish ? ProcessInfo.processInfo.environment["QUOTABACK_RENDER_DIR"].map { URL(fileURLWithPath: $0) } : nil)
            ?? tempDirectory()
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    func testRendersCharts() throws {
        try render("analytics-en-light", language: "en", scheme: .light)
        try render("analytics-ja-light", language: "ja", scheme: .light)
        try render("analytics-en-dark", language: "en", scheme: .dark)
    }

    /// The window's minimum width. The heatmap scrolls instead of widening the page
    func testRendersAtMinimumWidth() throws {
        try render("analytics-en-light-520", language: "en", scheme: .light, width: 520, publish: false)
    }
}
