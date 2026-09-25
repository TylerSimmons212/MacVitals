import Foundation
import Darwin

enum MemoryPressure: String, Sendable {
    case normal, warning, critical

    var label: String { rawValue.capitalized }
}

struct MemorySnapshot: Sendable {
    var total: UInt64 = 0
    /// Anonymous memory owned by apps (Activity Monitor's "App Memory").
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    /// File-backed and purgeable pages the system can reclaim instantly.
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: MemoryPressure = .normal
    /// Memory held in the compressor before compression (what `compressed` would take uncompressed).
    var compressedOriginal: UInt64 = 0
    /// Bytes per second. Sustained swap/page-out activity is the real sign of "thrashing".
    var swapInRate: Double = 0
    var swapOutRate: Double = 0
    var pageOutRate: Double = 0

    /// How much the compressor is squeezing (e.g. 2.9 means 2.9 GB stored in 1 GB).
    var compressionRatio: Double? {
        compressed > 0 && compressedOriginal > compressed ? Double(compressedOriginal) / Double(compressed) : nil
    }

    var used: UInt64 { app + wired + compressed }

    var usedPercent: Double {
        total > 0 ? Double(used) / Double(total) * 100 : 0
    }

    static let zero = MemorySnapshot()
}

final class MemorySampler {
    private let pageSize = UInt64(getpagesize())
    private let total = ProcessInfo.processInfo.physicalMemory
    private var previousCounters: (swapIns: UInt64, swapOuts: UInt64, pageOuts: UInt64, time: UInt64)?

    func sample() -> MemorySnapshot {
        var snapshot = MemorySnapshot()
        snapshot.total = total

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let anonymous = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            snapshot.app = (anonymous > purgeable ? anonymous - purgeable : 0) * pageSize
            snapshot.wired = UInt64(stats.wire_count) * pageSize
            snapshot.compressed = UInt64(stats.compressor_page_count) * pageSize
            snapshot.cached = (UInt64(stats.external_page_count) + purgeable) * pageSize
            snapshot.free = UInt64(stats.free_count) * pageSize
            snapshot.compressedOriginal = UInt64(stats.total_uncompressed_pages_in_compressor) * pageSize

            let now = DispatchTime.now().uptimeNanoseconds
            let counters = (swapIns: UInt64(stats.swapins), swapOuts: UInt64(stats.swapouts), pageOuts: UInt64(stats.pageouts))
            if let previous = previousCounters {
                let seconds = Double(now - previous.time) / 1_000_000_000
                if seconds > 0 {
                    func rate(_ new: UInt64, _ old: UInt64) -> Double {
                        new >= old ? Double((new - old) * pageSize) / seconds : 0
                    }
                    snapshot.swapInRate = rate(counters.swapIns, previous.swapIns)
                    snapshot.swapOutRate = rate(counters.swapOuts, previous.swapOuts)
                    snapshot.pageOutRate = rate(counters.pageOuts, previous.pageOuts)
                }
            }
            previousCounters = (counters.swapIns, counters.swapOuts, counters.pageOuts, now)
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            snapshot.swapUsed = swap.xsu_used
            snapshot.swapTotal = swap.xsu_total
        }

        switch Sysctl.int("kern.memorystatus_vm_pressure_level") {
        case 4: snapshot.pressure = .critical
        case 2: snapshot.pressure = .warning
        default: snapshot.pressure = .normal
        }
        return snapshot
    }
}
