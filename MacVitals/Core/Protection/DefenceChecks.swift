import Foundation

/// One of macOS's built-in protections, checked without admin rights and explained in plain words.
struct DefenceCheck: Identifiable, Equatable, Sendable {
    enum ID: String, CaseIterable, Sendable {
        case fileVault, gatekeeper, sip, securityUpdates, xprotect, macOSUpdates, firewall, screenLock, sharing, management
    }

    enum Status: Equatable, Sendable {
        /// Protected.
        case on
        /// Off, and it matters.
        case off
        /// Off, but only a recommendation (e.g. the firewall, which macOS ships off).
        case recommended
        /// Neither good nor bad: worth knowing (e.g. Remote Login is on).
        case info
        case checking
        case unknown

        var needsAttention: Bool { self == .off }
    }

    let id: ID
    let title: String
    let status: Status
    /// One plain sentence about the current state.
    let summary: String
    /// Why it matters, for people who want to know.
    let why: String
    var fixLabel: String? = nil
    var fixURL: URL? = nil
    /// Command and raw output, for "Under the hood".
    var technical: String? = nil

    /// Counts toward "defences on": the core protections, not the informational rows.
    var isCoreDefence: Bool {
        switch id {
        case .fileVault, .gatekeeper, .sip, .securityUpdates, .xprotect, .firewall: true
        case .macOSUpdates, .screenLock, .sharing, .management: false
        }
    }
}

enum SettingsLink {
    static func url(_ string: String) -> URL { URL(string: "x-apple.systempreferences:\(string)")! }
    static let fileVault = url("com.apple.preference.security?FileVault")
    static let privacySecurity = url("com.apple.preference.security?General")
    static let firewall = url("com.apple.Network-Settings.extension?Firewall")
    static let softwareUpdate = url("com.apple.Software-Update-Settings.extension")
    static let lockScreen = url("com.apple.Lock-Screen-Settings.extension")
    static let sharing = url("com.apple.Sharing-Settings.extension")
    static let deviceManagement = url("com.apple.Profiles-Settings.extension")
}

