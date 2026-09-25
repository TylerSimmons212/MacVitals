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
    let failures: [String]

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
        for item in items {
            guard !isProtected(item.path) else {
                failures.append(item.name)
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
            } catch {
                failures.append(item.name)
            }
        }
        return CleanupRecord(id: UUID(), date: Date(), entries: entries, failures: failures)
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
