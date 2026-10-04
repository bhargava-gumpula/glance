import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The on-device memory: one row per stored snapshot (app, window title, URL, OCR text, small thumbnail).
/// Never leaves the Mac by itself; `recent(since:)` feeds MemoryContext, which reaches ContextPacket only when the user asks.
final class Timeline: @unchecked Sendable {
    struct Snippet: Sendable, Equatable {
        let ts: Double
        let app: String
        let title: String?
        let url: String?
        let text: String
    }

    enum DBError: LocalizedError {
        case sqlite(String), noFTS5
        var errorDescription: String? {
            switch self {
            case .sqlite(let m): "Timeline database: \(m)"
            case .noFTS5: "This Mac's SQLite has no FTS5, so memory search is off."
            }
        }
    }

    static let schemaVersion = 1

    /// ~/Library/Application Support/Glance/timeline.sqlite (folder 0700, file 0600).
    static var defaultPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glance", isDirectory: true)
        var folder = dir
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Keep the memory (and its -wal/-shm files) out of Time Machine, so Forget and retention really delete it.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return folder.appendingPathComponent("timeline.sqlite").path
    }

    private var db: OpaquePointer?
    private let lock = NSLock() // ponytail: one lock for every call; the recorder writes once per 3 s at most

    init(path: String = Timeline.defaultPath) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw DBError.sqlite("can't open") }
        chmod(path, 0o600)
        guard sqlite3_compileoption_used("ENABLE_FTS5") == 1 else { throw DBError.noFTS5 }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA secure_delete=ON;")
        try migrate()
    }

    deinit { sqlite3_close(db) }

    /// Each step runs once, in order; `schema_version` records the last one applied.
    private func migrate() throws {
        try exec("CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL);"
                 + "INSERT INTO schema_version SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM schema_version);")
        let steps: [String] = [
            // 1: snapshots + external-content FTS5 kept in sync by triggers
            """
            CREATE TABLE snapshots(
              id INTEGER PRIMARY KEY, ts REAL NOT NULL, app TEXT NOT NULL, bundle_id TEXT,
              window_title TEXT, url TEXT, text TEXT NOT NULL, thumb BLOB);
            CREATE INDEX snapshots_ts ON snapshots(ts);
            CREATE VIRTUAL TABLE snapshots_fts USING fts5(text, window_title, url, content='snapshots', content_rowid='id');
            INSERT INTO snapshots_fts(snapshots_fts, rank) VALUES('secure-delete', 1);
            CREATE TRIGGER snap_ai AFTER INSERT ON snapshots BEGIN
              INSERT INTO snapshots_fts(rowid, text, window_title, url) VALUES (new.id, new.text, new.window_title, new.url);
            END;
            CREATE TRIGGER snap_ad AFTER DELETE ON snapshots BEGIN
              INSERT INTO snapshots_fts(snapshots_fts, rowid, text, window_title, url)
              VALUES ('delete', old.id, old.text, old.window_title, old.url);
            END;
            """,
        ]
        var version = try int("SELECT version FROM schema_version")
        for (i, sql) in steps.enumerated() where i + 1 > version {
            try exec("BEGIN; \(sql) UPDATE schema_version SET version = \(i + 1); COMMIT;")
            version = i + 1
        }
    }

    var version: Int { locked { (try? int("SELECT version FROM schema_version")) ?? 0 } }

    func insert(ts: Double = Date().timeIntervalSince1970, app: String, bundleID: String?, title: String?, url: String?,
                text: String, thumb: Data?) throws {
        try locked {
            let st = try prepare("INSERT INTO snapshots(ts,app,bundle_id,window_title,url,text,thumb) VALUES(?,?,?,?,?,?,?)")
            defer { sqlite3_finalize(st) }
            sqlite3_bind_double(st, 1, ts)
            for (i, s) in [app, bundleID, title, url, text].enumerated() { bind(st, Int32(i + 2), s) }
            if let thumb {
                _ = thumb.withUnsafeBytes { sqlite3_bind_blob(st, 7, $0.baseAddress, Int32(thumb.count), SQLITE_TRANSIENT) }
            }
            guard sqlite3_step(st) == SQLITE_DONE else { throw DBError.sqlite(errmsg) }
        }
    }

    /// "Forget last N min": rows, FTS entries (trigger) and thumbnails (same row) go together.
    func forget(since ts: Double) throws {
        try locked { try exec("DELETE FROM snapshots WHERE ts >= \(ts); PRAGMA wal_checkpoint(TRUNCATE);") }
    }

    /// Rolling deletion.
    func trim(olderThan ts: Double) throws {
        try locked {
            try exec("DELETE FROM snapshots WHERE ts < \(ts)")
            if sqlite3_changes(db) > 0 { try exec("PRAGMA wal_checkpoint(TRUNCATE)") }
        }
    }

    /// Every row since `ts`, newest first (retention keeps this small). For "Where was I?" and the recent-windows fallback.
    func recent(since ts: Double) throws -> [Snippet] {
        try locked {
            let st = try prepare("SELECT ts, app, window_title, url, text FROM snapshots WHERE ts >= ? ORDER BY ts DESC")
            defer { sqlite3_finalize(st) }
            sqlite3_bind_double(st, 1, ts)
            var out: [Snippet] = []
            while sqlite3_step(st) == SQLITE_ROW {
                func col(_ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
                out.append(Snippet(ts: sqlite3_column_double(st, 0), app: col(1) ?? "", title: col(2), url: col(3), text: col(4) ?? ""))
            }
            return out
        }
    }

    func count(matching query: String? = nil) throws -> Int {
        try locked {
            guard let query else { return try int("SELECT count(*) FROM snapshots") }
            let st = try prepare("SELECT count(*) FROM snapshots_fts WHERE snapshots_fts MATCH ?")
            defer { sqlite3_finalize(st) }
            bind(st, 1, query)
            return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int(st, 0)) : 0
        }
    }

    // MARK: SQLite plumbing

    private var errmsg: String { String(cString: sqlite3_errmsg(db)) }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            let m = errmsg
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw DBError.sqlite(m)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { throw DBError.sqlite(errmsg) }
        return st
    }

    private func bind(_ st: OpaquePointer?, _ i: Int32, _ s: String?) {
        if let s { sqlite3_bind_text(st, i, s, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(st, i) }
    }

    private func int(_ sql: String) throws -> Int {
        let st = try prepare(sql)
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int(st, 0)) : 0
    }
}
