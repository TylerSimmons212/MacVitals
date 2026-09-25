import Foundation

/// A record of one cleanup, so every cleanup can be reviewed and undone.
struct CleanupRecord: Codable, Identifiable, Sendable {
    struct Entry: Codable, Sendable, Hashable {
        let name: String
        let originalPath: String
        /// Where it landed in the Trash. nil = deleted permanently (e.g. emptied from the Trash).
        var trashedPath: String?
        let size: Int64
    }

    let id: UUID
    let date: Date
    var entries: [Entry]
    var failures: [String]
    /// What stopped each failure, so the result can offer the right fix. Optional for older history.
    var failedItems: [FailedItem]? = nil

    func failed(_ blocker: RemovalBlocker) -> [FailedItem] {
        (failedItems ?? []).filter { $0.blocker == blocker }
    }

    var movedToTrash: Int64 { entries.filter { $0.trashedPath != nil }.reduce(0) { $0 + $1.size } }
    var deletedPermanently: Int64 { entries.filter { $0.trashedPath == nil }.reduce(0) { $0 + $1.size } }
    var total: Int64 { entries.reduce(0) { $0 + $1.size } }

    /// Entries that are still in the Trash and can go back where they came from.
    var restorable: [Entry] {
        entries.filter { entry in
            guard let trashed = entry.trashedPath else { return false }
            return FileManager.default.fileExists(atPath: trashed) && !FileManager.default.fileExists(atPath: entry.originalPath)
        }
    }
}

/// Why an item couldn't be removed, in terms of what would fix it.
enum RemovalBlocker: String, Codable, Sendable {
    /// macOS asks before one app deletes another (Privacy & Security › App Management).
    case appManagement
    /// A privacy-protected location (Mail, containers…) and Full Disk Access is off.
    case fullDiskAccess
    /// Owned by the system / installed for all users: needs an admin password (via Finder).
    case admin
    /// In use, protected by macOS, or gone.
    case other
}

struct FailedItem: Codable, Sendable, Hashable {
    let name: String
    let path: String
    let size: Int64
    let blocker: RemovalBlocker

    var junkItem: JunkItem { JunkItem(path: path, name: name, detail: nil, size: size, tier: .review) }
}

/// The only code in Clean Up that removes anything. Every module goes through it, so the
/// safety rules live in one place:
/// - never touches macOS system locations
/// - moves to the Trash (reversible) unless told otherwise or the item is already in the Trash
/// - records exactly what happened so it can be put back
enum CleanupRemover {
    static let protectedPrefixes = ["/System", "/usr", "/bin", "/sbin", "/private/var/db", "/Library/Apple"]

    static func isProtected(_ path: String) -> Bool {
        protectedPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") } || path == "/" ||
            path == FileManager.default.homeDirectoryForCurrentUser.path
    }

    static func remove(_ items: [JunkItem], permanently: Bool, permanentIDs: Set<String> = []) -> CleanupRecord {
        let fm = FileManager.default
        var entries: [CleanupRecord.Entry] = []
        var failures: [String] = []
        var failedItems: [FailedItem] = []
        let hasFullDiskAccess = Permissions.checkFullDiskAccess()
        for item in items {
            guard !isProtected(item.path) else {
                failures.append(item.name)
                failedItems.append(FailedItem(name: item.name, path: item.path, size: item.size, blocker: .other))
                continue
            }
            do {
                if permanently || permanentIDs.contains(item.id) {
                    try fm.removeItem(at: item.url)
                    entries.append(.init(name: item.name, originalPath: item.path, trashedPath: nil, size: item.size))
                } else {
                    var resulting: NSURL?
                    try fm.trashItem(at: item.url, resultingItemURL: &resulting)
                    entries.append(.init(name: item.name, originalPath: item.path, trashedPath: resulting?.path, size: item.size))
                }
                if isInstalledApp(item.path) { Permissions.learnAppManagement(allowed: true) }
            } catch {
                let blocker = blocker(for: error, path: item.path, hasFullDiskAccess: hasFullDiskAccess)
                if blocker == .appManagement, isInstalledApp(item.path) { Permissions.learnAppManagement(allowed: false) }
                failures.append(item.name)
                failedItems.append(FailedItem(name: item.name, path: item.path, size: item.size, blocker: blocker))
            }
        }
        return CleanupRecord(id: UUID(), date: Date(), entries: entries, failures: failures, failedItems: failedItems)
    }

    static func isAppBundle(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".app")
    }

    /// An app in an Applications folder: the only removals that tell us about App Management.
    static func isInstalledApp(_ path: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return isAppBundle(path) && (path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/"))
    }

    /// EPERM ("Operation not permitted") is macOS privacy protection; EACCES ("Permission
    /// denied") is ordinary file ownership, e.g. something installed for all users.
    static func blocker(for error: Error, path: String, hasFullDiskAccess: Bool) -> RemovalBlocker {
        switch posixCode(of: error) {
        case EPERM:
            if isAppBundle(path) { return .appManagement }
            return hasFullDiskAccess ? .other : .fullDiskAccess
        case EACCES:
            return .admin
        case nil:
            // No POSIX detail: fall back to Cocoa's "no permission" and check ownership ourselves.
            if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSFileWriteNoPermissionError {
                return isAppBundle(path) && isWritableByUs(path) ? .appManagement : .admin
            }
            return .other
        default:
            return .other // in use, busy, gone…
        }
    }

    /// Walks the underlying-error chain for the POSIX code.
    static func posixCode(of error: Error) -> Int32? {
        var queue: [NSError] = [error as NSError]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current.domain == NSPOSIXErrorDomain { return Int32(current.code) }
            queue.append(contentsOf: current.underlyingErrors as [NSError])
        }
        return nil
    }

    /// Ordinary Unix permissions would allow it (so a refusal is macOS privacy, not ownership).
    static func isWritableByUs(_ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        return FileManager.default.isWritableFile(atPath: parent) && FileManager.default.isWritableFile(atPath: path)
    }

    /// Moves everything still in the Trash back to where it was. Returns how many came back.
    static func putBack(_ record: CleanupRecord) -> Int {
        let fm = FileManager.default
        var restored = 0
        for entry in record.restorable {
            guard let trashed = entry.trashedPath else { continue }
            let destination = URL(fileURLWithPath: entry.originalPath)
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: URL(fileURLWithPath: trashed), to: destination)
                restored += 1
            } catch {
                continue
            }
        }
        return restored
    }

    /// Permanently deletes only what this cleanup put in the Trash (not the rest of your Trash),
    /// so the space is actually freed. Returns the updated record.
    static func finalize(_ record: CleanupRecord) -> CleanupRecord {
        var updated = record
        for index in updated.entries.indices {
            guard let trashed = updated.entries[index].trashedPath,
                  FileManager.default.fileExists(atPath: trashed),
                  (try? FileManager.default.removeItem(atPath: trashed)) != nil else { continue }
            updated.entries[index].trashedPath = nil
        }
        return updated
    }
}

/// Keeps the last cleanups on disk (Application Support/MacVitals/cleanup-history.json).
enum CleanupHistoryStore {
    static let limit = 25

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MacVitals/cleanup-history.json")
    }

    static func load(from url: URL = fileURL) -> [CleanupRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CleanupRecord].self, from: data)) ?? []
    }

    static func save(_ records: [CleanupRecord], to url: URL = fileURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(records.prefix(limit))) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
