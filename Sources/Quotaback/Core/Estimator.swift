import Foundation

/// Estimate for display. Recomputed every time from observations (facts) and the current time.
struct WindowEstimate: Identifiable, Hashable {
    enum Value: Hashable {
        /// Logged in now, and observed recently
        case exact(Double)
        /// Not logged in. A lower bound, since it may have been used elsewhere since
        case atLeast(Double)
        /// Past the observed reset time. Counts from 0 again (usage since then is unknown)
        case reset
    }

    enum NextReset: Hashable {
        case known(Date)
        /// Projected from the cadence
        case projected(Date)
        /// Unknown, since the window counts from first use
        case unknown
    }

    let window: WindowObservation
    let value: Value
    let nextReset: NextReset
    let observedAt: Date
    /// Projected time to reach 100% at the current pace (only when logged in, before the reset and in the future)
    let limitETA: Date?

    var id: String { window.key }

    /// For the menu bar peak. 0 once reset
    var lowerBound: Double {
        switch value {
        case .exact(let v), .atLeast(let v): return v
        case .reset: return 0
        }
    }
}

enum Estimator {
    static func estimate(_ w: WindowObservation, observedAt: Date, isLive: Bool,
                         history: [(Date, Double)] = [], now: Date = Date(),
                         calendar: Calendar = .current) -> WindowEstimate {
        let passed = w.resetsAt.map { $0 <= now } ?? false

        let value: WindowEstimate.Value
        if passed { value = .reset }
        else if isLive { value = .exact(w.percent) }
        else { value = .atLeast(w.percent) }

        return WindowEstimate(window: w, value: value,
                              nextReset: nextReset(w, now: now, calendar: calendar),
                              observedAt: observedAt,
                              // Pace only means something for the account in use
                              limitETA: passed || !w.isLimit || !isLive ? nil
                                  : limitETA(history: history, resetsAt: w.resetsAt).flatMap { $0 > now ? $0 : nil })
    }

    static func nextReset(_ w: WindowObservation, now: Date, calendar: Calendar = .current) -> WindowEstimate.NextReset {
        guard let r = w.resetsAt else { return .unknown }
        if r > now { return .known(r) }
        switch w.cadence {
        case .fixed(let period) where period > 0:
            let k = (now.timeIntervalSince(r) / period).rounded(.down) + 1
            return .projected(r.addingTimeInterval(k * period))
        case .monthly:
            var next = r
            while next <= now {
                guard let n = calendar.date(byAdding: .month, value: 1, to: next) else { return .unknown }
                next = n
            }
            return .projected(next)
        case .rolling, .unknown, .fixed:
            return .unknown
        }
    }

    /// Projects when 100% is reached by drawing a line through the first and last observations in the same reset period.
    /// Only returned when they span 10+ minutes, usage is increasing, and 100% comes before the reset.
    static func limitETA(history: [(Date, Double)], resetsAt: Date?) -> Date? {
        guard let first = history.first, let last = history.last else { return nil }
        let span = last.0.timeIntervalSince(first.0)
        let rise = last.1 - first.1
        guard span >= 600, rise > 0, last.1 < 100 else { return nil }
        let eta = last.0.addingTimeInterval((100 - last.1) / (rise / span))
        if let r = resetsAt, eta >= r { return nil }
        return eta
    }
}
