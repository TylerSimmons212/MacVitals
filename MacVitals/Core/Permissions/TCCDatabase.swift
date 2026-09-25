import Foundation
import SQLite3

/// Read-only look at macOS's privacy database (TCC). There's no public API to ask "did the
/// user allow App Management?", but once Full Disk Access is on, the database itself is
/// readable, so we can show the real state instead of guessing. Never written to.
enum TCCDatabase {
    enum Lookup: Equatable {
        /// Can't read it (no Full Disk Access yet).
        case unreadable
        /// Readable, and there's no decision for us: never asked.
        case noEntry
        case allowed
        case denied
    }

    static let systemPath = "/Library/Application Support/com.apple.TCC/TCC.db"
    static var userPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/com.apple.TCC/TCC.db").path
    }

    /// `auth_value` 2 = allowed, 3 = limited (treated as allowed), 0 = denied.
    static func lookup(service: String, client: String = Bundle.main.bundleIdentifier ?? "", paths: [String]? = nil) -> Lookup {
        var readAny = false
        for path in paths ?? [systemPath, userPath] {
            guard let value = authValue(path: path, service: service, client: client) else { continue }
            readAny = true
            if let value { return value == 2 || value == 3 ? .allowed : .denied }
        }
        return readAny ? .noEntry : .unreadable
    }

    /// nil = couldn't open; .some(nil) = opened, no row.
    static func authValue(path: String, service: String, client: String) -> Int?? {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT auth_value FROM access WHERE service = ?1 AND client = ?2 LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, service, -1, transient)
        sqlite3_bind_text(statement, 2, client, -1, transient)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return .some(Int(sqlite3_column_int(statement, 0)))
        case SQLITE_DONE: return .some(nil)
        default: return nil // e.g. "authorization denied" surfaces here on some systems
        }
    }
}
