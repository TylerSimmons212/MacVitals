import Foundation

/// Moves protected items (installed for all users, owned by the system account) to the Trash
/// by asking Finder, exactly as if you'd dragged them there yourself: Finder shows macOS's own
/// password prompt, and the items land in your Trash (Finder's Put Back can restore them).
///
/// This is the no-helper alternative to a privileged daemon. Mac Vitals never sees the password.
enum FinderRemover {
    struct Result: Sendable {
        var entries: [CleanupRecord.Entry] = []
        var remaining: [FailedItem] = []
        /// You dismissed the password prompt.
        var cancelled = false
    }

    /// One Finder call for all items, so there's one password prompt.
    static let script = """
    on run argv
        set theItems to {}
        repeat with p in argv
            set end of theItems to ((POSIX file (p as text)) as alias)
        end repeat
        tell application "Finder" to set trashed to delete theItems
        if class of trashed is not list then set trashed to {trashed}
        set out to {}
        repeat with t in trashed
            set end of out to POSIX path of (t as alias)
        end repeat
        set AppleScript's text item delimiters to linefeed
        return out as text
    end run
    """

    static func trash(_ items: [FailedItem]) -> Result {
        guard !items.isEmpty else { return Result() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Paths go in as arguments (never spliced into the script), so no quoting issues.
        process.arguments = ["-e", script] + items.map(\.path)
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return Result(remaining: items)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        let trashedPaths = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }
        return match(items, trashedPaths: trashedPaths, cancelled: process.terminationStatus != 0 && errorText.contains("-128"))
    }

    /// Pairs Finder's answer with what we asked for. Finder returns items in order; if the
    /// counts differ we fall back to "is it gone from where it was?".
    static func match(_ items: [FailedItem], trashedPaths: [String], cancelled: Bool,
                      exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Result {
        var result = Result(cancelled: cancelled)
        let inOrder = trashedPaths.count == items.count
        for (index, item) in items.enumerated() {
            if exists(item.path) {
                result.remaining.append(item)
                continue
            }
            let name = (item.path as NSString).lastPathComponent
            let trashed = inOrder ? trashedPaths[index]
                : trashedPaths.first { ($0 as NSString).lastPathComponent == name }
                ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash/\(name)").path
            result.entries.append(.init(name: item.name, originalPath: item.path, trashedPath: trashed, size: item.size))
        }
        return result
    }
}
