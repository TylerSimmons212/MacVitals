import Foundation
import AppKit

/// A small, honest set of fixes that genuinely help on modern macOS. Each is listed by the
/// symptom it fixes, says what it does and what you'll notice, and only runs when you ask.
///
/// Deliberately *not* included (see `MaintenanceTask.leftOut`): "free up RAM", repairing
/// permissions, running maintenance scripts, and checking the startup disk.
struct MaintenanceTask: Identifiable, Sendable {
    enum ID: String, CaseIterable, Sendable {
        case restartFinder, restartDock, quickLook, openWith, dnsCache, spotlight, snapshots
    }

    let id: ID
    /// The symptom, in your words.
    let symptom: String
    /// What we'll do.
    let action: String
    let explanation: String
    /// What you'll notice while or after it runs.
    let sideEffect: String
    let icon: String
    let duration: String
    let needsPassword: Bool
    /// Needs a "are you sure" because it's disruptive.
    let confirm: String?
    /// Absolute paths only; run in order.
    let commands: [[String]]

    static let all: [MaintenanceTask] = [
        MaintenanceTask(
            id: .restartFinder, symptom: "Finder is frozen or not showing files",
            action: "Restart Finder",
            explanation: "Quits and reopens Finder, the same as Force Quit › Relaunch. Fixes stuck windows, missing files and a Desktop that won't update.",
            sideEffect: "Finder windows close and reopen. Nothing is lost.",
            icon: "macwindow", duration: "A few seconds", needsPassword: false, confirm: nil,
            commands: [["/usr/bin/killall", "Finder"]]),
        MaintenanceTask(
            id: .restartDock, symptom: "The Dock, Launchpad or Mission Control is stuck",
            action: "Restart the Dock",
            explanation: "Restarts the process behind the Dock, Launchpad, Mission Control and app switching.",
            sideEffect: "The Dock disappears for a second and comes back.",
            icon: "dock.rectangle", duration: "A few seconds", needsPassword: false, confirm: nil,
            commands: [["/usr/bin/killall", "Dock"]]),
        MaintenanceTask(
            id: .quickLook, symptom: "File previews and thumbnails are blank or wrong",
            action: "Rebuild Quick Look previews",
            explanation: "Clears the saved thumbnails and reloads the preview plug-ins, so Finder and Quick Look draw them fresh.",
            sideEffect: "Thumbnails redraw the next time you open a folder.",
            icon: "eye", duration: "A few seconds", needsPassword: false, confirm: nil,
            commands: [["/usr/bin/qlmanage", "-r", "cache"], ["/usr/bin/qlmanage", "-r"]]),
        MaintenanceTask(
            id: .openWith, symptom: "\"Open With\" lists duplicates or apps open in the wrong app",
            action: "Rebuild the app list",
            explanation: "Rebuilds macOS's list of apps and which files they open (Launch Services), removing duplicates and apps you've deleted.",
            sideEffect: "Your Mac is a little busy for about a minute. Default apps you chose may need choosing again.",
            icon: "list.bullet.rectangle", duration: "About a minute", needsPassword: false,
            confirm: "Default apps you've picked for some file types may reset and need choosing again.",
            commands: [["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                        "-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"]]),
        MaintenanceTask(
            id: .dnsCache, symptom: "Websites won't load after changing networks or DNS",
            action: "Clear the DNS cache",
            explanation: "Forgets the saved addresses of websites so your Mac looks them up again. Helps after switching networks, VPNs or DNS settings.",
            sideEffect: "Nothing you'll notice; the first visit to each site takes a moment longer.",
            icon: "network", duration: "A second", needsPassword: true, confirm: nil,
            commands: [["/usr/bin/dscacheutil", "-flushcache"], ["/usr/bin/killall", "-HUP", "mDNSResponder"]]),
        MaintenanceTask(
            id: .spotlight, symptom: "Spotlight can't find files you know are there",
            action: "Rebuild the Spotlight index",
            explanation: "Deletes Spotlight's index of your disk and builds it again from scratch.",
            sideEffect: "Search is incomplete and your Mac is busier (and warmer) for a few hours while it re-reads everything. Best done plugged in, before a break.",
            icon: "magnifyingglass", duration: "A few hours", needsPassword: true,
            confirm: "Your Mac will be busier for a few hours while Spotlight re-reads everything, and search results will be incomplete until it's done.",
            commands: [["/usr/bin/mdutil", "-E", "/System/Volumes/Data"]]),
        MaintenanceTask(
            id: .snapshots, symptom: "\"System Data\" is huge and space won't come back",
            action: "Remove local Time Machine snapshots",
            explanation: "Time Machine keeps hourly snapshots on your Mac between backups. macOS removes them when it needs space, but they can make storage look full.",
            sideEffect: "Your backups on the backup disk aren't touched. You lose the option to restore from the last few hours' local snapshots.",
            icon: "clock.arrow.circlepath", duration: "Under a minute", needsPassword: true,
            confirm: "Backups on your backup disk aren't affected, but you won't be able to restore from these local snapshots.",
            commands: [["/usr/bin/tmutil", "deletelocalsnapshots", "/"]]),
    ]

    struct LeftOut: Identifiable {
        let title: String
        let reason: String
        var id: String { title }
    }

    /// Things other cleaners offer that don't help, or can hurt, on modern macOS.
    static let leftOut: [LeftOut] = [
        LeftOut(title: "Free up RAM",
                reason: "macOS uses spare memory to keep apps fast, and frees it instantly when needed. Forcing it empty makes your Mac reload everything, which is slower."),
        LeftOut(title: "Repair disk permissions",
                reason: "Not needed since macOS 10.11. System Integrity Protection keeps system permissions correct, and Disk Utility dropped the option."),
        LeftOut(title: "Run maintenance scripts",
                reason: "macOS runs its own housekeeping on schedule. Running the old scripts by hand mostly rotates a few logs."),
        LeftOut(title: "Check the startup disk for errors",
                reason: "Checking the disk while you're using it can freeze your Mac until it finishes. Use Disk Utility › First Aid, or Recovery if something's wrong."),
    ]
}

/// Runs maintenance tasks. Password tasks go through one macOS prompt that names Mac Vitals.
enum MaintenanceRunner {
    enum Outcome: Equatable, Sendable {
        case done
        case cancelled
        case failed(String)
    }

    static func run(_ task: MaintenanceTask) async -> Outcome {
        if task.needsPassword {
            return await MainActor.run { runAsAdmin(task) }
        }
        return await Task.detached(priority: .userInitiated) {
            for command in task.commands {
                let (status, output) = execute(command)
                // killall reports "No matching processes" if it's not running: that's fine.
                if status != 0 && !output.contains("No matching processes") {
                    return .failed(output.split(separator: "\n").last.map(String.init) ?? "It didn't finish.")
                }
            }
            return .done
        }.value
    }

    /// The shell line for a password task (fixed commands only, every argument quoted).
    static func shellLine(_ task: MaintenanceTask) -> String {
        task.commands.map { $0.map(quote).joined(separator: " ") }.joined(separator: "; ")
    }

    static func quote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @MainActor
    private static func runAsAdmin(_ task: MaintenanceTask) -> Outcome {
        let prompt = "Mac Vitals needs your password to \(task.action.lowercased())."
        let script = "do shell script \(appleScriptString(shellLine(task))) with prompt \(appleScriptString(prompt)) with administrator privileges"
        var error: NSDictionary?
        _ = NSAppleScript(source: script)?.executeAndReturnError(&error)
        guard let error else { return .done }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        return .failed(error[NSAppleScript.errorMessage] as? String ?? "It didn't finish.")
    }

    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func execute(_ command: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: Status (read-only, cheap)

    /// Local Time Machine snapshots on the startup disk (`tmutil listlocalsnapshotdates /`).
    static func localSnapshots() -> [String] {
        let (_, output) = execute(["/usr/bin/tmutil", "listlocalsnapshotdates", "/"])
        return parseSnapshotDates(output)
    }

    static func parseSnapshotDates(_ output: String) -> [String] {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.firstMatch(of: /^\d{4}-\d{2}-\d{2}-\d{6}$/) != nil }
    }

    /// "2026-09-25-120000" → a readable date.
    static func snapshotDate(_ stamp: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.date(from: stamp)
    }
}
