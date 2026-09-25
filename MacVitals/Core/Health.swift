import Foundation

enum ThermalLevel: String, Sendable {
    case nominal, fair, serious, critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    var label: String {
        switch self {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Hot"
        case .critical: "Critical"
        }
    }
}

struct HealthIssue: Identifiable, Equatable, Sendable {
    enum Severity: Int, Comparable, Sendable {
        case info = 0, warning = 1, critical = 2
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    let id: String
    let severity: Severity
    let title: String
    let detail: String
    let penalty: Int
    let section: DashboardSection
    /// Compact label for tight spaces like the menu bar panel. Written to fit on one line.
    var shortTitle: String = ""
    /// The one number that says how bad it is ("12 GB left", "92% avg").
    var metric: String = ""

    var compactTitle: String { shortTitle.isEmpty ? title : shortTitle }
}

/// One row of the "vital signs" checklist: every factor that feeds the score, healthy or not.
struct HealthCheck: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let value: String
    /// Nil means the factor is healthy.
    let severity: HealthIssue.Severity?
    let section: DashboardSection
}

struct HealthReport: Equatable, Sendable {
    let score: Int
    let issues: [HealthIssue]
    var checks: [HealthCheck] = []

    var grade: String {
        switch score {
        case 90...: "Excellent"
        case 75..<90: "Good"
        case 55..<75: "Fair"
        default: "Needs attention"
        }
    }

    static let pending = HealthReport(score: 100, issues: [])
}

struct HealthInputs: Sendable {
    var cpuAverage: Double          // recent average, 0...100
    var memory: MemorySnapshot
    var disk: DiskSnapshot
    var battery: BatterySnapshot?
    var thermal: ThermalLevel
    var uptime: TimeInterval
}

