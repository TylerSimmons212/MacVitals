import Foundation

/// Something that starts automatically: an app that opens at login, a background helper
/// (launch agent), or a system service (launch daemon).
struct StartupItem: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable, CaseIterable {
        case loginItem, agent, daemon

        var title: String {
            switch self {
            case .loginItem: "Opens at login"
            case .agent: "Background helper"
            case .daemon: "System service"
            }
        }
    }

    /// launchd label or bundle ID (without BTM's numeric type prefix).
    let label: String
    let name: String
    let kind: Kind
    let developer: String?
    /// The app it belongs to, if any.
    let appName: String?
    let appPath: String?
    /// The launchd plist, for agents/daemons installed as files (the ones we can manage directly).
    let plistPath: String?
    let executablePath: String?
    /// Allowed to run (System Settings › Login Items › "Allow in the Background").
    var isEnabled: Bool
    let lastRun: Date?
    var isRunning = false
    var schedule: Schedule = .unknown

    var id: String { "\(kind.rawValue)|\(label)" }

    enum Schedule: Equatable, Sendable {
        case unknown, atLogin, alwaysRunning, every(TimeInterval), calendar, onDemand

        var text: String {
            switch self {
            case .unknown: "Starts automatically"
            case .atLogin: "Runs when you log in"
            case .alwaysRunning: "Always running (restarts if it quits)"
            case .every(let seconds): "Runs every \(StartupItem.describe(interval: seconds))"
            case .calendar: "Runs on a schedule"
            case .onDemand: "Runs when needed"
            }
        }
    }

    static func describe(interval seconds: TimeInterval) -> String {
        switch seconds {
        case ..<120: "\(Int(seconds)) seconds"
        case ..<7200: "\(Int(seconds / 60)) minutes"
        case ..<172_800: "\(Int(seconds / 3600)) hours"
        default: "\(Int(seconds / 86_400)) days"
        }
    }

    /// Its program no longer exists (typically the app was deleted but its helper stayed behind).
    var isBroken: Bool {
        guard let executablePath, executablePath.hasPrefix("/") else { return false }
        return !FileManager.default.fileExists(atPath: executablePath)
    }

    /// A plist in your own LaunchAgents folder: you can switch it off/on without admin rights.
    var isUserManageable: Bool {
        guard kind == .agent, let plistPath else { return false }
        return plistPath.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/Library/LaunchAgents/")
    }

    /// A plain explanation of what this probably is.
    var purpose: String {
        let haystack = [label, name, executablePath ?? ""].joined(separator: " ").lowercased()
        let owner = appName ?? developer ?? "an app"
        if isBroken {
            return "Its app is gone, so this can't do anything anymore. Safe to remove."
        }
        if label.hasPrefix("homebrew.mxcl.") {
            let service = label.replacingOccurrences(of: "homebrew.mxcl.", with: "")
            return "Homebrew service: \(service) runs in the background (started with `brew services`)."
        }
        if ["update", "keystone", "shipit", "sparkle"].contains(where: haystack.contains) {
            return "Keeps \(owner) up to date. Usually safe to turn off; most apps also check for updates when you open them."
        }
        if kind == .loginItem {
            return "Starts \(owner)'s menu bar item or helper when you log in."
        }
        if ["sync", "drive", "dropbox", "onedrive", "backup"].contains(where: haystack.contains) {
            return "Keeps \(owner) syncing in the background. Turning it off pauses syncing."
        }
        if kind == .daemon {
            return "A system-wide service installed by \(owner). Runs for every user, with extra privileges."
        }
        return "A background helper for \(owner)."
    }
}

// MARK: - Background Task Management (sfltool dumpbtm)

/// Parses `sfltool dumpbtm`, the same database System Settings › Login Items uses.
/// The format isn't documented, so parsing is defensive: unknown lines are ignored.
enum BTMParser {
    struct Record: Equatable, Sendable {
        var uid: Int?
        var fields: [String: String] = [:]

        var name: String? { fields["Name"].flatMap(clean) }
        var developer: String? { fields["Developer Name"].flatMap(clean) }
        var identifier: String? { fields["Identifier"] }
        var url: String? { fields["URL"].flatMap(clean) }
        var executable: String? { fields["Executable Path"].flatMap(clean) }
        var bundleID: String? { fields["Bundle Identifier"].flatMap(clean) }
        var parent: String? { fields["Parent Identifier"] }

        /// Numeric type flags from "Type: legacy agent (0x10008)".
        var typeFlags: Int? {
            guard let type = fields["Type"], let open = type.lastIndex(of: "("), let close = type.lastIndex(of: ")") else { return nil }
            let hex = type[type.index(after: open)..<close].replacingOccurrences(of: "0x", with: "")
            return Int(hex, radix: 16)
        }

        var kind: StartupItem.Kind? {
            guard let flags = typeFlags else { return nil }
            if flags & 0x4 != 0 { return .loginItem }
            if flags & 0x8 != 0 { return .agent }
            if flags & 0x10 != 0 { return .daemon }
            return nil
        }

