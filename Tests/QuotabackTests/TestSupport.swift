import Foundation
@testable import Quotaback

func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("quotaback-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func window(_ key: String = "weekly_all", percent: Double, resetsAt: Date?,
            cadence: Cadence = .fixed(7 * 24 * 3600), isLimit: Bool = true) -> WindowObservation {
    WindowObservation(key: key, title: key, percent: percent, resetsAt: resetsAt,
                      isLimit: isLimit, detail: nil, cadence: cadence)
}

/// 秒単位に丸めた日時（ISO8601 で保存すると秒未満が落ちるため）
func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds.rounded()) }

let t0 = date(1_790_000_000)
let hour: TimeInterval = 3600
let day: TimeInterval = 24 * hour