/// Turns raw vitals into a 0–100 score plus plain-English issues.
/// Each rule deducts points; the worst offenders surface first.
enum HealthEvaluator {
    static func evaluate(_ input: HealthInputs) -> HealthReport {
        var issues: [HealthIssue] = []

        // Storage
        if input.disk.totalCapacity > 0 {
            let free = input.disk.freePercent
            let freeText = Fmt.bytes(input.disk.availableCapacity)
            if free < 5 {
                issues.append(.init(id: "disk", severity: .critical, title: "Startup disk almost full",
                                    detail: "Only \(freeText) free. macOS slows down and updates can fail below 5%.",
                                    penalty: 30, section: .cleanup,
                                shortTitle: "Disk almost full", metric: "\(freeText) left"))
            } else if free < 10 {
                issues.append(.init(id: "disk", severity: .warning, title: "Startup disk running low",
                                    detail: "\(freeText) free. Run a cleanup to reclaim space.",
                                    penalty: 18, section: .cleanup,
                                shortTitle: "Disk space low", metric: "\(freeText) left"))
            } else if free < 15 {
                issues.append(.init(id: "disk", severity: .info, title: "Disk space getting tight",
                                    detail: "\(freeText) free (\(Fmt.percent(free)) of disk).",
                                    penalty: 8, section: .cleanup,
                                shortTitle: "Disk getting full", metric: "\(freeText) left"))
            }
        }

        // Memory
        switch input.memory.pressure {
        case .critical:
            issues.append(.init(id: "memory", severity: .critical, title: "Memory pressure is critical",
                                detail: "Your Mac is out of RAM and swapping heavily. Quit memory-hungry apps.",
                                penalty: 25, section: .memory,
                                shortTitle: "Out of memory", metric: "Critical"))
        case .warning:
            issues.append(.init(id: "memory", severity: .warning, title: "Memory pressure is elevated",
                                detail: "Apps are competing for RAM. Check the biggest memory users.",
                                penalty: 12, section: .memory,
                                shortTitle: "Memory pressure high", metric: "Elevated"))
        case .normal:
            break
        }
        let gib: UInt64 = 1 << 30
        if input.memory.total > 0, input.memory.swapUsed > input.memory.total / 2 {
            issues.append(.init(id: "swap", severity: .warning, title: "Heavy swap usage",
                                detail: "\(Fmt.memory(input.memory.swapUsed)) swapped to disk. This wears the SSD and slows things down.",
                                penalty: 10, section: .memory,
                                shortTitle: "Heavy swap use", metric: Fmt.memory(input.memory.swapUsed)))
        } else if input.memory.swapUsed > 2 * gib {
            issues.append(.init(id: "swap", severity: .info, title: "Swap in use",
                                detail: "\(Fmt.memory(input.memory.swapUsed)) swapped to disk.",
                                penalty: 4, section: .memory,
                                shortTitle: "Using swap", metric: Fmt.memory(input.memory.swapUsed)))
        }

        // CPU
        if input.cpuAverage > 85 {
            issues.append(.init(id: "cpu", severity: .warning, title: "CPU is maxed out",
                                detail: "Averaging \(Fmt.percent(input.cpuAverage)) over the last minute.",
                                penalty: 15, section: .cpu,
                                shortTitle: "CPU maxed out", metric: "\(Fmt.percent(input.cpuAverage)) avg"))
        } else if input.cpuAverage > 60 {
            issues.append(.init(id: "cpu", severity: .info, title: "CPU is busy",
                                detail: "Averaging \(Fmt.percent(input.cpuAverage)) over the last minute.",
                                penalty: 6, section: .cpu,
                                shortTitle: "CPU busy", metric: "\(Fmt.percent(input.cpuAverage)) avg"))
        }

        // Thermals
        switch input.thermal {
        case .critical:
            issues.append(.init(id: "thermal", severity: .critical, title: "Mac is overheating",
                                detail: "macOS is heavily throttling performance to cool down.",
                                penalty: 25, section: .cpu,
                                shortTitle: "Overheating", metric: "Throttled"))
        case .serious:
            issues.append(.init(id: "thermal", severity: .warning, title: "Mac is running hot",
                                detail: "Performance is being throttled.",
                                penalty: 15, section: .cpu,
                                shortTitle: "Running hot", metric: "Throttling"))
        case .fair:
            issues.append(.init(id: "thermal", severity: .info, title: "Mac is warm",
                                detail: "Thermals are elevated but not throttling yet.",
                                penalty: 4, section: .cpu,
                                shortTitle: "Running warm", metric: "Warm"))
        case .nominal:
            break
        }

        // Battery
        if let battery = input.battery {
            if let health = battery.healthPercent, health < 80 {
                issues.append(.init(id: "battery", severity: .warning, title: "Battery health is degraded",
                                    detail: "Holding \(Fmt.percent(health)) of its original capacity. Consider a service.",
                                    penalty: 10, section: .battery,
                                shortTitle: "Battery worn", metric: "\(Fmt.percent(health)) capacity"))
            } else if let cycles = battery.cycleCount, cycles > 1000 {
                issues.append(.init(id: "battery", severity: .info, title: "High battery cycle count",
                                    detail: "\(cycles) cycles. Apple rates most Mac batteries for 1,000.",
                                    penalty: 5, section: .battery,
                                shortTitle: "High cycle count", metric: "\(cycles) cycles"))
            }
        }

        // Uptime
        let days = input.uptime / 86_400
        if days > 14 {
            issues.append(.init(id: "uptime", severity: .info, title: "Restart recommended",
                                detail: "Up for \(Int(days)) days. A restart clears leaked memory and applies pending updates.",
                                penalty: 5, section: .overview,
                                shortTitle: "Restart recommended", metric: "\(Int(days)) days up"))
        }

        let penalty = issues.reduce(0) { $0 + $1.penalty }
        let sorted = issues.sorted { $0.severity == $1.severity ? $0.penalty > $1.penalty : $0.severity > $1.severity }
        return HealthReport(score: max(0, 100 - penalty), issues: sorted, checks: checks(for: input, issues: issues))
    }

    private static func checks(for input: HealthInputs, issues: [HealthIssue]) -> [HealthCheck] {
        func severity(_ ids: String...) -> HealthIssue.Severity? {
            issues.filter { ids.contains($0.id) }.map(\.severity).max()
        }
        var checks: [HealthCheck] = [
            HealthCheck(id: "disk", label: "Storage",
                        value: input.disk.totalCapacity > 0 ? "\(Fmt.percent(input.disk.freePercent)) free" : "—",
                        severity: severity("disk"), section: .disk),
            HealthCheck(id: "memory", label: "Memory",
                        value: input.memory.swapUsed > 0 && severity("swap") != nil
                            ? "\(input.memory.pressure.label) · \(Fmt.memory(input.memory.swapUsed)) swap"
                            : "\(input.memory.pressure.label) pressure",
                        severity: severity("memory", "swap"), section: .memory),
            HealthCheck(id: "cpu", label: "CPU",
                        value: "\(Fmt.percent(input.cpuAverage)) avg",
                        severity: severity("cpu"), section: .cpu),
            HealthCheck(id: "thermal", label: "Thermals",
                        value: input.thermal.label,
                        severity: severity("thermal"), section: .cpu),
        ]
        if let battery = input.battery {
            checks.append(HealthCheck(id: "battery", label: "Battery",
                                      value: battery.healthPercent.map { "\(Fmt.percent($0)) capacity" } ?? battery.statusText,
                                      severity: severity("battery"), section: .battery))
        }
        checks.append(HealthCheck(id: "uptime", label: "Uptime",
                                  value: Fmt.duration(input.uptime),
                                  severity: severity("uptime"), section: .overview))
        return checks
    }
}