        var isEnabled: Bool {
            guard let disposition = fields["Disposition"] else { return true }
            return disposition.contains("enabled") && !disposition.contains("disallowed")
        }

        var lastUse: Date? { fields["Last Use"].flatMap { BTMParser.dateFormatter.date(from: $0) } }

        /// "8.com.google.GoogleUpdater.wake" → "com.google.GoogleUpdater.wake"
        var label: String? {
            guard let identifier else { return nil }
            if let dot = identifier.firstIndex(of: "."), Int(identifier[..<dot]) != nil {
                return String(identifier[identifier.index(after: dot)...])
            }
            return identifier
        }

        private func clean(_ value: String) -> String? {
            value == "(null)" || value.isEmpty ? nil : value
        }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ssXXXXX"
        return f
    }()

    static func parse(_ text: String) -> [Record] {
        var records: [Record] = []
        var current: Record?
        var uid: Int?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID") {
                if let current { records.append(current) }
                current = nil
                let parts = line.split(separator: " ")
                uid = parts.count > 3 ? Int(parts[3]) : nil
                continue
            }
            if line.hasPrefix("#"), line.hasSuffix(":"), Int(line.dropFirst().dropLast()) != nil {
                if let current { records.append(current) }
                current = Record(uid: uid)
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // Keep the first value (nested "Embedded Item Identifiers" lines like "#1: x" are skipped above).
            if current?.fields[key] == nil { current?.fields[key] = value }
        }
        if let current { records.append(current) }
        return records
    }

    /// Reads the live database. Works without admin rights.
    static func read() -> [Record] {
        guard let output = try? Shell.run("/usr/bin/sfltool", ["dumpbtm"]), !output.isEmpty else { return [] }
        return parse(output)
    }
}

// MARK: - Inventory

enum StartupInventory {
    /// BTM writes home paths as /Users/<uid>/…; translate to the real home folder.
    static func resolveHome(_ path: String, uid: uid_t = getuid(), home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let prefix = "/Users/\(uid)/"
        return path.hasPrefix(prefix) ? home + "/" + path.dropFirst(prefix.count) : path
    }

    static func items(from records: [BTMRecordSource] = [.live], uid: uid_t = getuid(),
                      home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                      running: Set<String> = [], disabledLabels: Set<String> = []) -> [StartupItem] {
        let all = records.flatMap { $0.records() }
        // Only this user's items, plus system-wide ones (daemons live under root/-2).
        let relevant = all.filter { $0.uid == Int(uid) || $0.uid == 0 || $0.uid == -2 }
        var apps: [String: (name: String?, path: String?)] = [:]
        for record in relevant where record.typeFlags == 0x2 {
            if let identifier = record.identifier {
                apps[identifier] = (record.name, record.url.map { resolveHome($0, uid: uid, home: home) })
            }
        }

        var seen = Set<String>()
        var items: [StartupItem] = []
        for record in relevant {
            guard let kind = record.kind, let label = record.label, !seen.contains("\(kind)|\(label)") else { continue }
            seen.insert("\(kind)|\(label)")
            let parent = record.parent.flatMap { apps[$0] }
            let appPath = parent?.path
            // Embedded items (SMAppService) have paths relative to their app bundle.
            func absolute(_ path: String?) -> String? {
                guard let path else { return nil }
                if path.hasPrefix("/") { return resolveHome(path, uid: uid, home: home) }
                return appPath.map { ($0 as NSString).appendingPathComponent(path) }
            }
            let plist = record.url.flatMap { $0.hasSuffix(".plist") ? absolute($0) : nil }
            let executable = absolute(record.executable)
            var item = StartupItem(
                label: label,
                name: friendlyName(record.name ?? label, appName: parent?.name),
                kind: kind,
                developer: record.developer,
                appName: parent?.name ?? appNameFromPath(executable),
                appPath: appPath ?? executable.flatMap(ProcessGrouping.outermostAppBundle(in:)),
                plistPath: plist,
                executablePath: executable,
                isEnabled: record.isEnabled && !disabledLabels.contains(label),
                lastRun: record.lastUse
            )
            item.isRunning = running.contains(label)
            item.schedule = plist.map(schedule(ofPlistAt:)) ?? (kind == .loginItem ? .atLogin : .unknown)
            items.append(item)
        }
        return items
    }

    enum BTMRecordSource: Sendable {
        case live
        case parsed([BTMParser.Record])

        func records() -> [BTMParser.Record] {
            switch self {
            case .live: BTMParser.read()
            case .parsed(let records): records
            }
        }
    }

    /// "com.google.GoogleUpdater.wake" as a name isn't friendly; prefer the owning app's name.
    /// Names that say nothing about what they belong to.
    static let genericHelperNames: Set<String> = ["LaunchAgent", "LaunchDaemon", "Helper", "Launcher", "Agent", "LoginItem", "Login Item", "Updater"]

    static func friendlyName(_ name: String, appName: String?) -> String {
        let bare = (name as NSString).deletingPathExtension
        if genericHelperNames.contains(bare), let appName { return "\(appName) helper" }
        guard AppInventory.looksLikeBundleID(name) else { return bare }
        if let appName { return "\(appName) helper" }
        return AppInventory.prettyName(for: name)
    }

