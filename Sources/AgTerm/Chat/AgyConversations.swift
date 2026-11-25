import AgTermCore
import AgTermSessionKit
import Foundation
import SQLite3

/// Antigravity CLI (`agy`) conversations: one SQLite database per conversation in
/// `~/.gemini/antigravity-cli/conversations/<id>.db`, written as the agent works (WAL mode, so
/// the newest steps can sit in `<id>.db-wal`). Read-only; agy keeps writing while agterm reads.
enum AgyConversations {
    static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/antigravity-cli")
    }

    static var folder: URL { home.appendingPathComponent("conversations") }

    /// The conversation a running agy has open: it holds its database open for as long as it's on.
    static func open(group: pid_t) -> URL? {
        ProcInfo.openFiles(group: group) { $0.contains("/antigravity-cli/conversations/") && $0.hasSuffix(".db") }
            .first.map(URL.init(fileURLWithPath:))
    }

    /// The newest conversation started in `cwd` and written since `since`, for when the process
    /// can't be asked (it has no conversation open yet, or it's another user's).
    static func newest(cwd: String, since: Date, in folder: URL = folder) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let recent = files.filter { $0.pathExtension == "db" }.compactMap { url -> (URL, Date)? in
            let date = changed(url)
            return date >= since ? (url, date) : nil
        }
        let workspace = Data(("file://" + cwd).utf8)
        return recent.sorted { $0.1 > $1.1 }.first { url, _ in
            // The workspace is a `file://` URL in the conversation's metadata, followed by the next
            // field's key (a control byte, or 0x7A for field 15), not by more of a longer path.
            guard let blob = metadata(url), let range = blob.range(of: workspace) else { return false }
            return range.upperBound == blob.endIndex || blob[range.upperBound] < 0x20 || blob[range.upperBound] == 0x7A
        }?.0
    }

    /// When the conversation last changed: its database or its write-ahead log, whichever is newer.
    static func changed(_ url: URL) -> Date {
        [url, wal(url)].compactMap { attributes($0)?[.modificationDate] as? Date }.max() ?? .distantPast
    }

    /// Size and date of the database and its log, so an unchanged conversation isn't read again.
    /// Read fresh each time: `URL.resourceValues` caches per URL and would never see a change.
    static func stamp(_ url: URL) -> String {
        [url, wal(url)].map { file in
            let values = attributes(file)
            let date = (values?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\((values?[.size] as? NSNumber)?.int64Value ?? -1)@\(date)"
        }.joined(separator: "|")
    }

    private static func attributes(_ url: URL) -> [FileAttributeKey: Any]? {
        try? FileManager.default.attributesOfItem(atPath: url.path)
    }

    private static func wal(_ url: URL) -> URL { URL(fileURLWithPath: url.path + "-wal") }

    /// Steps from `index` on, oldest first; nil when the database can't be read.
    static func steps(_ url: URL, from index: Int = 0) -> [AgyStep]? {
        query(url, "SELECT idx, step_type, status, step_payload FROM steps WHERE idx >= ? ORDER BY idx", bind: index) { row in
            AgyStep(index: Int(sqlite3_column_int64(row, 0)), type: Int(sqlite3_column_int64(row, 1)),
                    status: Int(sqlite3_column_int64(row, 2)), payload: blob(row, 3))
        }
    }

    private static func metadata(_ url: URL) -> Data? {
        query(url, "SELECT data FROM trajectory_metadata_blob LIMIT 1") { blob($0, 0) }?.first
    }

    private static func blob(_ row: OpaquePointer?, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column)))
    }

    /// While agy runs, its log and shared-memory files exist and a read-only connection sees the
    /// newest steps. Once it quits they're gone, and SQLite can't open a WAL database read-only
    /// without them; the file no longer changes then, so it's opened as immutable.
    static func uri(_ url: URL) -> String {
        let path = url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path
        let live = FileManager.default.fileExists(atPath: wal(url).path) && FileManager.default.fileExists(atPath: url.path + "-shm")
        return "file:" + path + (live ? "?mode=ro" : "?immutable=1")
    }

    private static func query<T>(_ url: URL, _ sql: String, bind: Int? = nil, row make: (OpaquePointer?) -> T) -> [T]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(uri(url), &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        if let bind { sqlite3_bind_int64(statement, 1, Int64(bind)) }
        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW { rows.append(make(statement)); continue }
            return result == SQLITE_DONE ? rows : nil
        }
    }
}
