import Foundation
import Darwin
import Observation

struct ListeningPort: Identifiable, Hashable, Sendable {
    let pid: pid_t
    let command: String
    let port: Int
    let addresses: [String]
    let workingDirectory: String?
    var arguments: [String] = []
    var startDate: Date?

    var id: String { "\(pid):\(port)" }

    var uptime: TimeInterval? { startDate.map { Date().timeIntervalSince($0) } }

    var tech: ServerInsights.Tech? {
        ServerInsights.tech(command: command, arguments: arguments, port: port)
    }

    var service: ServerInsights.Service? {
        isDevServer ? nil : ServerInsights.service(command: command, port: port)
    }

    /// Full command line for the technical view.
    var commandLine: String { arguments.isEmpty ? command : arguments.joined(separator: " ") }

    /// Bound only to loopback, so other devices on the network can't reach it.
    var isLocalOnly: Bool {
        addresses.allSatisfy { $0.hasPrefix("127.") || $0 == "[::1]" || $0 == "localhost" }
    }

    /// Project folder name when the process was started from inside the user's home folder.
    var projectName: String? {
        guard let workingDirectory else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard workingDirectory.hasPrefix(home + "/"), !workingDirectory.contains(".app/") else { return nil }
        return (workingDirectory as NSString).lastPathComponent
    }

    var isDevServer: Bool { projectName != nil }
}

enum PortScanner {
    struct RawEntry: Equatable {
        let pid: pid_t
        let command: String
        let address: String
        let port: Int
    }

    /// Parses `lsof -F pcn` output: lines prefixed p(pid), c(command), n(name "addr:port").
    static func parse(lsofOutput: String) -> [RawEntry] {
        var entries: [RawEntry] = []
        var pid: pid_t = 0
        var command = ""
        for line in lsofOutput.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = pid_t(value) ?? 0
                command = ""
            case "c":
                command = value
            case "n":
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                let address = String(value[..<colon])
                entries.append(RawEntry(pid: pid, command: command, address: address, port: port))
            default:
                continue
            }
        }
        return entries
    }

    static func scan() throws -> [ListeningPort] {
        let output = try run("/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"])
        let raw = parse(lsofOutput: output)

        var grouped: [String: (entry: RawEntry, addresses: [String])] = [:]
        var order: [String] = []
        for entry in raw {
            let key = "\(entry.pid):\(entry.port)"
            if grouped[key] == nil {
                grouped[key] = (entry, [])
                order.append(key)
            }
            if !(grouped[key]?.addresses.contains(entry.address) ?? true) {
                grouped[key]?.addresses.append(entry.address)
            }
        }

        var cwdCache: [pid_t: String?] = [:]
        return order.compactMap { key -> ListeningPort? in
            guard let (entry, addresses) = grouped[key] else { return nil }
            let cwd: String?
            if let cached = cwdCache[entry.pid] {
                cwd = cached
            } else {
                cwd = workingDirectory(of: entry.pid)
                cwdCache[entry.pid] = cwd
            }
            return ListeningPort(pid: entry.pid, command: entry.command, port: entry.port,
                                 addresses: addresses, workingDirectory: cwd,
                                 arguments: ProcessDetails.arguments(of: entry.pid) ?? [],
                                 startDate: ProcessDetails.startDate(of: entry.pid))
        }
        .sorted { ($0.isDevServer ? 0 : 1, $0.port) < ($1.isDevServer ? 0 : 1, $1.port) }
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty || path == "/" ? nil : path
    }

    private static func run(_ executable: String, arguments: [String]) throws -> String {
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

@MainActor
@Observable
final class PortsModel {
    private(set) var ports: [ListeningPort] = []
    private(set) var isLoading = false
    /// True once the first scan finishes. Views key "empty" and "loading" states off this, not
    /// `isLoading`, so the periodic background rescans don't make the page flicker.
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let scanned = try await Task.detached(priority: .utility) { try PortScanner.scan() }.value
            // Only publish real changes so unchanged rescans don't redraw anything.
            if scanned != ports { ports = scanned }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        hasLoaded = true
    }
}