/// Reads each protection. Every reader is a thin shell call plus a pure parser (unit-tested).
enum DefenceChecks {
    /// Fast checks (well under a second together). macOS updates are separate: they hit the network.
    static func runFast(now: Date = Date()) -> [DefenceCheck] {
        [
            fileVault(output: run("/usr/bin/fdesetup", ["status"])),
            gatekeeper(output: run("/usr/sbin/spctl", ["--status"])),
            sip(output: run("/usr/bin/csrutil", ["status"])),
            securityUpdates(preferences: softwareUpdatePreferences()),
            xprotect(output: run("/usr/bin/xprotect", ["version"]), bundleVersion: xprotectBundleVersion(), now: now),
            firewall(global: run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]),
                     stealth: run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getstealthmode"])),
            screenLock(output: run("/usr/sbin/sysadminctl", ["-screenLock", "status"], includeErrors: true)),
            sharing(listeningPorts: listeningPorts()),
            management(enrollment: run("/usr/bin/profiles", ["status", "-type", "enrollment"]),
                       profiles: run("/usr/bin/profiles", ["list"])),
        ]
    }

    static let macOSUpdatesChecking = DefenceCheck(
        id: .macOSUpdates, title: "macOS is up to date", status: .checking,
        summary: "Checking Apple's servers for updates…",
        why: "Updates fix security holes that are already known to attackers. Installing them is the single most effective thing you can do.")

    /// Asks Apple's update servers. Takes a few seconds to a minute.
    static func macOSUpdates() -> DefenceCheck {
        macOSUpdates(output: run("/usr/sbin/softwareupdate", ["--list"], includeErrors: true))
    }

    // MARK: Parsers

    static func fileVault(output: String) -> DefenceCheck {
        let why = "FileVault encrypts everything on your disk. If your Mac is lost or stolen, nobody can read your files without your password."
        let technical = "$ fdesetup status\n\(output)"
        if output.contains("FileVault is On") {
            if output.localizedCaseInsensitiveContains("in progress") {
                return DefenceCheck(id: .fileVault, title: "Your files are encrypted", status: .on,
                                    summary: "FileVault is on and still encrypting your disk in the background.", why: why, technical: technical)
            }
            return DefenceCheck(id: .fileVault, title: "Your files are encrypted", status: .on,
                                summary: "FileVault is on. Your data is unreadable without your password.", why: why, technical: technical)
        }
        if output.contains("FileVault is Off") {
            return DefenceCheck(id: .fileVault, title: "Your files are encrypted", status: .off,
                                summary: "FileVault is off. Anyone with your Mac could read your files.", why: why,
                                fixLabel: "Turn On…", fixURL: SettingsLink.fileVault, technical: technical)
        }
        return DefenceCheck(id: .fileVault, title: "Your files are encrypted", status: .unknown,
                            summary: "Couldn't read FileVault's status.", why: why, fixLabel: "Open Settings", fixURL: SettingsLink.fileVault, technical: technical)
    }

    static func gatekeeper(output: String) -> DefenceCheck {
        let why = "Gatekeeper checks every app before it opens the first time and blocks apps that aren't from identified developers or that Apple knows are malicious."
        let technical = "$ spctl --status\n\(output)"
        if output.contains("assessments enabled") {
            return DefenceCheck(id: .gatekeeper, title: "Only trusted apps can open", status: .on,
                                summary: "Gatekeeper is on. New apps are checked before they open.", why: why, technical: technical)
        }
        if output.contains("assessments disabled") {
            return DefenceCheck(id: .gatekeeper, title: "Only trusted apps can open", status: .off,
                                summary: "Gatekeeper is off. Any app can open without being checked.", why: why,
                                fixLabel: "Open Settings", fixURL: SettingsLink.privacySecurity, technical: technical)
        }
        return DefenceCheck(id: .gatekeeper, title: "Only trusted apps can open", status: .unknown,
                            summary: "Couldn't read Gatekeeper's status.", why: why, technical: technical)
    }

    static func sip(output: String) -> DefenceCheck {
        let why = "System Integrity Protection stops anything, even apps with your password, from changing macOS itself. Malware that gets in can't dig into the system."
        let technical = "$ csrutil status\n\(output)"
        let lower = output.lowercased()
        if lower.contains("status: enabled") {
            return DefenceCheck(id: .sip, title: "macOS is protected from changes", status: .on,
                                summary: "System Integrity Protection is on.", why: why, technical: technical)
        }
        if lower.contains("status: disabled") || lower.contains("custom configuration") {
            return DefenceCheck(id: .sip, title: "macOS is protected from changes", status: .off,
                                summary: "System Integrity Protection is off. It can only be turned back on from Recovery: restart holding the power button, open Terminal and run csrutil enable.",
                                why: why, technical: technical)
        }
        return DefenceCheck(id: .sip, title: "macOS is protected from changes", status: .unknown,
                            summary: "Couldn't read System Integrity Protection's status.", why: why, technical: technical)
    }

    /// Missing keys mean macOS's defaults, which are on.
    static func securityUpdates(preferences: [String: Any]) -> DefenceCheck {
        let why = "Apple pushes urgent security fixes and new malware definitions quietly in the background. With this off, your Mac only gets them when you update manually."
        let critical = preferences["CriticalUpdateInstall"] as? Bool ?? true
        let configData = preferences["ConfigDataInstall"] as? Bool ?? true
        let technical = "/Library/Preferences/com.apple.SoftwareUpdate\nCriticalUpdateInstall = \(critical)\nConfigDataInstall = \(configData)"
        if critical && configData {
            return DefenceCheck(id: .securityUpdates, title: "Security fixes install automatically", status: .on,
                                summary: "Security responses and malware definitions install on their own.", why: why, technical: technical)
        }
        let missing = [critical ? nil : "security responses", configData ? nil : "malware definitions"].compactMap { $0 }
        return DefenceCheck(id: .securityUpdates, title: "Security fixes install automatically", status: .off,
                            summary: "Automatic \(missing.joined(separator: " and ")) \(missing.count == 1 ? "is" : "are") off.", why: why,
                            fixLabel: "Open Settings", fixURL: SettingsLink.softwareUpdate, technical: technical)
    }

    /// `xprotect version` → "Version: 5360 Installed: 2026-09-18 22:36:12 +0000".
    static func xprotect(output: String, bundleVersion: String?, now: Date) -> DefenceCheck {
        let why = "XProtect is the malware scanner built into macOS. It checks apps when they open and scans in the background, and Apple updates what it looks for every few weeks."
        let technical = "$ xprotect version\n\(output)"
        var version = bundleVersion
        var installed: Date?
        if let match = output.firstMatch(of: /Version:\s*(\S+)/) { version = String(match.1) }
        if let match = output.firstMatch(of: /Installed:\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4})/) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            installed = formatter.date(from: String(match.1))
        }
        guard let version else {
            return DefenceCheck(id: .xprotect, title: "Malware definitions are current", status: .unknown,
                                summary: "Couldn't read XProtect's version.", why: why, technical: technical)
        }
        guard let installed else {
            return DefenceCheck(id: .xprotect, title: "Malware definitions are current", status: .on,
                                summary: "XProtect version \(version) is installed.", why: why, technical: technical)
        }
        let days = Int(now.timeIntervalSince(installed) / 86_400)
        let age = days <= 0 ? "today" : days == 1 ? "yesterday" : "\(days) days ago"
        if days > 60 {
            return DefenceCheck(id: .xprotect, title: "Malware definitions are current", status: .off,
                                summary: "Last updated \(age). Apple usually updates them every few weeks, so automatic updates may be off.",
                                why: why, fixLabel: "Open Settings", fixURL: SettingsLink.softwareUpdate, technical: technical)
        }
        return DefenceCheck(id: .xprotect, title: "Malware definitions are current", status: .on,
                            summary: "Updated \(age) (version \(version)).", why: why, technical: technical)
    }

    static func firewall(global: String, stealth: String) -> DefenceCheck {
        let why = "The firewall blocks other devices from connecting to apps on your Mac. macOS ships with it off; it matters most on public Wi-Fi like cafés and airports."
        let technical = "$ socketfilterfw --getglobalstate\n\(global)\n$ socketfilterfw --getstealthmode\n\(stealth)"
        let stealthOn = stealth.localizedCaseInsensitiveContains("stealth mode is on") || stealth.localizedCaseInsensitiveContains("enabled")
        if global.contains("enabled") || global.contains("State = 1") || global.contains("State = 2") {
            return DefenceCheck(id: .firewall, title: "Firewall blocks incoming connections", status: .on,
                                summary: "The firewall is on\(stealthOn ? " in stealth mode (your Mac doesn't answer probes)" : "").",
                                why: why, technical: technical)
        }
        if global.contains("disabled") || global.contains("State = 0") {
            return DefenceCheck(id: .firewall, title: "Firewall blocks incoming connections", status: .recommended,
                                summary: "The firewall is off, which is macOS's default. Turning it on is a good idea if you use public Wi-Fi.",
                                why: why, fixLabel: "Turn On…", fixURL: SettingsLink.firewall, technical: technical)
        }
        return DefenceCheck(id: .firewall, title: "Firewall blocks incoming connections", status: .unknown,
                            summary: "Couldn't read the firewall's status.", why: why, technical: technical)
    }

    /// sysadminctl prints e.g. "screenLock delay is 60 seconds", "… is immediate", "screenLock is off".
    static func screenLock(output: String) -> DefenceCheck {
        let why = "When your Mac sleeps or the screensaver starts, it should ask for your password so nobody can walk up and use it."
        let technical = "$ sysadminctl -screenLock status\n\(output.split(separator: "\n").last.map(String.init) ?? output)"
        let lower = output.lowercased()
        if lower.contains("screenlock is off") {
            return DefenceCheck(id: .screenLock, title: "Asks for your password when you step away", status: .off,
                                summary: "Your Mac doesn't ask for a password after sleep or the screensaver.", why: why,
                                fixLabel: "Open Settings", fixURL: SettingsLink.lockScreen, technical: technical)
        }
        if lower.contains("immediate") {
            return DefenceCheck(id: .screenLock, title: "Asks for your password when you step away", status: .on,
                                summary: "Asks for your password right away after sleep or the screensaver.", why: why, technical: technical)
        }
        if let match = lower.firstMatch(of: /delay is (\d+) seconds/), let seconds = Int(match.1) {
            let text = seconds < 60 ? "\(seconds) seconds" : seconds < 3600 ? "\(seconds / 60) minute\(seconds / 60 == 1 ? "" : "s")" : "\(seconds / 3600) hour\(seconds / 3600 == 1 ? "" : "s")"
            return DefenceCheck(id: .screenLock, title: "Asks for your password when you step away",
                                status: seconds > 300 ? .recommended : .on,
                                summary: seconds > 300 ? "Asks for your password \(text) after sleep. Shorter is safer." : "Asks for your password \(text) after sleep or the screensaver.",
                                why: why, fixLabel: seconds > 300 ? "Open Settings" : nil, fixURL: seconds > 300 ? SettingsLink.lockScreen : nil, technical: technical)
        }
        return DefenceCheck(id: .screenLock, title: "Asks for your password when you step away", status: .unknown,
                            summary: "Couldn't read the screen lock setting.", why: why, fixLabel: "Open Settings", fixURL: SettingsLink.lockScreen, technical: technical)
    }

    /// Well-known ports macOS's sharing services listen on.
    static let sharingServices: [(port: Int, name: String)] = [
        (22, "Remote Login (SSH)"), (5900, "Screen Sharing"), (3283, "Remote Management"), (445, "File Sharing"), (548, "File Sharing (AFP)"),
    ]

    static func sharing(listeningPorts: Set<Int>) -> DefenceCheck {
        let why = "Sharing services let other computers connect to yours. They're safe when you use them, but each one is a door. Turn off the ones you don't use."
        var seen: [String] = []
        for service in sharingServices where listeningPorts.contains(service.port) && !seen.contains(service.name) {
            seen.append(service.name)
        }
        let technical = "Listening TCP ports checked: " + sharingServices.map { "\($0.port)" }.joined(separator: ", ") +
            "\nOpen: " + (sharingServices.filter { listeningPorts.contains($0.port) }.map { "\($0.port)" }.joined(separator: ", ").nilIfEmpty ?? "none")
        if seen.isEmpty {
            return DefenceCheck(id: .sharing, title: "Remote access and sharing", status: .on,
                                summary: "No sharing services are accepting connections.", why: why, technical: technical)
        }
        return DefenceCheck(id: .sharing, title: "Remote access and sharing", status: .info,
                            summary: "\(ListFormatter.localizedString(byJoining: seen)) \(seen.count == 1 ? "is" : "are") on. Fine if you use \(seen.count == 1 ? "it" : "them"); otherwise turn \(seen.count == 1 ? "it" : "them") off.",
                            why: why, fixLabel: "Open Sharing", fixURL: SettingsLink.sharing, technical: technical)
    }

    static func management(enrollment: String, profiles: String) -> DefenceCheck {
        let why = "An organization (work or school) can manage a Mac with device management and configuration profiles. Adware sometimes installs a profile to control your browser, so it's worth knowing what's there."
        let technical = "$ profiles status -type enrollment\n\(enrollment)\n$ profiles list\n\(profiles)"
        let enrolled = enrollment.contains("MDM enrollment: Yes")
        let noProfiles = profiles.localizedCaseInsensitiveContains("no configuration profiles") || profiles.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if enrolled {
            return DefenceCheck(id: .management, title: "Device management", status: .info,
                                summary: "Your Mac is managed by an organization. That's normal for a work or school Mac.",
                                why: why, fixLabel: "Review", fixURL: SettingsLink.deviceManagement, technical: technical)
        }
        if !noProfiles {
            return DefenceCheck(id: .management, title: "Device management", status: .off,
                                summary: "A configuration profile is installed, but your Mac isn't managed by an organization. If you didn't add it yourself, remove it.",
                                why: why, fixLabel: "Review", fixURL: SettingsLink.deviceManagement, technical: technical)
        }
        return DefenceCheck(id: .management, title: "Device management", status: .on,
                            summary: "Not managed by an organization, and no configuration profiles installed.", why: why, technical: technical)
    }

    /// `softwareupdate --list` lists "* Label: …" lines, or says "No new software available."
    static func macOSUpdates(output: String) -> DefenceCheck {
        let why = "Updates fix security holes that are already known to attackers. Installing them is the single most effective thing you can do."
        let technical = "$ softwareupdate --list\n\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        if output.contains("No new software available") {
            return DefenceCheck(id: .macOSUpdates, title: "macOS is up to date", status: .on,
                                summary: "No updates waiting.", why: why, technical: technical)
        }
        let titles = output.split(separator: "\n").compactMap { line -> String? in
            guard let match = line.firstMatch(of: /Title:\s*([^,]+)/) else { return nil }
            return String(match.1).trimmingCharacters(in: .whitespaces)
        }
        if !titles.isEmpty {
            let security = titles.contains { $0.localizedCaseInsensitiveContains("security") || $0.localizedCaseInsensitiveContains("macOS") }
            return DefenceCheck(id: .macOSUpdates, title: "macOS is up to date", status: security ? .off : .recommended,
                                summary: "\(titles.count == 1 ? "An update is" : "\(titles.count) updates are") waiting: \(ListFormatter.localizedString(byJoining: titles)).",
                                why: why, fixLabel: "Update…", fixURL: SettingsLink.softwareUpdate, technical: technical)
        }
        return DefenceCheck(id: .macOSUpdates, title: "macOS is up to date", status: .unknown,
                            summary: "Couldn't reach Apple's update servers. Check Software Update yourself.", why: why,
                            fixLabel: "Open Settings", fixURL: SettingsLink.softwareUpdate, technical: technical)
    }

    // MARK: Readers

    static func run(_ executable: String, _ arguments: [String], includeErrors: Bool = false) -> String {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Some tools (sysadminctl) answer via NSLog; with OS_ACTIVITY_DT_MODE set (Xcode, some
        // launch contexts) NSLog goes to the system log instead of stderr, and we'd read nothing.
        process.environment = ProcessInfo.processInfo.environment.filter { $0.key != "OS_ACTIVITY_DT_MODE" }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = includeErrors ? pipe : FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func softwareUpdatePreferences() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: "/Library/Preferences/com.apple.SoftwareUpdate.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [:] }
        return plist
    }

    static func xprotectBundleVersion() -> String? {
        let path = "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }

    /// TCP ports anything on this Mac is listening on (netstat sees every process, including
    /// launchd's on-demand sockets for sharing services, without admin rights).
    static func listeningPorts() -> Set<Int> {
        parseListeningPorts(run("/usr/sbin/netstat", ["-anv", "-p", "tcp"]))
    }

    static func parseListeningPorts(_ output: String) -> Set<Int> {
        var ports: Set<Int> = []
        for line in output.split(separator: "\n") where line.contains("LISTEN") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count > 3 else { continue }
            let local = columns[3]
            if let dot = local.lastIndex(of: "."), let port = Int(local[local.index(after: dot)...]) { ports.insert(port) }
        }
        return ports
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
