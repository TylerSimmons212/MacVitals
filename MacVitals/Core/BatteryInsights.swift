import Foundation

/// Plain-language battery readings: is it healthy, why is (or isn't) it charging,
/// how long a charge really lasts for *you*, and which apps drain it.
enum BatteryInsights {
    enum Health: Equatable, Sendable {
        case healthy, normalWear, serviceSoon, unknown

        var title: String {
            switch self {
            case .healthy: "Your battery is healthy"
            case .normalWear: "Your battery is aging normally"
            case .serviceSoon: "Your battery needs service soon"
            case .unknown: "Checking your battery…"
            }
        }
    }

    /// Apple considers 80%+ of original capacity normal; its condition label overrides.
    static func health(percent: Double?, condition: String?) -> Health {
        if let condition, ["service", "replace", "poor", "check"].contains(where: { condition.lowercased().contains($0) }) {
            return .serviceSoon
        }
        guard let percent else { return .unknown }
        switch percent {
        case 90...: return .healthy
        case 80..<90: return .normalWear
        default: return .serviceSoon
        }
    }

    static func healthSentence(_ battery: BatterySnapshot) -> String {
        guard let percent = battery.healthPercent else { return "Reading battery details…" }
        let capacity = "It holds \(Fmt.percent(percent)) of its original charge"
        let cycles: String
        if let count = battery.cycleCount {
            let rated = battery.designCycleCount ?? 1000
            cycles = " after \(count) of about \(rated.formatted()) rated charge cycles"
        } else {
            cycles = ""
        }
        switch health(percent: percent, condition: battery.condition) {
        case .healthy: return capacity + cycles + ". Like new."
        case .normalWear: return capacity + cycles + ". That's normal wear; nothing to do yet."
        case .serviceSoon: return capacity + cycles + ". Apple recommends a battery service below 80%."
        case .unknown: return capacity + cycles + "."
        }
    }

    enum ChargingState: Equatable, Sendable {
        case charging(watts: Double?, adapterWatts: Int?)
        /// macOS is deliberately pausing around 80% to slow battery aging.
        case holdingToProtect
        case full
        case pluggedNotCharging
        case onBattery(minutesLeft: Int?)
    }

    static func chargingState(_ battery: BatterySnapshot) -> ChargingState {
        if battery.isCharging {
            return .charging(watts: battery.watts.map { abs($0) }, adapterWatts: battery.adapterWatts)
        }
        if battery.isPluggedIn {
            if battery.isFullyCharged || battery.percent >= 99 { return .full }
            if (75...95).contains(battery.percent) { return .holdingToProtect }
            return .pluggedNotCharging
        }
        return .onBattery(minutesLeft: battery.minutesRemaining)
    }

    static func chargingText(_ state: ChargingState) -> String {
        switch state {
        case .charging(let watts, let adapter):
            let rate = watts.map { String(format: "Charging at %.0f W", $0) } ?? "Charging"
            return adapter.map { rate + " · \($0) W charger" } ?? rate
        case .holdingToProtect:
            return "Paused near 80% to protect the battery"
        case .full:
            return "Fully charged"
        case .pluggedNotCharging:
            return "Plugged in, not charging"
        case .onBattery(let minutes):
            return minutes.map { "\(Fmt.duration(TimeInterval($0 * 60))) left" } ?? "On battery"
        }
    }

    static func chargingHelp(_ state: ChargingState) -> String {
        switch state {
        case .holdingToProtect:
            "Optimized Battery Charging learns your routine and waits at about 80% until you need it. It keeps the battery healthier for longer. Nothing is wrong."
        case .pluggedNotCharging:
            "macOS sometimes pauses charging (for example when warm). If it never charges, try another charger or cable."
        case .charging(_, let adapter):
            adapter.map { "Your \($0) W charger is connected. A weaker charger charges slowly, or not at all under heavy load." } ?? "Charging."
        default:
            ""
        }
    }

    /// Average power drawn while running on battery, from history. Nil until there's at least
    /// an hour of unplugged use to learn from.
    static func typicalDrain(samples: [HistorySample], sampleLength: TimeInterval) -> Double? {
        let unplugged = samples.compactMap(\.batteryWatts).filter { $0 > 0.3 }
        guard Double(unplugged.count) * sampleLength >= 3600 else { return nil }
        return unplugged.reduce(0, +) / Double(unplugged.count)
    }

    /// How long a full charge lasts at a given draw.
    static func hours(fullChargeWattHours: Double?, watts: Double?) -> Double? {
        guard let wh = fullChargeWattHours, let watts, watts > 0.3 else { return nil }
        return wh / watts
    }

    static func describe(hours: Double) -> String {
        let rounded = (hours * 2).rounded() / 2 // nearest half hour
        if rounded < 1 { return "under an hour" }
        let whole = Int(rounded)
        return rounded == Double(whole) ? "about \(whole) hour\(whole == 1 ? "" : "s")" : "about \(whole)½ hours"
    }

    enum Impact: Equatable, Sendable {
        case high, medium, low

        var label: String {
            switch self {
            case .high: "High"
            case .medium: "Medium"
            case .low: "Low"
            }
        }
    }

    static func impact(watts: Double) -> Impact {
        switch watts {
        case 2...: .high
        case 0.5..<2: .medium
        default: .low
        }
    }
}
