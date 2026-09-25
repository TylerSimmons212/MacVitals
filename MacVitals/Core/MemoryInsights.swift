import Foundation

/// Plain-language memory readings. The key idea: a high "used" number is normal on a Mac
/// (it keeps spare RAM busy as cache). What matters is *pressure* and *swap*.
enum MemoryInsights {
    enum Level: Equatable, Sendable {
        case comfortable, recentlyTight, gettingTight, underStrain

        var title: String {
            switch self {
            case .comfortable, .recentlyTight: "comfortable"
            case .gettingTight: "getting tight"
            case .underStrain: "under strain"
            }
        }

        var sentence: String {
            switch self {
            case .comfortable:
                "Everything fits in RAM with room to spare."
            case .recentlyTight:
                "Fine right now, but some memory spilled onto the disk earlier. Restarting heavy apps can reclaim it."
            case .gettingTight:
                "macOS is compressing memory to make room. Switching between apps may feel slower."
            case .underStrain:
                "You're out of RAM and your Mac is leaning on the much slower disk. Quit something big."
            }
        }
    }

    /// Swap below this is housekeeping, not a sign of trouble.
    static let notableSwap: UInt64 = 1 << 30 // 1 GB

    static func level(pressure: MemoryPressure, swapUsed: UInt64) -> Level {
        switch pressure {
        case .critical: return .underStrain
        case .warning: return .gettingTight
        case .normal: return swapUsed >= notableSwap ? .recentlyTight : .comfortable
        }
    }

    /// One slice of the composition bar, with a friendly name, the technical term and a meaning.
    struct Slice: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let term: String
        let bytes: UInt64
        let meaning: String
    }

    static func composition(_ memory: MemorySnapshot) -> [Slice] {
        [
            Slice(id: "app", name: "Apps", term: "App memory", bytes: memory.app,
                  meaning: "Used by the apps you have open."),
            Slice(id: "wired", name: "System", term: "Wired", bytes: memory.wired,
                  meaning: "Reserved by macOS; can't be freed."),
            Slice(id: "compressed", name: "Compressed", term: "Compressed", bytes: memory.compressed,
                  meaning: "Squeezed to make room. Lots of it means RAM is tight."),
            Slice(id: "cached", name: "Ready to reuse", term: "Cached files", bytes: memory.cached,
                  meaning: "Recently used files kept for speed. Freed instantly when needed."),
            Slice(id: "free", name: "Free", term: "Free", bytes: memory.free,
                  meaning: "Completely unused. A low number here is normal."),
        ]
    }

    static func shareOfRAM(_ bytes: UInt64, total: UInt64) -> Double {
        total > 0 ? Double(bytes) / Double(total) * 100 : 0
    }
}

// MARK: - Is your RAM enough?

extension MemoryInsights {
    enum Adequacy: Equatable, Sendable {
        case collecting(hoursNeeded: Int)
        /// Comfortable percent of the time is carried for display.
        case plenty(comfortablePercent: Double)
        case mostlyEnough(comfortablePercent: Double)
        case oftenShort(comfortablePercent: Double)

        var comfortablePercent: Double? {
            switch self {
            case .collecting: nil
            case .plenty(let p), .mostlyEnough(let p), .oftenShort(let p): p
            }
        }
    }

    static let adequacyMinimumSpan: TimeInterval = 12 * 3600

    /// Long-term verdict from the share of time memory pressure was elevated.
    static func adequacy(samples: [HistorySample]) -> Adequacy {
        let tight = samples.compactMap { s in s.memoryTight.map { (s.date, $0) } }
        guard let first = tight.first, let last = tight.last,
              last.0.timeIntervalSince(first.0) >= adequacyMinimumSpan else {
            let span = tight.first.flatMap { f in tight.last.map { $0.0.timeIntervalSince(f.0) } } ?? 0
            return .collecting(hoursNeeded: max(1, Int(((adequacyMinimumSpan - span) / 3600).rounded(.up))))
        }
        let tightShare = tight.reduce(0) { $0 + $1.1 } / Double(tight.count)
        let comfortable = (1 - tightShare) * 100
        switch tightShare {
        case ..<0.01: return .plenty(comfortablePercent: comfortable)
        case ..<0.05: return .mostlyEnough(comfortablePercent: comfortable)
        default: return .oftenShort(comfortablePercent: comfortable)
        }
    }

