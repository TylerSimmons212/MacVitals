import Foundation

/// Turns raw CPU numbers into plain-language readings. Pure functions, unit-tested.
enum CPUInsights {
    enum Level: Equatable, Sendable {
        case relaxed, busy, workingHard, maxedOut

        var title: String {
            switch self {
            case .relaxed: "Relaxed"
            case .busy: "Busy"
            case .workingHard: "Working hard"
            case .maxedOut: "Maxed out"
            }
        }

        var sentence: String {
            switch self {
            case .relaxed: "Plenty of headroom for whatever you do next."
            case .busy: "Working, with room to spare."
            case .workingHard: "Things may start to feel slower."
            case .maxedOut: "Apps will feel sluggish until this calms down."
            }
        }
    }

    /// Based on a short recent average (not the instantaneous value) so the verdict doesn't flicker.
    static func level(forAverage percent: Double) -> Level {
        switch percent {
        case ..<25: .relaxed
        case 25..<60: .busy
        case 60..<85: .workingHard
        default: .maxedOut
        }
    }

    enum Demand: Equatable, Sendable {
        case light, moderate, heavy

        var title: String {
            switch self {
            case .light: "Light"
            case .moderate: "Moderate"
            case .heavy: "Heavy"
            }
        }
    }

    /// Load average only means something relative to core count.
    /// At or above 1 task per core, work starts queuing.
    static func demand(loadAverage: Double, cores: Int) -> Demand {
        let perCore = loadAverage / Double(max(cores, 1))
        switch perCore {
        case ..<0.5: return .light
        case 0.5..<1: return .moderate
        default: return .heavy
        }
    }

    /// App CPU is measured per core (Activity Monitor style: 250% = 2.5 cores).
    /// On this page we show it as a share of total capacity so it adds up to the gauge.
    static func shareOfTotal(appCPU: Double, cores: Int) -> Double {
        appCPU / Double(max(cores, 1))
    }

    /// A single pegged core while the overall CPU is quiet usually means one app is stuck
    /// on one thread: it's slow no matter how many cores you have.
    static func singleCoreBottleneck(perCore: [Double], total: Double) -> Int? {
        guard total < 40, let (index, value) = perCore.enumerated().max(by: { $0.element < $1.element }).map({ ($0.offset, $0.element) }),
              value > 90 else { return nil }
        return index
    }

    /// Splits per-core values into (label, indices) groups. On Apple silicon the efficiency
    /// cluster is numbered first (verified on M1 Pro: background-QoS work lands on cores 0–1).
    static func clusters(coreCount: Int, efficiency: Int?, performance: Int?) -> [(name: String, range: Range<Int>)] {
        guard let efficiency, let performance, efficiency > 0, efficiency + performance == coreCount else {
            return [("Cores", 0..<coreCount)]
        }
        return [
            ("Performance", efficiency..<coreCount),
            ("Efficiency", 0..<efficiency),
        ]
    }
}
