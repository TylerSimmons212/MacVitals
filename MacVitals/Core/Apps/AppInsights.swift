import Foundation
import AppKit

/// Plain-language readings for the Apps page: what kind of thing an app is, how much impact
/// it has on your Mac, and whether it's misbehaving (stuck busy, or memory that keeps growing).
enum AppInsights {
    // MARK: Role

    enum Role: String, CaseIterable, Identifiable, Sendable {
        /// Apps you opened: they have a Dock icon and windows.
        case app
        /// Menu bar utilities and background apps.
        case background
        /// Parts of macOS itself.
        case system

        var id: String { rawValue }

        var title: String {
            switch self {
            case .app: "Apps"
            case .background: "Background"
            case .system: "macOS"
            }
        }

        var label: String {
            switch self {
            case .app: "App"
            case .background: "Background"
            case .system: "macOS"
            }
        }
    }

    /// Activation policy by bundle path, from the apps macOS knows are running.
    @MainActor
    static func activationPolicies() -> [String: NSApplication.ActivationPolicy] {
        var result: [String: NSApplication.ActivationPolicy] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let path = app.bundleURL?.path { result[path] = app.activationPolicy }
        }
        return result
    }

    static func role(for app: AppUsage, policies: [String: NSApplication.ActivationPolicy]) -> Role {
        switch app.kind {
        case .system: return .system
        case .process: return .background
        case .application:
            guard let path = app.bundlePath else { return .background }
            if path.hasPrefix("/System/") && policies[path] != .regular { return .system }
            return policies[path] == .regular ? .app : .background
        }
    }

    // MARK: Impact

    enum Impact: Int, Comparable, Sendable {
        case low = 0, medium = 1, high = 2

        static func < (a: Impact, b: Impact) -> Bool { a.rawValue < b.rawValue }

        var label: String {
            switch self {
            case .high: "High impact"
            case .medium: "Medium"
            case .low: "Low"
            }
        }
    }

    /// One number combining CPU (share of all cores), memory (share of RAM) and energy.
    /// 1.0 ≈ "noticeable": 10% of the CPU, 10% of RAM, or 2 W of power.
    static func impactScore(_ app: AppUsage, cores: Int, totalRAM: UInt64) -> Double {
        let cpuShare = app.cpu / Double(max(cores, 1)) // percent of total CPU
        let ramShare = totalRAM > 0 ? Double(app.memory) / Double(totalRAM) * 100 : 0
        return max(cpuShare / 10, ramShare / 10, app.watts / 2)
    }

    static func impact(score: Double) -> Impact {
        switch score {
        case 1...: .high
        case 0.3..<1: .medium
        default: .low
        }
    }

    // MARK: Misbehavior

    struct TrendPoint: Sendable, Equatable {
        let date: Date
        let cpu: Double      // percent of one core
        let memory: UInt64
    }

    enum Flag: Equatable, Sendable {
        /// Busy nonstop: averaged `averageCPU`% of a core for at least `minutes`.
        case stuckBusy(averageCPU: Double, minutes: Int)
        /// Memory grew steadily from `from` to `to` over `minutes`: a possible leak.
        case growingMemory(from: UInt64, to: UInt64, minutes: Int)

        var title: String {
            switch self {
            case .stuckBusy(_, let minutes): "Busy nonstop for \(minutes) min"
            case .growingMemory(_, _, let minutes): "Memory keeps growing (\(minutes) min)"
            }
        }

        var detail: String {
            switch self {
            case .stuckBusy(let cpu, _):
                "Using \(Fmt.percent(cpu)) of a core the whole time. If you're not waiting on it, it may be stuck. Quitting and reopening usually fixes it."
            case .growingMemory(let from, let to, _):
                "Grew from \(Fmt.memory(from)) to \(Fmt.memory(to)) and hasn't come back down. That's often a memory leak. Restarting the app frees it."
            }
        }
    }

    static let busyThreshold = 80.0          // % of one core
    static let busyWindow: TimeInterval = 5 * 60
    static let growthWindow: TimeInterval = 20 * 60
    static let growthMinimum: UInt64 = 1 << 30   // 1 GB

    /// Stuck busy: every point in the last 5 minutes is high, and there are enough points to be sure.
    static func stuckBusy(_ points: [TrendPoint], now: Date) -> Flag? {
        let recent = points.filter { now.timeIntervalSince($0.date) <= busyWindow }
        guard recent.count >= 5,
              let first = recent.first, now.timeIntervalSince(first.date) >= busyWindow * 0.8,
              recent.allSatisfy({ $0.cpu >= busyThreshold * 0.6 }) else { return nil }
        let average = recent.reduce(0) { $0 + $1.cpu } / Double(recent.count)
        guard average >= busyThreshold else { return nil }
        // How long it's been busy, looking back past the window.
        let streakStart = points.reversed().prefix { $0.cpu >= busyThreshold * 0.6 }.last?.date ?? first.date
        return .stuckBusy(averageCPU: average, minutes: max(5, Int(now.timeIntervalSince(streakStart) / 60)))
    }

    /// Growing memory: up by 1 GB+ and 50%+ over 20+ minutes, rising most of the way.
    static func growingMemory(_ points: [TrendPoint], now: Date) -> Flag? {
        guard let first = points.first, let last = points.last,
              last.date.timeIntervalSince(first.date) >= growthWindow, points.count >= 8 else { return nil }
        let start = points.prefix(3).map(\.memory).min() ?? first.memory
        let end = last.memory
        guard end > start, end - start >= growthMinimum, Double(end) >= Double(start) * 1.5 else { return nil }
        let steps = zip(points, points.dropFirst())
        let rising = steps.filter { $1.memory >= $0.memory }.count
        guard Double(rising) / Double(points.count - 1) >= 0.6 else { return nil }
        return .growingMemory(from: start, to: end, minutes: Int(last.date.timeIntervalSince(first.date) / 60))
    }

    static func flags(_ points: [TrendPoint], now: Date = Date()) -> [Flag] {
        [stuckBusy(points, now: now), growingMemory(points, now: now)].compactMap { $0 }
    }
}

/// Keeps a short per-app history (last ~45 minutes) so we can spot apps that are stuck busy or
/// leaking memory. Fed from every process sample, including the slower background ones.
struct AppTrendTracker: Sendable {
    static let retention: TimeInterval = 45 * 60
    private(set) var points: [String: [AppInsights.TrendPoint]] = [:]

    mutating func record(_ apps: [AppUsage], at date: Date) {
        var seen = Set<String>()
        for app in apps where app.kind != .system {
            seen.insert(app.id)
            var series = points[app.id, default: []]
            // Thin to at most one point per 20s so long windows stay small.
            if let last = series.last, date.timeIntervalSince(last.date) < 20 { continue }
            series.append(.init(date: date, cpu: app.cpu, memory: app.memory))
            series.removeAll { date.timeIntervalSince($0.date) > Self.retention }
            points[app.id] = series
        }
        // Forget apps that quit.
        points = points.filter { seen.contains($0.key) }
    }

    func flags(now: Date = Date()) -> [String: [AppInsights.Flag]] {
        points.compactMapValues { series in
            let flags = AppInsights.flags(series, now: now)
            return flags.isEmpty ? nil : flags
        }
    }
}
