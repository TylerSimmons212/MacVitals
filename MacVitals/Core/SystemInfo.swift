import Foundation
import Darwin

enum Sysctl {
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        if size == MemoryLayout<Int32>.size {
            return Int(Int32(truncatingIfNeeded: value))
        }
        return Int(value)
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func bootTime() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}

/// Static facts about this Mac, read once at launch.
struct SystemInfo: Sendable {
    let hostName: String
    let chip: String
    let modelIdentifier: String
    let osVersion: String
    let physicalMemory: UInt64
    let logicalCores: Int
    let performanceCores: Int?
    let efficiencyCores: Int?
    let bootTime: Date?

    var uptime: TimeInterval {
        if let bootTime { return Date().timeIntervalSince(bootTime) }
        return ProcessInfo.processInfo.systemUptime
    }

    var coreSummary: String {
        if let p = performanceCores, let e = efficiencyCores, e > 0 {
            return "\(p)P + \(e)E cores"
        }
        return "\(logicalCores) cores"
    }

    static func current() -> SystemInfo {
        let process = ProcessInfo.processInfo
        let v = process.operatingSystemVersion
        let version = v.patchVersion > 0
            ? "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
            : "macOS \(v.majorVersion).\(v.minorVersion)"
        return SystemInfo(
            hostName: Host.current().localizedName ?? process.hostName,
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "Unknown chip",
            modelIdentifier: Sysctl.string("hw.model") ?? "Mac",
            osVersion: version,
            physicalMemory: process.physicalMemory,
            logicalCores: process.activeProcessorCount,
            performanceCores: Sysctl.int("hw.perflevel0.logicalcpu"),
            efficiencyCores: Sysctl.int("hw.perflevel1.logicalcpu"),
            bootTime: Sysctl.bootTime()
        )
    }
}
