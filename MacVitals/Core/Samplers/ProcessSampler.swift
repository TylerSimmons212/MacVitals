import Foundation
import Darwin

struct ProcessUsage: Identifiable, Hashable, Sendable {
    let pid: pid_t
    let name: String
    let path: String
    /// Percent of one core (Activity Monitor convention: can exceed 100).
    var cpu: Double
    var memory: UInt64
    var diskReadRate: Double
    var diskWriteRate: Double
    /// Power this process is drawing, from macOS's own per-process energy accounting (watts).
    var watts: Double = 0

    var id: pid_t { pid }
}

enum AppKind: Sendable, Hashable {
    case application
    case system
    case process
}

/// One row in the "apps" view: every helper, renderer and XPC service rolled up under its owner.
struct AppUsage: Identifiable, Sendable {
    let id: String
    let name: String
    let bundlePath: String?
    let kind: AppKind
    var processes: [ProcessUsage]
    private(set) var cpu: Double = 0
    private(set) var memory: UInt64 = 0
    private(set) var diskReadRate: Double = 0
    private(set) var diskWriteRate: Double = 0
    private(set) var watts: Double = 0

    init(id: String, name: String, bundlePath: String?, kind: AppKind, processes: [ProcessUsage] = []) {
        self.id = id
        self.name = name
        self.bundlePath = bundlePath
        self.kind = kind
        self.processes = processes
        recomputeTotals()
    }

    var processCount: Int { processes.count }

    /// True for Mac Vitals itself. We show ourselves honestly in lists (labeled "This app"),
    /// but never blame ourselves in verdicts like "Mostly …".
    var isCurrentApp: Bool {
        let own = ProcessInfo.processInfo.processIdentifier
        return processes.contains { $0.pid == own }
    }
    var diskTotalRate: Double { diskReadRate + diskWriteRate }

    mutating func recomputeTotals() {
        cpu = processes.reduce(0) { $0 + $1.cpu }
        memory = processes.reduce(0) { $0 + $1.memory }
        diskReadRate = processes.reduce(0) { $0 + $1.diskReadRate }
        diskWriteRate = processes.reduce(0) { $0 + $1.diskWriteRate }
        watts = processes.reduce(0) { $0 + $1.watts }
    }
}

/// Pure rules for deciding which app a process belongs to. Kept separate so it's unit-testable.
enum ProcessGrouping {
    enum Group: Equatable {
        case application(bundlePath: String)
        case system
        case standalone
    }

    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/", "/Library/Apple/"]

    /// "/Applications/Google Chrome.app/Contents/Frameworks/.../Google Chrome Helper.app/..." → "/Applications/Google Chrome.app"
    static func outermostAppBundle(in path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var built = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            built += "/" + component
            if component.hasSuffix(".app") { return built }
        }
        return nil
    }

    static func isSystemPath(_ path: String) -> Bool {
        systemPrefixes.contains { path.hasPrefix($0) }
    }

    /// Bundles tucked inside support folders are helpers an app installed for itself
    /// (e.g. ~/Library/Application Support/Claude/claude-code/…/claude.app), not apps you installed.
    static let helperLocations = ["/Library/Application Support/", "/Library/Caches/", "/Library/PrivilegedHelperTools/"]

    static func isHelperBundle(_ bundlePath: String) -> Bool {
        helperLocations.contains { bundlePath.contains($0) }
    }

    /// 1. Inside a real .app bundle → that app.
    /// 2. Launched on behalf of an app (XPC services, WebKit renderers, terminal children) → the responsible app.
    /// 3. Started directly by an app, even one that "disclaimed" responsibility (e.g. Claude's
    ///    `disclaimer` helper) → the nearest ancestor app. Apps macOS launches normally have
    ///    launchd as their parent, so they're unaffected.
    /// 4. A helper bundle nobody owns (e.g. Microsoft AutoUpdate, started by launchd) → itself.
    /// 5. Apple system binary → "macOS".
    /// 6. Otherwise it stands alone (e.g. a Homebrew daemon).
    ///
    /// `ancestorPaths` is only evaluated when rules 1–2 don't settle it (walking parents costs syscalls).
    static func classify(path: String, responsiblePath: String?, ancestorPaths: () -> [String] = { [] }) -> Group {
        let ownApp = outermostAppBundle(in: path)
        if let ownApp, !isHelperBundle(ownApp) { return .application(bundlePath: ownApp) }
        if let responsiblePath, let app = outermostAppBundle(in: responsiblePath), !isHelperBundle(app) {
            return .application(bundlePath: app)
        }
        for ancestor in ancestorPaths() {
            if let app = outermostAppBundle(in: ancestor), !isHelperBundle(app) { return .application(bundlePath: app) }
        }
        if let ownApp { return .application(bundlePath: ownApp) }
        if isSystemPath(path) { return .system }
        return .standalone
    }
}

/// Samples every process the current user can inspect and rolls them up into apps.
/// Root-owned processes need a privileged helper (planned) and are skipped for now.
final class ProcessSampler {
    private struct Previous {
        let startTime: UInt64
        let cpuNanos: Double
        let bytesRead: UInt64
        let bytesWritten: UInt64
        let energyNanojoules: UInt64
    }

    private struct Identity {
        let groupKey: String
        let groupName: String
        let bundlePath: String?
        let kind: AppKind
        let processName: String
        let path: String
    }

