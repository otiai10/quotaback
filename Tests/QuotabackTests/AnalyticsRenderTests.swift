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
        let r: [Date] = (1...4).map { reset - Double($0) * week }   // r[0] = last week, r[3] = four weeks ago
        var cycles: [CycleSummary] = []
        cycles += [summary(p, at: r[3], 92), summary(w, at: r[3] + shift, 35, gap: 2 * day)]
        cycles += [summary(p, at: r[2], 100), summary(w, at: r[2] + shift, 48)]
        // P has no summary two weeks ago
        cycles += [summary(w, at: r[1] + shift, 61, gap: 3 * day)]
        cycles += [summary(p, at: r[0], 74), summary(w, at: r[0] + shift, 22)]
        cycles += [summary(p, "weekly_scoped/Fable", at: r[1], 40), summary(p, "weekly_scoped/Fable", at: r[0], 55)]
        let weekly = WindowObservation(key: "weekly_all", title: "Current week (all models)", percent: 58, resetsAt: reset,
                                       isLimit: true, detail: nil, cadence: .fixed(week))
        let session = WindowObservation(key: "session", title: "Current session", percent: 35, resetsAt: t0 + 2 * hour,
                                        isLimit: true, detail: nil, cadence: .rolling(5 * hour))
        let start = reset - week
        let live = [
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

    func render(_ name: String, language: String?, scheme: ColorScheme) throws {
        L10n.apply(language)
        let view = AnalyticsCharts(input: sample())
            .frame(width: 640)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(image.size.height, 400)
        let dir = try ProcessInfo.processInfo.environment["QUOTABACK_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
            ?? tempDirectory()
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    func testRendersCharts() throws {
        try render("analytics-en-light", language: "en", scheme: .light)
        try render("analytics-ja-light", language: "ja", scheme: .light)
        try render("analytics-en-dark", language: "en", scheme: .dark)
    }
}
