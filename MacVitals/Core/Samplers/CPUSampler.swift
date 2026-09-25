import Foundation
import Darwin

struct CPUSnapshot: Sendable {
    /// Share of total CPU capacity, 0...100.
    var user: Double = 0
    var system: Double = 0
    /// Per-core busy percentage, 0...100.
    var perCore: [Double] = []
    var loadAverage: [Double] = [0, 0, 0]

    var total: Double { min(100, user + system) }

    static let zero = CPUSnapshot()
}

/// Reads per-core tick counters from the Mach host and turns deltas into percentages.
final class CPUSampler {
    private struct Ticks {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    private var previous: [Ticks] = []

    func sample() -> CPUSnapshot {
        var snapshot = CPUSnapshot()
        snapshot.loadAverage = Self.loadAverage()

        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else {
            return snapshot
        }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        let stride = Int(CPU_STATE_MAX)
        var current: [Ticks] = []
        current.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * stride
            current.append(Ticks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            ))
        }
        defer { previous = current }
        guard previous.count == current.count else { return snapshot }

        var userTotal = 0.0, systemTotal = 0.0, allTotal = 0.0
        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        for (old, new) in zip(previous, current) {
            // Counters are 32-bit and wrap; wrapping subtraction handles that.
            let user = Double(new.user &- old.user) + Double(new.nice &- old.nice)
            let system = Double(new.system &- old.system)
            let idle = Double(new.idle &- old.idle)
            let total = user + system + idle
            perCore.append(total > 0 ? (user + system) / total * 100 : 0)
            userTotal += user
            systemTotal += system
            allTotal += total
        }
        snapshot.perCore = perCore
        if allTotal > 0 {
            snapshot.user = userTotal / allTotal * 100
            snapshot.system = systemTotal / allTotal * 100
        }
        return snapshot
    }

    private static func loadAverage() -> [Double] {
        var load = [Double](repeating: 0, count: 3)
        guard getloadavg(&load, 3) == 3 else { return [0, 0, 0] }
        return load
    }
}
