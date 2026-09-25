import Foundation
import IOKit
import IOKit.ps

struct BatterySnapshot: Sendable {
    var percent: Double = 0
    var isCharging = false
    var isPluggedIn = false
    var isFullyCharged = false
    /// Minutes until empty (on battery) or full (charging). Nil while macOS is still estimating.
    var minutesRemaining: Int?
    var cycleCount: Int?
    /// Cycles the battery is rated for, as reported by the battery itself (usually 1,000).
    var designCycleCount: Int?
    /// Original capacity when new, in mAh.
    var designCapacity: Int?
    /// What a full charge holds today, in mAh.
    var maxCapacity: Int?
    var temperature: Double?
    /// Positive = drawing from battery, negative = charging.
    var watts: Double?
    var voltage: Double?
    /// Milliamps; negative while discharging.
    var amperage: Int?
    /// Apple's own "Maximum Capacity" percentage (matches System Settings). Preferred over our own math.
    var appleMaxCapacityPercent: Double?
    /// Apple's condition label ("Good", "Service Recommended", …).
    var condition: String?
    var adapterWatts: Int?
    var adapterName: String?

    /// Share of the original capacity it still holds. Uses Apple's figure when available so we
    /// never disagree with System Settings.
    var healthPercent: Double? {
        if let appleMaxCapacityPercent { return appleMaxCapacityPercent }
        guard let designCapacity, let maxCapacity, designCapacity > 0 else { return nil }
        return min(100, Double(maxCapacity) / Double(designCapacity) * 100)
    }

    /// Energy in a full charge today (watt-hours), used to estimate how long a charge lasts.
    var fullChargeWattHours: Double? {
        guard let maxCapacity, let voltage, maxCapacity > 0 else { return nil }
        return Double(maxCapacity) * voltage / 1000
    }

    var statusText: String {
        if isFullyCharged && isPluggedIn { return "Fully charged" }
        if isCharging { return "Charging" }
        if isPluggedIn { return "Plugged in, not charging" }
        return "On battery"
    }
}

final class BatterySampler {
    private var appleHealth: (percent: Double?, condition: String?, cycles: Int?)?
    private var appleHealthCheckedAt = Date.distantPast

    func sample() -> BatterySnapshot? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        var snapshot: BatterySnapshot?
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description["Type"] as? String == "InternalBattery" else { continue }
            var s = BatterySnapshot()
            let current = description["Current Capacity"] as? Int ?? 0
            let max = description["Max Capacity"] as? Int ?? 100
            s.percent = max > 0 ? Double(current) / Double(max) * 100 : 0
            s.isCharging = description["Is Charging"] as? Bool ?? false
            s.isPluggedIn = description["Power Source State"] as? String == "AC Power"
            s.isFullyCharged = description["Is Charged"] as? Bool ?? false
            s.condition = description["BatteryHealth"] as? String
            let key = s.isCharging ? "Time to Full Charge" : "Time to Empty"
            if let minutes = description[key] as? Int, minutes > 0, !(s.isPluggedIn && !s.isCharging) {
                s.minutesRemaining = minutes
            }
            snapshot = s
            break
        }
        guard var snapshot else { return nil }

        if snapshot.isPluggedIn, let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            snapshot.adapterWatts = (adapter["Watts"] as? NSNumber)?.intValue
            snapshot.adapterName = adapter["Name"] as? String
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            let batteryData = property("BatteryData") as? [String: Any]
            snapshot.cycleCount = (property("CycleCount") as? NSNumber)?.intValue
            snapshot.designCycleCount = (property("DesignCycleCount9C") as? NSNumber)?.intValue
            snapshot.designCapacity = (property("DesignCapacity") as? NSNumber)?.intValue
                ?? (batteryData?["DesignCapacity"] as? NSNumber)?.intValue
            snapshot.maxCapacity = (property("AppleRawMaxCapacity") as? NSNumber)?.intValue
                ?? (property("NominalChargeCapacity") as? NSNumber)?.intValue
            if let raw = (property("Temperature") as? NSNumber)?.intValue, raw > 0 {
                snapshot.temperature = Double(raw) / 100
            }
            if let millivolts = (property("Voltage") as? NSNumber)?.intValue {
                snapshot.voltage = Double(millivolts) / 1000
                // Stored as an unsigned 64-bit bit pattern (e.g. 18446744073709550787 = −829 mA),
                // so read the raw bits and reinterpret as signed.
                if let number = (property("InstantAmperage") ?? property("Amperage")) as? NSNumber {
                    let milliamps = Int(Int64(bitPattern: number.uint64Value))
                    snapshot.amperage = milliamps
                    snapshot.watts = -Double(millivolts) * Double(milliamps) / 1_000_000
                }
            }
        }

        // Apple's own health numbers (same as System Settings). Cheap (~70 ms) but no need to
        // re-run every sample; battery health changes over weeks.
        if Date().timeIntervalSince(appleHealthCheckedAt) > 600 {
            appleHealth = Self.readAppleHealth()
            appleHealthCheckedAt = Date()
        }
        if let appleHealth {
            snapshot.appleMaxCapacityPercent = appleHealth.percent
            snapshot.condition = appleHealth.condition ?? snapshot.condition
            snapshot.cycleCount = appleHealth.cycles ?? snapshot.cycleCount
        }
        return snapshot
    }

    static func readAppleHealth() -> (percent: Double?, condition: String?, cycles: Int?)? {
        guard let output = try? Shell.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"]) else { return nil }
        return parseAppleHealth(Data(output.utf8))
    }

    static func parseAppleHealth(_ json: Data) -> (percent: Double?, condition: String?, cycles: Int?)? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]] else { return nil }
        for item in items {
            guard let health = item["sppower_battery_health_info"] as? [String: Any] else { continue }
            let percentText = (health["sppower_battery_health_maximum_capacity"] as? String)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "% "))
            return (
                percent: percentText.flatMap(Double.init),
                condition: health["sppower_battery_health"] as? String,
                cycles: (health["sppower_battery_cycle_count"] as? NSNumber)?.intValue
            )
        }
        return nil
    }
}