    static func appNameFromPath(_ path: String?) -> String? {
        guard let path, let bundle = ProcessGrouping.outermostAppBundle(in: path) else { return nil }
        return ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// How a launchd job runs, from its plist.
    static func schedule(ofPlistAt path: String) -> StartupItem.Schedule {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return .unknown }
        return schedule(of: plist)
    }

    static func schedule(of plist: [String: Any]) -> StartupItem.Schedule {
        if let keepAlive = plist["KeepAlive"] {
            if (keepAlive as? Bool) == true || keepAlive is [String: Any] { return .alwaysRunning }
        }
        if let interval = (plist["StartInterval"] as? NSNumber)?.doubleValue, interval > 0 { return .every(interval) }
        if plist["StartCalendarInterval"] != nil { return .calendar }
        if (plist["RunAtLoad"] as? Bool) == true { return .atLogin }
        if plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil || plist["MachServices"] != nil { return .onDemand }
        return .unknown
    }

    /// Labels launchd is currently running for this user (`launchctl list`: PID, status, label).
    static func runningLabels() -> Set<String> {
        guard let output = try? Shell.run("/bin/launchctl", ["list"]) else { return [] }
        return parseLaunchctlList(output)
    }

    static func parseLaunchctlList(_ output: String) -> Set<String> {
        Set(output.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: "\t")
            guard parts.count == 3, Int(parts[0]) != nil else { return nil } // "-" = not running
            return String(parts[2])
        })
    }

    /// Labels switched off with `launchctl disable` (Mac Vitals' own off switch uses this).
    static func disabledLabels(uid: uid_t = getuid()) -> Set<String> {
        guard let output = try? Shell.run("/bin/launchctl", ["print-disabled", "gui/\(uid)"]) else { return [] }
        return parseDisabled(output)
    }

    static func parseDisabled(_ output: String) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix("=> disabled") || trimmed.hasSuffix("=> true"),
                  let open = trimmed.firstIndex(of: "\""), let close = trimmed[trimmed.index(after: open)...].firstIndex(of: "\"") else { return nil }
            return String(trimmed[trimmed.index(after: open)..<close])
        })
    }

    static func scan() -> [StartupItem] {
        let running = runningLabels()
        let disabled = disabledLabels()
        var found = items(running: running, disabledLabels: disabled)
        // If the BTM format ever changes and we can't parse it, fall back to the launchd folders.
        if found.isEmpty { found = folderItems(running: running, disabledLabels: disabled) }
        return found.sorted { ($0.isBroken ? 0 : 1, $0.name.lowercased()) < ($1.isBroken ? 0 : 1, $1.name.lowercased()) }
    }

    /// Fallback: read launchd plists straight from the standard folders.
    static func folderItems(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                            running: Set<String>, disabledLabels: Set<String>) -> [StartupItem] {
        let folders: [(String, StartupItem.Kind)] = [
            (home + "/Library/LaunchAgents", .agent), ("/Library/LaunchAgents", .agent), ("/Library/LaunchDaemons", .daemon),
        ]
        var items: [StartupItem] = []
        for (folder, kind) in folders {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] where file.hasSuffix(".plist") {
                let path = folder + "/" + file
                guard let data = FileManager.default.contents(atPath: path),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                let label = plist["Label"] as? String ?? String(file.dropLast(6))
                let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
                var item = StartupItem(label: label, name: friendlyName(label, appName: appNameFromPath(program)), kind: kind,
                                       developer: nil, appName: appNameFromPath(program),
                                       appPath: program.flatMap(ProcessGrouping.outermostAppBundle(in:)),
                                       plistPath: path, executablePath: program,
                                       isEnabled: !disabledLabels.contains(label), lastRun: nil)
                item.isRunning = running.contains(label)
                item.schedule = schedule(of: plist)
                items.append(item)
            }
        }
        return items
    }
}

// MARK: - Switching helpers off and on

/// Turns a user launch agent off/on with launchctl: reversible, no admin rights needed.
/// Off = stop it now and don't start it again; On = allow it and start it.
enum LaunchctlController {
    static func turnOff(_ item: StartupItem, uid: uid_t = getuid()) -> Bool {
        guard item.isUserManageable else { return false }
        _ = try? Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)/\(item.label)"])
        _ = try? Shell.run("/bin/launchctl", ["disable", "gui/\(uid)/\(item.label)"])
        return StartupInventory.disabledLabels(uid: uid).contains(item.label)
    }

    static func turnOn(_ item: StartupItem, uid: uid_t = getuid()) -> Bool {
        guard item.isUserManageable, let plist = item.plistPath else { return false }
        _ = try? Shell.run("/bin/launchctl", ["enable", "gui/\(uid)/\(item.label)"])
        _ = try? Shell.run("/bin/launchctl", ["bootstrap", "gui/\(uid)", plist])
        return !StartupInventory.disabledLabels(uid: uid).contains(item.label)
    }
}
