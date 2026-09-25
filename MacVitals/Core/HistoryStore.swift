import Foundation

/// Chart ranges. The point of history is telling a *spike* (normal) from a *pattern*
/// (worth fixing), so ranges start at an hour, not minutes.
enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case hour, day, week, month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .hour: "1H"
        case .day: "24H"
        case .week: "7D"
        case .month: "30D"
        }
    }

    var longLabel: String {
        switch self {
        case .hour: "last hour"
        case .day: "last 24 hours"
        case .week: "last 7 days"
        case .month: "last 30 days"
        }
    }

    var duration: TimeInterval {
        switch self {
        case .hour: 3_600
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }

    /// Spacing of samples in the tier that serves this range.
    var resolution: TimeInterval {
        switch self {
        case .hour: 5
        case .day: 60
        case .week, .month: 900
        }
    }
}

/// Running sum used to average raw samples into a coarser bucket.
struct BucketAccumulator: Codable, Sendable, Equatable {
    let start: Date
    var count = 0
    var cpuUser = 0.0, cpuSystem = 0.0, memory = 0.0
    var netIn = 0.0, netOut = 0.0, diskRead = 0.0, diskWrite = 0.0
    var battery = 0.0, batteryCount = 0
    // Optional so buckets saved by older versions still decode.
    var swap: Double? = nil
    var swapCount: Int? = nil
    var diskFree: Double? = nil
    var diskFreeCount: Int? = nil
    var memoryTight: Double? = nil
    var memoryTightCount: Int? = nil
    var batteryWatts: Double? = nil
    var batteryWattsCount: Int? = nil

    init(start: Date) { self.start = start }

    mutating func add(_ s: HistorySample) {
        count += 1
        cpuUser += s.cpuUser
        cpuSystem += s.cpuSystem
        memory += s.memoryUsedPercent
        netIn += s.networkIn
        netOut += s.networkOut
        diskRead += s.diskRead
        diskWrite += s.diskWrite
        if let b = s.batteryPercent {
            battery += b
            batteryCount += 1
        }
        if let sw = s.swapUsed {
            swap = (swap ?? 0) + sw
            swapCount = (swapCount ?? 0) + 1
        }
        if let free = s.diskFree {
            diskFree = (diskFree ?? 0) + free
            diskFreeCount = (diskFreeCount ?? 0) + 1
        }
        if let tight = s.memoryTight {
            memoryTight = (memoryTight ?? 0) + tight
            memoryTightCount = (memoryTightCount ?? 0) + 1
        }
        if let watts = s.batteryWatts {
            batteryWatts = (batteryWatts ?? 0) + watts
            batteryWattsCount = (batteryWattsCount ?? 0) + 1
        }
    }

    func average(length: TimeInterval) -> HistorySample {
        let n = Double(max(count, 1))
        return HistorySample(
            date: start.addingTimeInterval(length / 2),
            cpuUser: cpuUser / n, cpuSystem: cpuSystem / n, memoryUsedPercent: memory / n,
            networkIn: netIn / n, networkOut: netOut / n, diskRead: diskRead / n, diskWrite: diskWrite / n,
            batteryPercent: batteryCount > 0 ? battery / Double(batteryCount) : nil,
            swapUsed: (swapCount ?? 0) > 0 ? (swap ?? 0) / Double(swapCount ?? 1) : nil,
            diskFree: (diskFreeCount ?? 0) > 0 ? (diskFree ?? 0) / Double(diskFreeCount ?? 1) : nil,
            memoryTight: (memoryTightCount ?? 0) > 0 ? (memoryTight ?? 0) / Double(memoryTightCount ?? 1) : nil,
            batteryWatts: (batteryWattsCount ?? 0) > 0 ? (batteryWatts ?? 0) / Double(batteryWattsCount ?? 1) : nil
        )
    }
}

