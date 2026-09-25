import Foundation
import IOKit

struct DiskSnapshot: Sendable {
    var totalCapacity: Int64 = 0
    /// Space available for important usage (includes purgeable space macOS will free on demand).
    var availableCapacity: Int64 = 0
    /// Part of `availableCapacity` that macOS frees on demand (purgeable caches, local snapshots).
    var purgeableCapacity: Int64 = 0
    var readRate: Double = 0
    var writeRate: Double = 0
    var sessionRead: UInt64 = 0
    var sessionWritten: UInt64 = 0

    var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }

    var usedPercent: Double {
        totalCapacity > 0 ? Double(usedCapacity) / Double(totalCapacity) * 100 : 0
    }

    var freePercent: Double { totalCapacity > 0 ? 100 - usedPercent : 100 }

    static let zero = DiskSnapshot()
}

final class DiskSampler {
    private var previous: (read: UInt64, written: UInt64, time: UInt64)?
    private var baseline: (read: UInt64, written: UInt64)?
    private var capacity: (total: Int64, available: Int64, purgeable: Int64) = (0, 0, 0)
    private var capacityCheckedAt = Date.distantPast

    func sample() -> DiskSnapshot {
        var snapshot = DiskSnapshot()

        // Capacity queries can be slow (APFS computes purgeable space), so refresh them every 30s.
        if Date().timeIntervalSince(capacityCheckedAt) > 30 {
            capacity = Self.volumeCapacity()
            capacityCheckedAt = Date()
        }
        snapshot.totalCapacity = capacity.total
        snapshot.availableCapacity = capacity.available
        snapshot.purgeableCapacity = capacity.purgeable

        let (read, written) = Self.ioTotals()
        let now = DispatchTime.now().uptimeNanoseconds
        if baseline == nil { baseline = (read, written) }
        if let baseline {
            snapshot.sessionRead = read >= baseline.read ? read - baseline.read : 0
            snapshot.sessionWritten = written >= baseline.written ? written - baseline.written : 0
        }
        if let previous {
            let seconds = Double(now - previous.time) / 1_000_000_000
            if seconds > 0 {
                snapshot.readRate = read >= previous.read ? Double(read - previous.read) / seconds : 0
                snapshot.writeRate = written >= previous.written ? Double(written - previous.written) / seconds : 0
            }
        }
        previous = (read, written, now)
        return snapshot
    }

    static func volumeCapacity() -> (total: Int64, available: Int64, purgeable: Int64) {
        let url = FileManager.default.homeDirectoryForCurrentUser
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (0, 0, 0) }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let immediatelyFree = Int64(values.volumeAvailableCapacity ?? 0)
        let available = values.volumeAvailableCapacityForImportantUsage ?? immediatelyFree
        return (total, available, max(0, available - immediatelyFree))
    }

    /// Cumulative bytes read/written across all block storage drivers since boot.
    static func ioTotals() -> (read: UInt64, written: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var written: UInt64 = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                written += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (read, written)
    }
}
