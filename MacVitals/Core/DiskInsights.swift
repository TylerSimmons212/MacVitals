import Foundation

/// Plain-language disk readings. Free space is what matters for a startup disk:
/// macOS needs room for updates, swap and caches.
enum DiskInsights {
    enum Level: Equatable, Sendable {
        case plenty, gettingFull, runningLow, almostFull

        var title: String {
            switch self {
            case .plenty: "has plenty of room"
            case .gettingFull: "is getting full"
            case .runningLow: "is running low"
            case .almostFull: "is almost full"
            }
        }

        var sentence: String {
            switch self {
            case .plenty: "Plenty of room for updates, swap and new files."
            case .gettingFull: "Still fine, but macOS works best with at least 15% free."
            case .runningLow: "Updates can fail and things slow down when space runs short. Time to clean up."
            case .almostFull: "Free up space now to avoid slowdowns, failed updates and apps that can't save."
            }
        }
    }

    /// Same thresholds as the health score, so the page and the score always agree.
    static func level(freePercent: Double) -> Level {
        switch freePercent {
        case ..<5: .almostFull
        case 5..<10: .runningLow
        case 10..<15: .gettingFull
        default: .plenty
        }
    }

    /// Major macOS updates need roughly this much free space to download and install.
    static let updateHeadroom: Int64 = 25_000_000_000

    static func tooSmallForUpdates(available: Int64) -> Bool {
        available > 0 && available < updateHeadroom
    }

    /// Change in free space across the samples (negative = space is being used up).
    static func freeSpaceChange(_ samples: [HistorySample]) -> Double? {
        let values = samples.compactMap(\.diskFree)
        guard let first = values.first, let last = values.last, values.count >= 2 else { return nil }
        return last - first
    }

    /// Plain description of a change in free space, or nil if it's too small to mention.
    static func describeChange(_ delta: Double, over range: HistoryRange) -> String? {
        guard abs(delta) >= 500_000_000 else { return "Free space has been steady over the \(range.longLabel)." }
        let amount = Fmt.bytes(Int64(abs(delta)))
        return delta < 0
            ? "Free space went down by \(amount) over the \(range.longLabel)."
            : "Free space went up by \(amount) over the \(range.longLabel)."
    }
}

// MARK: - Forecast

extension DiskInsights {
    enum Forecast: Equatable, Sendable {
        /// Not enough history yet to say anything honest.
        case collecting(hoursNeeded: Int)
        case steady
        case freeingUp
        case runsOut(days: Double)

        var headline: String {
            switch self {
            case .collecting: "Forecast after a day of history"
            case .steady: "Free space is steady"
            case .freeingUp: "Free space is growing"
            case .runsOut(let days): "Runs out in \(DiskInsights.describe(days: days))"
            }
        }

        var sentence: String {
            switch self {
            case .collecting(let hours):
                "Mac Vitals needs about \(hours) more hour\(hours == 1 ? "" : "s") of history to predict when you'll run out."
            case .steady: "At this rate you won't run out of space any time soon."
            case .freeingUp: "You've been freeing up space recently."
            case .runsOut(let days): "At this rate, you'll run out of space in \(DiskInsights.describe(days: days))."
            }
        }
    }

    /// Minimum history before forecasting, and the smallest daily loss worth calling a trend.
    static let forecastMinimumSpan: TimeInterval = 12 * 3600
    static let steadyThresholdPerDay: Double = 200_000_000 // 0.2 GB/day

    /// Linear trend of free space over the available history, projected to zero.
    static func forecast(samples: [HistorySample], currentFree: Int64) -> Forecast {
        let points = samples.compactMap { s in s.diskFree.map { (s.date.timeIntervalSinceReferenceDate, $0) } }
        guard let first = points.first, let last = points.last else {
            return .collecting(hoursNeeded: Int(forecastMinimumSpan / 3600))
        }
        let span = last.0 - first.0
        guard span >= forecastMinimumSpan, points.count >= 12 else {
            return .collecting(hoursNeeded: max(1, Int(((forecastMinimumSpan - span) / 3600).rounded(.up))))
        }
        // Least-squares slope (bytes per second).
        let n = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.0 } / n
        let meanY = points.reduce(0) { $0 + $1.1 } / n
        let numerator = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let denominator = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.0 - meanX) }
        guard denominator > 0 else { return .steady }
        let perDay = numerator / denominator * 86_400

        if perDay > steadyThresholdPerDay { return .freeingUp }
        if perDay > -steadyThresholdPerDay { return .steady }
        let days = Double(currentFree) / -perDay
        return days > 365 ? .steady : .runsOut(days: days)
    }

    static func describe(days: Double) -> String {
        switch days {
        case ..<1.5: return "about a day"
        case ..<14: return "about \(Int(days.rounded())) days"
        case ..<60: return "about \(Int((days / 7).rounded())) weeks"
        default: return "about \(Int((days / 30).rounded())) months"
        }
    }
}
