// RecordingsReader.swift — strictly read-only access to Apple's CloudRecordings.db.
//
// The live database is updated via WAL: opening it immutably returns 0 rows
// because current data lives in the multi-MB `-wal` sidecar. So we copy the DB
// plus its `-wal`/`-shm` companions to a temp directory and query the copy,
// never touching (or locking) Apple's files.

import Foundation
import SQLite3

public enum RecordingsReaderError: Error, CustomStringConvertible {
    case databaseMissing(String)
    case openFailed(String)
    case queryFailed(String)

    public var description: String {
        switch self {
        case .databaseMissing(let p): return "CloudRecordings.db not found at \(p) (Full Disk Access granted?)"
        case .openFailed(let m): return "failed to open database copy: \(m)"
        case .queryFailed(let m): return "query failed: \(m)"
        }
    }
}

public enum RecordingsReader {
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func copyBytes(from src: String, to dst: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: src))
        try data.write(to: URL(fileURLWithPath: dst))
    }

    /// Read all recordings from the DB at `recordingsDir`, ordered oldest-first.
    public static func readAll(recordingsDir: String) throws -> [Recording] {
        let dbPath = "\(recordingsDir)/CloudRecordings.db"
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw RecordingsReaderError.databaseMissing(dbPath)
        }

        let fm = FileManager.default
        let tempDir = NSTemporaryDirectory() + "vmingest-db-\(ProcessInfo.processInfo.globallyUniqueString)"
        try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tempDir) }

        // Copy the DB and its live WAL/SHM sidecars so the copy is consistent.
        //
        // Byte-read copy, NOT FileManager.copyItem: copyItem uses APFS
        // clonefile, and cloning fires an ItemCloned FSEvent on the *source*
        // files — which re-triggers the app's own recordings-dir watcher and
        // locks the pipeline into a permanent ~2s self-triggering loop
        // (verified live on macOS 26 with an independent FSEvents listener).
        // Plain reads generate no FS events.
        let tempDB = "\(tempDir)/CloudRecordings.db"
        for suffix in ["", "-wal", "-shm"] {
            let src = dbPath + suffix
            if fm.fileExists(atPath: src) {
                try copyBytes(from: src, to: tempDB + suffix)
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(tempDB, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw RecordingsReaderError.openFailed(msg)
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT ZUNIQUEID, ZDATE, ZDURATION, ZCUSTOMLABEL, ZPATH
        FROM ZCLOUDRECORDING
        WHERE ZUNIQUEID IS NOT NULL AND ZPATH IS NOT NULL
        ORDER BY ZDATE ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw RecordingsReaderError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        func text(_ col: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: c)
        }

        var results: [Recording] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = text(0), let path = text(4) else { continue }
            let zdate = sqlite3_column_double(stmt, 1)
            let duration = sqlite3_column_double(stmt, 2)
            let title = text(3) ?? ""
            results.append(Recording(
                id: id,
                recordedAt: dateFromCoreData(zdate),
                duration: duration,
                title: title,
                m4aPath: "\(recordingsDir)/\(path)"
            ))
        }
        return results
    }
}