/// Three tiers of history:
/// - live: every sample, last ~hour (memory only)
/// - minute: 1-minute averages, last 24h (persisted)
/// - quarter: 15-minute averages, last 30 days (persisted)
/// About 4,300 persisted samples in total (~350 KB).
struct TieredHistory: Sendable {
    static let minuteLength: TimeInterval = 60
    static let quarterLength: TimeInterval = 900

    private(set) var live = MetricHistory(capacity: 1_800)
    private(set) var minute: [HistorySample] = []
    private(set) var quarter: [HistorySample] = []
    private var minuteBucket: BucketAccumulator?
    private var quarterBucket: BucketAccumulator?

    init() {}

    mutating func append(_ sample: HistorySample) {
        live.append(sample)
        minuteBucket = Self.accumulate(sample, into: minuteBucket, length: Self.minuteLength, output: &minute)
        quarterBucket = Self.accumulate(sample, into: quarterBucket, length: Self.quarterLength, output: &quarter)
        prune(now: sample.date)
    }

    private static func accumulate(_ sample: HistorySample, into bucket: BucketAccumulator?,
                                   length: TimeInterval, output: inout [HistorySample]) -> BucketAccumulator {
        let start = Date(timeIntervalSinceReferenceDate: floor(sample.date.timeIntervalSinceReferenceDate / length) * length)
        var current = bucket ?? BucketAccumulator(start: start)
        if current.start != start {
            if current.count > 0 { output.append(current.average(length: length)) }
            current = BucketAccumulator(start: start)
        }
        current.add(sample)
        return current
    }

    private mutating func prune(now: Date) {
        let dayAgo = now.addingTimeInterval(-HistoryRange.day.duration)
        if let first = minute.first, first.date < dayAgo {
            minute.removeAll { $0.date < dayAgo }
        }
        let monthAgo = now.addingTimeInterval(-HistoryRange.month.duration)
        if let first = quarter.first, first.date < monthAgo {
            quarter.removeAll { $0.date < monthAgo }
        }
    }

    /// Samples covering `range`, oldest first. Includes the in-progress bucket so charts reach "now".
    func samples(for range: HistoryRange, now: Date = Date()) -> [HistorySample] {
        let cutoff = now.addingTimeInterval(-range.duration)
        switch range {
        case .hour:
            return Array(live.samples(within: range.duration, now: now))
        case .day:
            return (minute + [minuteBucket].compactMap { $0?.average(length: Self.minuteLength) })
                .filter { $0.date >= cutoff }
        case .week, .month:
            return (quarter + [quarterBucket].compactMap { $0?.average(length: Self.quarterLength) })
                .filter { $0.date >= cutoff }
        }
    }

    /// Chart points, split into segments wherever data is missing (e.g. Mac Vitals wasn't
    /// running) so charts show a gap instead of a misleading straight line.
    func points(_ keyPath: KeyPath<HistorySample, Double>, series: String, range: HistoryRange) -> [ChartPoint] {
        segmented(samples(for: range), range: range) { sample, segment in
            ChartPoint(date: sample.date, value: sample[keyPath: keyPath], series: series, segment: segment)
        }
    }

    func points(_ keyPath: KeyPath<HistorySample, Double?>, series: String, range: HistoryRange) -> [ChartPoint] {
        segmented(samples(for: range), range: range) { sample, segment in
            sample[keyPath: keyPath].map { ChartPoint(date: sample.date, value: $0, series: series, segment: segment) }
        }
    }

    /// More points than a chart can show just costs render time.
    static let maxChartPoints = 360

    private func segmented(_ samples: [HistorySample], range: HistoryRange,
                           make: (HistorySample, Int) -> ChartPoint?) -> [ChartPoint] {
        // Live samples come every 2–5s; anything much longer than the tier's spacing is a gap.
        let maxGap = max(range.resolution * 4, 30)
        var segment = 0
        var previous: Date?
        let raw = samples.compactMap { sample -> ChartPoint? in
            if let previous, sample.date.timeIntervalSince(previous) > maxGap { segment += 1 }
            previous = sample.date
            return make(sample, segment)
        }
        return Self.downsample(raw, to: Self.maxChartPoints)
    }

