import XCTest
import SwiftUI
@testable import Quotaback

/// Renders the panel's account list from synthetic data, to review the layout without the app.
/// Images go to a temp directory, or to `$QUOTABACK_RENDER_DIR` when set
@MainActor
final class PanelRenderTests: XCTestCase {
    override func tearDown() {
        L10n.apply(nil)
        super.tearDown()
    }

    func sample() -> [AccountView] {
        let now = Date()
        let week: TimeInterval = 7 * day
        func w(_ key: String, _ title: String, _ p: Double, resets: Date?, cadence: Cadence = .fixed(week)) -> WindowObservation {
            WindowObservation(key: key, title: title, percent: p, resetsAt: resets, isLimit: true, detail: nil, cadence: cadence)
        }
        let p = AccountView(
            key: AccountKey(provider: "claude", account: "p@example.com"), label: "🏈", title: "🏈 personal",
            isLive: true, observedAt: now, source: nil, error: nil,
            windows: [
                WindowEstimate(window: w("session", "Current session", 12, resets: now + 3 * hour, cadence: .rolling(5 * hour)),
                               value: .exact(12), nextReset: .known(now + 3 * hour), observedAt: now, limitETA: nil),
                WindowEstimate(window: w("weekly_all", "Current week (all models)", 31, resets: now + 6 * day),
                               value: .exact(31), nextReset: .known(now + 6 * day), observedAt: now, limitETA: nil),
                WindowEstimate(window: w("weekly_scoped/Fable", "Current week (Fable)", 46, resets: now + 6 * day),
                               value: .exact(46), nextReset: .known(now + 6 * day), observedAt: now,
                               limitETA: now + 1.5 * day),
                WindowEstimate(window: WindowObservation(key: "spend", title: "Usage credits", percent: 0, resetsAt: nil,
                                                         isLimit: false, detail: "$0.00 / $200.00", cadence: .monthly),
                               value: .exact(0), nextReset: .unknown, observedAt: now, limitETA: nil),
            ])
        let s = AccountView(
            key: AccountKey(provider: "claude", account: "w@example.com"), label: "⭐️", title: "⭐️ work",
            isLive: false, observedAt: now - 2 * day, source: nil, error: nil,
            windows: [
                WindowEstimate(window: w("weekly_all", "Current week (all models)", 64, resets: now - hour),
                               value: .reset, nextReset: .projected(now + 6 * day), observedAt: now - 2 * day, limitETA: nil),
            ])
        let c = AccountView(
            key: AccountKey(provider: "codex", account: "c@example.com"), label: "🤖", title: "🤖 codex",
            isLive: true, observedAt: now, source: nil, error: nil,
            windows: [
                WindowEstimate(window: w("weekly", "Weekly limit", 0, resets: now + 6 * day),
                               value: .atLeast(0), nextReset: .known(now + 6 * day), observedAt: now, limitETA: nil),
            ])
        return [p, s, c]
    }

    func render(_ name: String, language: String, scheme: ColorScheme) throws {
        L10n.apply(language)
        let accounts = sample()
        let view = VStack(alignment: .leading, spacing: 18) {
            ForEach(accounts) { a in
                AccountSection(account: a, expanded: .constant(a.isLive))
                if a != accounts.last { Divider() }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(scheme == .dark ? Color(white: 0.17) : Color(white: 0.93),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let dir = try ProcessInfo.processInfo.environment["QUOTABACK_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
            ?? tempDirectory()
        try png.write(to: dir.appendingPathComponent("\(name).png"))
    }

    /// Work logged in but its credentials are still personal's (#29): a violet ring, no text. Not used in the README
    func testRendersCredentialMismatch() throws {
        L10n.apply("ja")
        let now = Date()
        let w = AccountView(
            key: AccountKey(provider: "claude", account: "w@example.com"), label: "⭐️", title: "⭐️ work",
            isLive: false, observedAt: now - day, source: nil, error: nil,
            windows: [WindowEstimate(window: WindowObservation(key: "weekly_all", title: "Current week (all models)", percent: 1,
                                                               resetsAt: now + 5 * day, isLimit: true, detail: nil, cadence: .fixed(7 * day)),
                                     value: .atLeast(1), nextReset: .known(now + 5 * day), observedAt: now - day, limitETA: nil)],
            credentialsOf: "🏈 personal")
        let view = AccountSection(account: w, expanded: .constant(true))
            .padding(14).frame(width: 340).background(Color(white: 0.93))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: tempDirectory().appendingPathComponent("panel-mismatch.png"))
        XCTAssertTrue(L10n.credentialsOf("🏈 personal").contains("/login"))
    }

    func testRendersPanel() throws {
        try render("panel-light", language: "en", scheme: .light)
        try render("panel-dark", language: "en", scheme: .dark)
        try render("panel-ja-light", language: "ja", scheme: .light)
    }
}
