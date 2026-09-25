import Foundation

struct HistorySample: Codable, Sendable {
    let date: Date
    let cpuUser: Double
    let cpuSystem: Double
    let memoryUsedPercent: Double
    let networkIn: Double
    let networkOut: Double
    let diskRead: Double
    let diskWrite: Double
    let batteryPercent: Double?
    /// Bytes swapped to disk. Optional: history saved before this field existed decodes as nil.
    var swapUsed: Double? = nil
    /// Free bytes on the startup disk. Optional for the same reason.
    var diskFree: Double? = nil
    /// 1 when memory pressure was elevated or critical, else 0. Bucket averages = share of time tight.
    var memoryTight: Double? = nil
    /// Watts drawn from the battery. Only recorded while running on battery, so averages
    /// describe real unplugged use (not charging).
    var batteryWatts: Double? = nil

    var cpuTotal: Double { cpuUser + cpuSystem }
}

struct ChartPoint: Identifiable, Sendable {
    let date: Date
    let value: Double
    let series: String
    /// Increments at every data gap; charts draw each segment separately.
    var segment: Int = 0

    var id: String { "\(series)|\(date.timeIntervalSinceReferenceDate)" }
    var segmentKey: String { "\(series)#\(segment)" }
}

/// Fixed-size rolling buffer of samples for the live charts.
struct MetricHistory: Sendable {
    let capacity: Int
    private(set) var samples: [HistorySample] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ sample: HistorySample) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    func samples(within window: TimeInterval, now: Date = Date()) -> ArraySlice<HistorySample> {
        let cutoff = now.addingTimeInterval(-window)
        guard let start = samples.firstIndex(where: { $0.date >= cutoff }) else { return [] }
        return samples[start...]
    }

    func average(_ keyPath: KeyPath<HistorySample, Double>, over window: TimeInterval, now: Date = Date()) -> Double {
        let recent = samples(within: window, now: now)
        guard !recent.isEmpty else { return 0 }
        return recent.reduce(0) { $0 + $1[keyPath: keyPath] } / Double(recent.count)
    }
}