    private var previous: [pid_t: Previous] = [:]
    private var identities: [pid_t: (startTime: UInt64, identity: Identity)] = [:]
    private var bundleNames: [String: String] = [:]
    private var lastSampleTime: UInt64 = 0
    /// rusage CPU times are Mach ticks (41.67ns each on Apple silicon, 1ns on Intel).
    private let ticksToNanos: Double
    private let responsiblePID: ((pid_t) -> pid_t)?

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksToNanos = timebase.denom == 0 ? 1 : Double(timebase.numer) / Double(timebase.denom)

        // Private libsystem SPI that Activity Monitor uses for "responsible" attribution.
        // Resolved dynamically so we degrade gracefully if it ever disappears.
        typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        if let symbol = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") {
            let fn = unsafeBitCast(symbol, to: ResponsibleFn.self)
            responsiblePID = { fn($0) }
        } else {
            responsiblePID = nil
        }
    }

    func sample() -> [AppUsage] {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = lastSampleTime == 0 ? 0 : Double(now - lastSampleTime)
        lastSampleTime = now

        var nextPrevious: [pid_t: Previous] = [:]
        var groups: [String: AppUsage] = [:]

        for pid in Self.allPIDs() {
            guard let usage = Self.resourceUsage(for: pid) else { continue }
            let startTime = usage.ri_proc_start_abstime
            let cpuNanos = Double(usage.ri_user_time &+ usage.ri_system_time) * ticksToNanos
            nextPrevious[pid] = Previous(
                startTime: startTime,
                cpuNanos: cpuNanos,
                bytesRead: usage.ri_diskio_bytesread,
                bytesWritten: usage.ri_diskio_byteswritten,
                energyNanojoules: usage.ri_energy_nj
            )

            var cpu = 0.0, readRate = 0.0, writeRate = 0.0, watts = 0.0
            if elapsed > 0, let old = previous[pid], old.startTime == startTime {
                cpu = max(0, (cpuNanos - old.cpuNanos) / elapsed * 100)
                let seconds = elapsed / 1_000_000_000
                if usage.ri_diskio_bytesread >= old.bytesRead {
                    readRate = Double(usage.ri_diskio_bytesread - old.bytesRead) / seconds
                }
                if usage.ri_diskio_byteswritten >= old.bytesWritten {
                    writeRate = Double(usage.ri_diskio_byteswritten - old.bytesWritten) / seconds
                }
                // nanojoules per nanosecond = watts
                if usage.ri_energy_nj >= old.energyNanojoules {
                    watts = Double(usage.ri_energy_nj - old.energyNanojoules) / elapsed
                }
            }

            let identity = identity(for: pid, startTime: startTime)
            let process = ProcessUsage(
                pid: pid,
                name: identity.processName,
                path: identity.path,
                cpu: cpu,
                memory: usage.ri_phys_footprint,
                diskReadRate: readRate,
                diskWriteRate: writeRate,
                watts: watts
            )
            groups[identity.groupKey, default: AppUsage(
                id: identity.groupKey,
                name: identity.groupName,
                bundlePath: identity.bundlePath,
                kind: identity.kind
            )].processes.append(process)
        }

        previous = nextPrevious
        identities = identities.filter { nextPrevious[$0.key] != nil }

        return groups.values
            .map { group -> AppUsage in
                var group = group
                group.recomputeTotals()
                return group
            }
            .sorted { $0.cpu == $1.cpu ? $0.memory > $1.memory : $0.cpu > $1.cpu }
    }

    // MARK: - Identity

    private func identity(for pid: pid_t, startTime: UInt64) -> Identity {
        if let cached = identities[pid], cached.startTime == startTime { return cached.identity }

        let path = Self.executablePath(for: pid)
        let processName = path.isEmpty ? (Self.shortName(for: pid) ?? "Process \(pid)") : (path as NSString).lastPathComponent

        var responsiblePath: String?
        if let responsiblePID {
            let owner = responsiblePID(pid)
            if owner > 0, owner != pid { responsiblePath = Self.executablePath(for: owner) }
        }

        let identity: Identity
        switch ProcessGrouping.classify(path: path, responsiblePath: responsiblePath,
                                        ancestorPaths: { Self.ancestorPaths(of: pid) }) {
        case .application(let bundlePath):
            identity = Identity(groupKey: bundlePath, groupName: displayName(forBundle: bundlePath),
                                bundlePath: bundlePath, kind: .application, processName: processName, path: path)
        case .system:
            identity = Identity(groupKey: "system", groupName: "macOS",
                                bundlePath: nil, kind: .system, processName: processName, path: path)
        case .standalone:
            identity = Identity(groupKey: "proc:" + (path.isEmpty ? processName : path), groupName: processName,
                                bundlePath: nil, kind: .process, processName: processName, path: path)
        }
        identities[pid] = (startTime, identity)
        return identity
    }

    private func displayName(forBundle path: String) -> String {
        if let cached = bundleNames[path] { return cached }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        bundleNames[path] = name
        return name
    }

    // MARK: - libproc

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    /// v6 adds `ri_energy_nj`: per-process energy, which powers "What's using your battery".
    static func resourceUsage(for pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return result == 0 ? info : nil
    }

    static func executablePath(for pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    /// Executable paths of the parent, grandparent… up to (not including) launchd.
    static func ancestorPaths(of pid: pid_t, maxDepth: Int = 8) -> [String] {
        var paths: [String] = []
        var current = pid
        for _ in 0..<maxDepth {
            guard let parent = parentPID(of: current), parent > 1 else { break }
            let path = executablePath(for: parent)
            if !path.isEmpty { paths.append(path) }
            current = parent
        }
        return paths
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func shortName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}
