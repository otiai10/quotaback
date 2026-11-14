import Foundation

/// How often each target is observed. The single source of the polling intervals (CLAUDE.md "取得のタイミング").
/// Regular fixed-point observation, tightened only while a usage-limit window is close to full.
/// Explicit fetches (the "Refresh" menu, a login switch) don't wait for this; the gate's minimum still applies
enum PollSchedule {
    /// Fixed-point observation while every window is comfortably below its limit
    static let regular: TimeInterval = 15 * 60
    /// While any usage-limit window is at or above `nearLimitPercent`
    static let nearLimit: TimeInterval = 5 * 60
    static let nearLimitPercent: Double = 70
    /// How often the store checks which targets are due (not a fetch interval)
    static let tick: TimeInterval = 30
    /// Slack on top of the regular interval for "observed recently enough" judgments
    /// (a logged-in value still counts as exact, a cycle's final value isn't a lower bound)
    static let slack: TimeInterval = 5 * 60

    /// Interval until the next observation, from the account's latest batch.
    /// Windows already past their reset don't count (they are 0% now)
    static func interval(after batch: ObservationBatch?, now: Date) -> TimeInterval {
        let near = batch?.windows.contains { w in
            w.isLimit && w.percent >= nearLimitPercent && (w.resetsAt.map { $0 > now } ?? true)
        } ?? false
        return near ? nearLimit : regular
    }
}