    /// Averages consecutive points (never across a gap) until there are at most `limit`.
    static func downsample(_ points: [ChartPoint], to limit: Int) -> [ChartPoint] {
        guard points.count > limit, limit > 0 else { return points }
        let groupSize = Int((Double(points.count) / Double(limit)).rounded(.up))
        var result: [ChartPoint] = []
        result.reserveCapacity(limit + 8)
        var group: [ChartPoint] = []
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let mean = group.reduce(0) { $0 + $1.value } / Double(group.count)
            let mid = Date(timeIntervalSinceReferenceDate: (first.date.timeIntervalSinceReferenceDate + last.date.timeIntervalSinceReferenceDate) / 2)
            result.append(ChartPoint(date: mid, value: mean, series: first.series, segment: first.segment))
            group.removeAll(keepingCapacity: true)
        }
        for point in points {
            if let last = group.last, last.segment != point.segment || group.count == groupSize { flush() }
            group.append(point)
        }
        flush()
        return result
    }

    /// Earliest timestamp we have data for, across tiers.
    var earliestDate: Date? {
        [quarter.first?.date, minute.first?.date, live.samples.first?.date].compactMap { $0 }.min()
    }

    // MARK: Persistence

    /// Everything needed to pick up exactly where we left off, including the last hour of raw
    /// samples and the half-finished averages (without those, frequent restarts meant the
    /// 15-minute tier never recorded anything).
    struct Archive: Codable {
        var version = 2
        var minute: [HistorySample]
        var quarter: [HistorySample]
        var live: [HistorySample]? = nil
        var minuteBucket: BucketAccumulator? = nil
        var quarterBucket: BucketAccumulator? = nil
    }

    var archive: Archive {
        Archive(minute: minute, quarter: quarter, live: live.samples,
                minuteBucket: minuteBucket, quarterBucket: quarterBucket)
    }

    init(archive: Archive, now: Date = Date()) {
        minute = archive.minute.sorted { $0.date < $1.date }
        quarter = archive.quarter.sorted { $0.date < $1.date }
        let hourAgo = now.addingTimeInterval(-HistoryRange.hour.duration)
        for sample in (archive.live ?? []).sorted(by: { $0.date < $1.date }) where sample.date >= hourAgo {
            live.append(sample)
        }
        minuteBucket = Self.resume(archive.minuteBucket, length: Self.minuteLength, now: now, output: &minute)
        quarterBucket = Self.resume(archive.quarterBucket, length: Self.quarterLength, now: now, output: &quarter)
        prune(now: now)
    }

    /// A saved half-finished bucket either continues (we're still inside its time window)
    /// or is closed out as a completed average.
    private static func resume(_ bucket: BucketAccumulator?, length: TimeInterval, now: Date,
                               output: inout [HistorySample]) -> BucketAccumulator? {
        guard let bucket, bucket.count > 0 else { return nil }
        let currentStart = Date(timeIntervalSinceReferenceDate: floor(now.timeIntervalSinceReferenceDate / length) * length)
        if bucket.start == currentStart { return bucket }
        if bucket.start < currentStart, !output.contains(where: { $0.date == bucket.start.addingTimeInterval(length / 2) }) {
            output.append(bucket.average(length: length))
            output.sort { $0.date < $1.date }
        }
        return nil
    }
}

/// Reads/writes the persisted history tiers in Application Support.
enum HistoryPersistence {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "MacVitals/history.json")
    }

    static func load(from url: URL = fileURL, now: Date = Date()) -> TieredHistory {
        guard let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(TieredHistory.Archive.self, from: data) else {
            return TieredHistory()
        }
        return TieredHistory(archive: archive, now: now)
    }

    static func save(_ history: TieredHistory, to url: URL = fileURL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(history.archive)
            try data.write(to: url, options: .atomic)
        } catch {
            // History is a nice-to-have; never let a write failure affect monitoring.
        }
    }
}
