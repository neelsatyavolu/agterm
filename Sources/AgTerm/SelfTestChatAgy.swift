#if DEBUG
import AgTermCore
import Foundation
import SQLite3

/// An Antigravity conversation for the Chat self-test: a SQLite file shaped like agy 1.5's
/// (`steps` rows with protobuf payloads; see `AgyTimeline`), with two turns of reads, a
/// search, an edit, commands that pass and fail, a denied command and a markdown reply.
enum AgyFixture {
    enum Field {
        case int(Int, Int)
        case text(Int, String)
        case message(Int, [Field])
    }

    static func encode(_ fields: [Field]) -> Data {
        var out = Data()
        func varint(_ value: Int) {
            var v = UInt64(value)
            while v >= 0x80 { out.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
            out.append(UInt8(v))
        }
        for field in fields {
            switch field {
            case .int(let number, let value): varint(number << 3); varint(value)
            case .text(let number, let text):
                varint(number << 3 | 2); varint(text.utf8.count); out.append(Data(text.utf8))
            case .message(let number, let inner):
                let bytes = encode(inner)
                varint(number << 3 | 2); varint(bytes.count); out.append(bytes)
            }
        }
        return out
    }

    struct Row {
        let type: Int
        let status: Int
        let payload: Data
    }

    /// 2026-11-08 12:00:00 UTC, plus `second`.
    static func time(_ second: Int) -> [Field] { [.int(1, 1_794_139_200 + second), .int(2, 0)] }

    static func user(_ text: String, at second: Int) -> Row {
        Row(type: 14, status: 3, payload: encode([.int(1, 14), .message(5, [.message(1, time(second))]), .message(19, [.text(2, text)])]))
    }

    static func call(_ id: String, _ name: String, _ args: String) -> [Field] { [.text(1, id), .text(2, name), .text(3, args)] }

    static func reply(thinking: String? = nil, text: String? = nil, calls: [[Field]] = [], at second: Int, status: Int = 3) -> Row {
        var fields: [Field] = []
        if let thinking { fields.append(.text(3, thinking)) }
        if let text { fields += [.text(1, text), .text(8, text)] }
        fields += calls.map { .message(7, $0) }
        return Row(type: 15, status: status, payload: encode([.int(1, 15), .message(5, [.message(1, time(second))]), .message(20, fields)]))
    }

    static func run(_ call: [Field], output: String? = nil, exit: Int? = nil, error: String? = nil, at second: Int, took: Int = 1,
                    status: Int = 3) -> Row {
        var result: [Field] = []
        if let output { result.append(.text(1, "Created At: 2026-11-08T12:00:00Z\nCompleted At: 2026-11-08T12:00:01Z\n" + output)) }
        if let exit { result.append(.message(3, [.message(10, [.message(3, [.int(3, exit), .text(4, output ?? "")])])])) }
        var fields: [Field] = [.int(1, 132), .message(5, [.message(1, time(second)), .message(4, call), .message(8, time(second + took))]),
                               .message(140, [.message(2, result)])]
        if let error { fields.append(.message(31, [.text(2, error)])) }
        return Row(type: 132, status: status, payload: encode(fields))
    }

    static let read = call("c1", "view_file", #"{"AbsolutePath":"/w/proj/Sources/AgTerm/TabCardDrawing.swift","toolSummary":"View tab card"}"#)
    static let grep = call("c2", "grep_search", #"{"Query":"agentState","SearchPath":"/w/proj/Sources"}"#)
    static let edit = call("c3", "replace_file_content", #"{"TargetFile":"/w/proj/Sources/AgTerm/TabCardDrawing.swift","TargetContent":"let dot = Theme.idle","ReplacementContent":"let dot = waiting ? Theme.warn : Theme.idle","toolSummary":"Color the waiting dot"}"#)
    static let build = call("c4", "run_command", #"{"CommandLine":"swift build","Cwd":"/w/proj","toolSummary":"Build"}"#)
    static let test = call("c5", "run_command", #"{"CommandLine":"swift test --filter TabCard","Cwd":"/w/proj"}"#)
    static let push = call("c6", "run_command", #"{"CommandLine":"git push","Cwd":"/w/proj"}"#)

    static var rows: [Row] {
        [
            user("Why is the tab dot grey while the agent waits?", at: 0),
            reply(thinking: "The dot color is set in TabCardDrawing; check how it reads the agent's state.", calls: [read, grep], at: 2),
            run(read, output: "1: import AppKit\n2: let dot = Theme.idle", at: 3),
            run(grep, output: "Sources/AgTerm/TabCard.swift:14: var agentState", at: 3),
            reply(text: "It only knows idle and working. Adding the waiting state:", calls: [edit, build], at: 9),
            run(edit, output: "Edited TabCardDrawing.swift", at: 10),
            run(build, output: "error: cannot find 'waiting' in scope", exit: 1, at: 11, took: 6),
            reply(calls: [test], at: 20),
            run(test, output: "Executed 4 tests, with 0 failures", exit: 0, at: 21, took: 3),
            reply(text: ChatFixtures.markdown, at: 41),
            user("Push it", at: 60),
            reply(calls: [push], at: 61),
            run(push, error: "tool call denied by pre-tool hook: git push needs approval", at: 62, status: 7),
            reply(text: "The push was blocked by your hook. Run `git push` yourself, or allow it in `/permissions`.", at: 64),
        ]
    }

    /// Writes the conversation to `url`, replacing any earlier copy.
    static func write(to url: URL) {
        try? FileManager.default.removeItem(at: url)
        exec(url, """
            CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer NOT NULL DEFAULT 0, status integer NOT NULL DEFAULT 0,
              step_payload blob);
            CREATE TABLE trajectory_metadata_blob (id text DEFAULT "main", data blob, PRIMARY KEY (id));
            """)
        for (index, row) in rows.enumerated() { insert(url, index: index, row) }
    }

    /// Adds a step, or replaces the one at `index` (a running step finishing), as agy does.
    static func insert(_ url: URL, index: Int, _ row: Row) {
        withDatabase(url) { db in
            var statement: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO steps (idx, step_type, status, step_payload) VALUES (?, ?, ?, ?)", -1, &statement, nil)
            sqlite3_bind_int64(statement, 1, Int64(index))
            sqlite3_bind_int64(statement, 2, Int64(row.type))
            sqlite3_bind_int64(statement, 3, Int64(row.status))
            _ = row.payload.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(row.payload.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            sqlite3_step(statement)
            sqlite3_finalize(statement)
        }
    }

    private static func exec(_ url: URL, _ sql: String) {
        withDatabase(url) { sqlite3_exec($0, sql, nil, nil, nil) }
    }

    private static func withDatabase(_ url: URL, _ body: (OpaquePointer?) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { return }
        body(db)
        sqlite3_close(db)
    }
}
#endif
