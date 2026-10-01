import Foundation

/// 表示用の推定値。観測（事実）と今の時刻から毎回計算する。
struct WindowEstimate: Identifiable, Hashable {
    enum Value: Hashable {
        /// いまログイン中で、直近に観測できた値
        case exact(Double)
        /// ログインしていない。観測後も他の端末などで使われている可能性があるので下限
        case atLeast(Double)
        /// 観測時のリセット時刻を過ぎた。0 から数え直し（ここからの使用量は分からない）
        case reset
    }

    enum NextReset: Hashable {
        case known(Date)
        /// 周期から推定した時刻
        case projected(Date)
        /// 使い始めから数える枠なので分からない
        case unknown
    }

    let window: WindowObservation
    let value: Value
    let nextReset: NextReset
    let observedAt: Date
    /// 今のペースで使い続けたときに 100% に達する推定時刻（リセットより前のときだけ）
    let limitETA: Date?

    var id: String { window.key }

    /// メニューバーのピーク値計算用。リセット済みは 0
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
                              limitETA: passed || !w.isLimit ? nil : limitETA(history: history, resetsAt: w.resetsAt))
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

    /// 同じリセット周期内の観測から、最初と最後を結んだ直線で 100% 到達時刻を推定する。
    /// 10分以上の幅・増加傾向・リセット前に到達、のときだけ返す。
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
