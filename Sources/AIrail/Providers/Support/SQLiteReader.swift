import Foundation
import SQLite3

/// Read-only lookups in a SQLite database another app owns (Cursor keeps its
/// sign-in in a VS Code-style key/value store).
enum SQLiteReader {
    /// Value of `key` in the `ItemTable(key, value)` layout VS Code-derived apps use.
    static func itemTableValue(databasePath: String, key: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw ConnectionError.unreadable("database not found")
        }
        do {
            return try query(databasePath: databasePath, key: key)
        } catch {
            // A live WAL database can refuse a second reader; a private copy always opens.
            let copy = try snapshotCopy(of: databasePath)
            defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
            return try query(databasePath: copy.path, key: key)
        }
    }

    private static func query(databasePath: String, key: String) throws -> String? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(databasePath, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw ConnectionError.unreadable(message)
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ConnectionError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, key, -1, transient)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        case SQLITE_DONE:
            return nil
        default:
            throw ConnectionError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func snapshotCopy(of databasePath: String) throws -> URL {
        let source = URL(fileURLWithPath: databasePath)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("airail-sqlite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: databasePath + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try? FileManager.default.copyItem(
                    at: sidecar,
                    to: directory.appendingPathComponent(source.lastPathComponent + suffix)
                )
            }
        }
        return destination
    }
}
