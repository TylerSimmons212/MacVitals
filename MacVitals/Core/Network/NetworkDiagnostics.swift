import Foundation
import CoreWLAN
import SystemConfiguration
import Darwin

// MARK: - Wi-Fi

struct WiFiInfo: Equatable, Sendable {
    let interface: String
    let rssi: Int          // dBm, e.g. -53
    let noise: Int         // dBm, e.g. -88
    let transmitRate: Double // Mbps
    let phyMode: Int       // CWPHYMode raw value
    let channel: Int?
    let band: Int?         // CWChannelBand raw value
    let width: Int?        // CWChannelWidth raw value

    var signalToNoise: Int { rssi - noise }

    /// "Wi-Fi 6 (802.11ax)"
    var standard: String {
        switch phyMode {
        case 1: "802.11a"
        case 2: "802.11b"
        case 3: "802.11g"
        case 4: "Wi-Fi 4 (802.11n)"
        case 5: "Wi-Fi 5 (802.11ac)"
        case 6: "Wi-Fi 6 (802.11ax)"
        case 7: "Wi-Fi 7 (802.11be)"
        default: "Wi-Fi"
        }
    }

    var bandName: String? {
        switch band {
        case 1: "2.4 GHz"
        case 2: "5 GHz"
        case 3: "6 GHz"
        default: nil
        }
    }

    var widthName: String? {
        switch width {
        case 1: "20 MHz"
        case 2: "40 MHz"
        case 3: "80 MHz"
        case 4: "160 MHz"
        default: nil
        }
    }

    /// Current Wi-Fi link, or nil if Wi-Fi is off / not connected. No permissions needed
    /// (only the network *name* requires Location access, which we don't ask for).
    static func current() -> WiFiInfo? {
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn(), iface.rssiValue() != 0 else { return nil }
        let channel = iface.wlanChannel()
        return WiFiInfo(
            interface: iface.interfaceName ?? "en0",
            rssi: iface.rssiValue(),
            noise: iface.noiseMeasurement(),
            transmitRate: iface.transmitRate(),
            phyMode: iface.activePHYMode().rawValue,
            channel: channel?.channelNumber,
            band: channel?.channelBand.rawValue,
            width: channel?.channelWidth.rawValue
        )
    }
}

// MARK: - Addresses, router, DNS, VPN

struct NetworkConfig: Equatable, Sendable {
    var primaryInterface: String?
    var router: String?
    var localIPv4: String?
    var dnsServers: [String] = []

    /// A VPN usually takes over the primary route with a tunnel interface.
    var isVPN: Bool {
        guard let primaryInterface else { return false }
        return primaryInterface.hasPrefix("utun") || primaryInterface.hasPrefix("ipsec") || primaryInterface.hasPrefix("ppp")
    }

    var isOnline: Bool { router != nil || primaryInterface != nil }

    static func current() -> NetworkConfig {
        var config = NetworkConfig()
        guard let store = SCDynamicStoreCreate(nil, "MacVitals" as CFString, nil, nil) else { return config }
        if let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            config.primaryInterface = ipv4["PrimaryInterface"] as? String
            config.router = ipv4["Router"] as? String
        }
        if let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] {
            config.dnsServers = dns["ServerAddresses"] as? [String] ?? []
        }
        if let primary = config.primaryInterface {
            config.localIPv4 = ipv4Address(of: primary)
        }
        return config
    }

    static func ipv4Address(of interface: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name) == interface,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            }
        }
        return nil
    }
}

// MARK: - Ping

struct PingResult: Equatable, Sendable {
    let averageMs: Double?
    let lossPercent: Double

    var reachable: Bool { lossPercent < 100 && averageMs != nil }