    /// Standard Mac memory configurations, for "your next Mac" advice.
    static let memoryTiers = [8, 16, 24, 32, 36, 48, 64, 96, 128, 192, 256]

    static func installedGB(_ bytes: UInt64) -> Int {
        Int((Double(bytes) / Double(1 << 30)).rounded())
    }

    static func headline(_ adequacy: Adequacy, installed: UInt64) -> String {
        let gb = installedGB(installed)
        switch adequacy {
        case .collecting: return "Learning how you use your Mac"
        case .plenty: return "\(gb) GB has been plenty for you"
        case .mostlyEnough: return "\(gb) GB is enough most of the time"
        case .oftenShort: return "You often run short on memory"
        }
    }

    static func explanation(_ adequacy: Adequacy) -> String {
        switch adequacy {
        case .collecting(let hours):
            "After about \(hours) more hour\(hours == 1 ? "" : "s") of history, Mac Vitals can tell you whether your RAM keeps up with how you work."
        case .plenty:
            "Memory has stayed comfortable nearly all the time, even with everything you run."
        case .mostlyEnough:
            "It gets tight now and then, usually with lots of apps or tabs open. Closing unused apps at those moments keeps things smooth."
        case .oftenShort:
            "Memory is regularly under pressure, which makes your Mac slower. Closing heavy apps helps day to day."
        }
    }

    /// Plain buying advice. Only recommends more when the data says so.
    static func nextMacAdvice(_ adequacy: Adequacy, installed: UInt64) -> String? {
        let gb = installedGB(installed)
        switch adequacy {
        case .collecting: return nil
        case .plenty, .mostlyEnough:
            return "For your next Mac, \(gb) GB matches how you work."
        case .oftenShort:
            let next = memoryTiers.first { $0 > gb } ?? gb * 2
            return "For your next Mac, consider \(next) GB or more."
        }
    }
}

// MARK: - Free up memory

extension MemoryInsights {
    struct CloseSuggestion: Identifiable, Sendable {
        let app: AppUsage
        /// nil = not used at all since Mac Vitals started tracking.
        let lastUsed: Date?
        var id: String { app.id }
    }

    static let suggestionMinimumMemory: UInt64 = 400 << 20 // 400 MB
    static let suggestionIdleTime: TimeInterval = 30 * 60

    /// Heavy apps you haven't switched to in a while: the ones worth quitting first.
    static func closeSuggestions(apps: [AppUsage], lastUsed: (String) -> Date?, trackingSince: Date,
                                 now: Date = Date(), limit: Int = 5) -> [CloseSuggestion] {
        // Until we've watched for a while, "not used" doesn't mean anything yet.
        guard now.timeIntervalSince(trackingSince) >= suggestionIdleTime else { return [] }
        return apps
            .filter { $0.kind == .application && !$0.isCurrentApp && $0.memory >= suggestionMinimumMemory }
            .compactMap { app -> CloseSuggestion? in
                // Never suggest quitting parts of macOS (Finder, Dock…).
                guard let path = app.bundlePath, !path.hasPrefix("/System/") else { return nil }
                let used = lastUsed(path)
                if let used, now.timeIntervalSince(used) < suggestionIdleTime { return nil }
                return CloseSuggestion(app: app, lastUsed: used)
            }
            .sorted { $0.app.memory > $1.app.memory }
            .prefix(limit)
            .map { $0 }
    }

    static func describeLastUsed(_ date: Date?, trackingSince: Date, now: Date = Date()) -> String {
        guard let date else {
            return "Not used since \(trackingSince.formatted(date: now.timeIntervalSince(trackingSince) > 86_400 ? .abbreviated : .omitted, time: .shortened))"
        }
        let minutes = now.timeIntervalSince(date) / 60
        switch minutes {
        case ..<90: return "Last used \(Int(minutes)) min ago"
        case ..<(48 * 60): return "Last used \(Int((minutes / 60).rounded())) h ago"
        default: return "Last used \(Int((minutes / 1440).rounded())) days ago"
        }
    }
}
