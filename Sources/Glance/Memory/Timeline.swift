import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The on-device memory: one row per stored snapshot (app, window title, URL, OCR text, small thumbnail).
/// Never leaves the Mac by itself; `snippets(matching:)` feeds ContextPacket only when the user asks.
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
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("timeline.sqlite").path
    }

    private var db: OpaquePointer?
    private let lock = NSLock() // ponytail: one lock for every call; the recorder writes once per 3 s at most

    init(path: String = Timeline.defaultPath) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw DBError.sqlite("can't open") }
        chmod(path, 0o600)
        guard sqlite3_compileoption_used("ENABLE_FTS5") == 1 else { throw DBError.noFTS5 }
        try exec("PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON;")
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

    var version: Int { (try? int("SELECT version FROM schema_version")) ?? 0 }

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
        try locked { try exec("DELETE FROM snapshots WHERE ts < \(ts); PRAGMA wal_checkpoint(TRUNCATE);") }
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

    /// Newest snapshot per window that matches any of `terms`, best matches first. Only lines that contain a term
    /// are kept, up to `Config.memorySnippetChars` per window.
    func snippets(matching terms: [String], since ts: Double, limit: Int = Config.memorySnippetLimit) throws -> [Snippet] {
        guard let match = Timeline.ftsQuery(terms) else { return [] }
        return try locked {
            let st = try prepare("""
                SELECT s.ts, s.app, s.window_title, s.url, s.text FROM snapshots_fts f JOIN snapshots s ON s.id = f.rowid
                WHERE snapshots_fts MATCH ? AND s.ts >= ? ORDER BY f.rank LIMIT 50
                """)
            defer { sqlite3_finalize(st) }
            bind(st, 1, match)
            sqlite3_bind_double(st, 2, ts)
            var out: [Snippet] = [], seen = Set<String>()
            while sqlite3_step(st) == SQLITE_ROW, out.count < limit {
                func col(_ i: Int32) -> String? { sqlite3_column_text(st, i).map { String(cString: $0) } }
                let key = "\(col(1) ?? "")|\(col(2) ?? "")"
                guard seen.insert(key).inserted else { continue }
                out.append(Snippet(ts: sqlite3_column_double(st, 0), app: col(1) ?? "", title: col(2), url: col(3),
                                   text: Timeline.matchingLines(col(4) ?? "", terms: terms)))
            }
            return out.sorted { $0.ts < $1.ts }
        }
    }

    // MARK: Query helpers (pure, selftested)

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "your", "this", "that", "with", "what", "how", "why", "who",
        "from", "they", "them", "was", "were", "has", "have", "had", "its", "it's", "can", "does", "did", "will",
        "one", "ones", "these", "those", "than", "then", "there", "here", "about", "into", "which", "when", "where",
        "earlier", "before", "different", "difference", "between", "other", "same", "more", "less", "some", "any",
        "just", "also", "out", "all", "get", "use", "see", "show", "tell", "me", "my", "is", "of", "to", "in", "on",
        "a", "an", "or", "be", "do", "it", "as", "at", "by", "if", "so", "up", "we", "i",
    ]

    /// Lowercased search words from the question and the selection, minus stop words, at most 40.
    static func terms(from texts: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for text in texts {
            for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                let w = String(raw)
                guard w.count >= 2, !stopWords.contains(w), seen.insert(w).inserted else { continue }
                out.append(w)
                if out.count == 40 { return out }
            }
        }
        return out
    }

    /// `"a" OR "b"`; quoting keeps FTS5 syntax characters out of MATCH.
    static func ftsQuery(_ terms: [String]) -> String? {
        let q = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: " OR ")
        return q.isEmpty ? nil : q
    }

    static func matchingLines(_ text: String, terms: [String]) -> String {
        var out = ""
        for line in text.split(separator: "\n") {
            let words = Set(line.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            guard terms.contains(where: words.contains) else { continue }
            if out.count + line.count > Config.memorySnippetChars { break }
            out += line + "\n"
        }
        return out.trimmingCharacters(in: .newlines)
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