    /// Parses the summary lines of macOS `ping`.
    static func parse(_ output: String) -> PingResult {
        var loss = 100.0
        var average: Double?
        for line in output.split(separator: "\n") {
            if line.contains("packet loss"),
               let range = line.range(of: #"([\d.]+)% packet loss"#, options: .regularExpression) {
                loss = Double(line[range].split(separator: "%").first ?? "") ?? 100
            }
            if line.contains("round-trip"), let equals = line.split(separator: "=").last {
                let parts = equals.trimmingCharacters(in: .whitespaces).split(separator: "/")
                if parts.count >= 2 { average = Double(parts[1]) }
            }
        }
        return PingResult(averageMs: average, lossPercent: loss)
    }

    /// A few quick ICMP echoes. No data is sent beyond the echo packets themselves.
    static func run(host: String, count: Int = 4) async -> PingResult {
        await Task.detached(priority: .utility) {
            let output = (try? Shell.run("/sbin/ping", ["-c", "\(count)", "-i", "0.25", "-t", "3", "-q", host])) ?? ""
            return parse(output)
        }.value
    }
}

// MARK: - Per-process network usage (nettop)

enum NettopReader {
    struct Entry: Equatable, Sendable {
        let pid: pid_t
        let name: String
        let bytesIn: UInt64
        let bytesOut: UInt64
    }

    /// Parses `nettop -P -L 1 -x -n -J bytes_in,bytes_out` (lines like "Safari.1234,5120,880,").
    static func parse(_ output: String) -> [Entry] {
        output.split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."),
                  let pid = pid_t(fields[0][fields[0].index(after: dot)...]),
                  let bytesIn = UInt64(fields[1]), let bytesOut = UInt64(fields[2]) else { return nil }
            return Entry(pid: pid, name: String(fields[0][..<dot]), bytesIn: bytesIn, bytesOut: bytesOut)
        }
    }

    /// Cumulative bytes per process since each process started. `-n` skips DNS lookups (5s → 20ms).
    static func read() async -> [Entry] {
        await Task.detached(priority: .utility) {
            let output = (try? Shell.run("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"])) ?? ""
            return parse(output)
        }.value
    }
}

// MARK: - Speed test (Apple's networkQuality)

struct SpeedTestResult: Codable, Equatable, Sendable {
    let date: Date
    let downloadBitsPerSecond: Double
    let uploadBitsPerSecond: Double
    /// Round-trips per minute under load; higher is better.
    let responsivenessRPM: Double?
    let idleLatencyMs: Double?
    let bytesUsed: Int64

    var downloadMbps: Double { downloadBitsPerSecond / 1_000_000 }
    var uploadMbps: Double { uploadBitsPerSecond / 1_000_000 }

    static func parse(_ json: Data, date: Date = Date()) -> SpeedTestResult? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let down = (root["dl_throughput"] as? NSNumber)?.doubleValue,
              let up = (root["ul_throughput"] as? NSNumber)?.doubleValue else { return nil }
        let rpm = (root["responsiveness"] as? NSNumber)?.doubleValue ?? (root["dl_responsiveness"] as? NSNumber)?.doubleValue
        let used = ((root["dl_bytes_transferred"] as? NSNumber)?.int64Value ?? 0) + ((root["ul_bytes_transferred"] as? NSNumber)?.int64Value ?? 0)
        return SpeedTestResult(date: date, downloadBitsPerSecond: down, uploadBitsPerSecond: up,
                               responsivenessRPM: rpm, idleLatencyMs: (root["base_rtt"] as? NSNumber)?.doubleValue,
                               bytesUsed: used)
    }

    static func run() async -> SpeedTestResult? {
        await Task.detached(priority: .userInitiated) {
            guard let output = try? Shell.run("/usr/bin/networkQuality", ["-c"]) else { return nil }
            return parse(Data(output.utf8))
        }.value
    }

    private static let storageKey = "lastSpeedTest"

    static func loadLast() -> SpeedTestResult? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(SpeedTestResult.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }
}

// MARK: - Shell helper

enum Shell {
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
