@testable import AgTermCore
import XCTest

final class ConversationSearchTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("conv-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ lines: [String], to path: String) throws -> URL {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func parse(_ agent: AccountProvider, _ lines: [String]) -> ConversationRecord {
        var record = ConversationRecord(agent: agent, id: "aaaaaaaa-1111", path: "/x", account: nil, modified: Date(), size: 0)
        for line in lines { ConversationParser.absorb(Data(line.utf8), into: &record) }
        return record
    }

    private func text(_ record: ConversationRecord) -> [String] {
        String(decoding: record.text, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    static let claudeLines = [
        #"{"type":"permission-mode","permissionMode":"default"}"#,
        #"{"type":"user","cwd":"/Users/me/app","message":{"role":"user","content":"<system-reminder>ignore me</system-reminder>"}}"#,
        #"{"type":"user","cwd":"/Users/me/app","message":{"role":"user","content":"Fix the   login\nredirect loop"}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"Found it in auth.ts."}]}}"#,
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#,
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"secret tool output"}]}}"#,
        #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"subagent prompt"}}"#,
        #"{"type":"user","isMeta":true,"message":{"role":"user","content":"meta caveat"}}"#,
        #"{"type":"ai-title","aiTitle":"Fix login redirect"}"#,
    ]

    func testClaudeKeepsPromptsAndRepliesOnly() {
        let record = parse(.claude, Self.claudeLines)
        XCTAssertEqual(text(record), ["Fix the login redirect loop", "Found it in auth.ts."])
        XCTAssertEqual(record.folder, "/Users/me/app")
        XCTAssertEqual(record.title, "Fix login redirect")
        XCTAssertEqual(record.firstPrompt, "Fix the   login")
        XCTAssertEqual(record.displayTitle, "Fix login redirect")
    }

    func testCodexSkipsInjectedContext() {
        let record = parse(.codex, [
            #"{"type":"session_meta","payload":{"id":"019c3bd4-ba78-7590-b14a-ce5e0570e04a","cwd":"/Users/me/api"}}"#,
            ##"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for /x"},{"type":"input_text","text":"<environment_context><cwd>/x</cwd></environment_context>"}]}}"##,
            #"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"dev rules"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add rate limiting"}]}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","output":"tool noise"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done: 100 req/min."}]}}"#,
        ])
        XCTAssertEqual(record.id, "019c3bd4-ba78-7590-b14a-ce5e0570e04a")
        XCTAssertEqual(record.folder, "/Users/me/api")
        XCTAssertEqual(text(record), ["Add rate limiting", "Done: 100 req/min."])
        XCTAssertEqual(record.firstPrompt, "Add rate limiting")
        XCTAssertEqual(ConversationParser.codexThreadNames(#"{"id":"a","thread_name":"Old"}"# + "\n" + #"{"id":"a","thread_name":"New"}"#),
                       ["a": "New"])
    }

    func testGrokReadsUserQueries() {
        let record = parse(.grok, [
            #"{"type":"system","content":"You are Grok"}"#,
            #"{"type":"user","content":[{"type":"text","text":"<user_info>\nOS: macos\n</user_info>"}]}"#,
            #"{"type":"user","content":[{"type":"text","text":"<user_query>\nlook at the flint thread\n</user_query>"}]}"#,
            #"{"type":"reasoning","summary":[{"type":"summary_text","text":"thinking"}]}"#,
            #"{"type":"assistant","content":"Reading the thread now.","tool_calls":[]}"#,
            #"{"type":"tool_result","content":"tool output"}"#,
        ])
        XCTAssertEqual(text(record), ["look at the flint thread", "Reading the thread now."])
        XCTAssertEqual(record.firstPrompt, "look at the flint thread")
        let summary = ConversationParser.grokSummary(Data(#"{"info":{"id":"9e15f9e2-4237","cwd":"/Users/me"},"session_summary":"Reply to Selim"}"#.utf8))
        XCTAssertEqual(summary.id, "9e15f9e2-4237")
        XCTAssertEqual(summary.folder, "/Users/me")
        XCTAssertEqual(summary.title, "Reply to Selim")
    }

    func testSearchMatchesEveryWordIgnoringCase() {
        let record = parse(.claude, Self.claudeLines)
        XCTAssertNotNil(ConversationSearch.match(record, ConversationSearch.terms("LOGIN auth")))
        XCTAssertNil(ConversationSearch.match(record, ConversationSearch.terms("login billing")))
        // The folder and title count too, with no snippet when only they match.
        XCTAssertEqual(ConversationSearch.match(record, ConversationSearch.terms("app"))?.snippet, "")
        XCTAssertEqual(ConversationSearch.match(record, ConversationSearch.terms("redirect"))?.snippet, "Fix the login redirect loop")
        // Tool output isn't searched.
        XCTAssertNil(ConversationSearch.match(record, ConversationSearch.terms("secret")))
    }

    func testSnippetCutsOnCharacterBoundaries() {
        let text = Data((String(repeating: "é", count: 80) + " needle " + String(repeating: "ü", count: 200) + "\nnext").utf8)
        let offset = text.range(of: Data("needle".utf8))!.lowerBound
        let snippet = ConversationSearch.snippet(text, at: offset, length: 6)
        XCTAssertTrue(snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertTrue(snippet.contains("needle"))
        XCTAssertFalse(snippet.contains("\u{FFFD}"))
        XCTAssertFalse(snippet.contains("next"))
    }

    func testRunStreamsNewestFirstAndStops() {
        let records = (0..<10).map { n -> ConversationRecord in
            var record = ConversationRecord(agent: .claude, id: "id-\(n)-xxxxxx", path: "/\(n)", account: nil,
                                            modified: Date(timeIntervalSince1970: Double(100 - n)), size: 0)
            record.append(n % 2 == 0 ? "even match" : "odd")
            return record
        }
        var batches: [[String]] = []
        ConversationSearch.run("MATCH", in: records, limit: 4, batch: 3) { batches.append($0.map(\.record.path)) }
        XCTAssertEqual(batches, [["/0", "/2", "/4"], ["/6"]])
        var none = 0
        ConversationSearch.run("", in: records, isCancelled: { true }) { none += $0.count }
        XCTAssertEqual(none, 0)
    }

    func testIndexReadsEveryAgentAndOnlyNewLines() throws {
        let claude = try write(Self.claudeLines, to: "claude/projects/-Users-me-app/11111111-2222-3333-4444-555555555555.jsonl")
        _ = try write([#"{"type":"user","message":{"content":"subagent"}}"#],
                      to: "claude/projects/-Users-me-app/11111111-2222-3333-4444-555555555555/subagents/a.jsonl")
        _ = try write([
            #"{"type":"session_meta","payload":{"id":"019c3bd4-ba78-7590-b14a-ce5e0570e04a","cwd":"/Users/me/api"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add rate limiting"}]}}"#,
        ], to: "codex/sessions/2026/11/07/rollout-2026-11-07T14-47-17-019c3bd4-ba78-7590-b14a-ce5e0570e04a.jsonl")
        let titles = try write([#"{"id":"019c3bd4-ba78-7590-b14a-ce5e0570e04a","thread_name":"Rate limits"}"#], to: "codex/session_index.jsonl")
        _ = try write([#"{"type":"user","content":[{"type":"text","text":"<user_query>grok question</user_query>"}]}"#],
                      to: "grok/sessions/%2FUsers%2Fme/9e15f9e2-4237-48b4/chat_history.jsonl")
        let roots = [
            ConversationRoot(agent: .claude, url: dir.appendingPathComponent("claude/projects"), account: nil),
            // A login linked to the same folder is read once.
            ConversationRoot(agent: .claude, url: dir.appendingPathComponent("claude/projects"), account: "acct"),
            ConversationRoot(agent: .codex, url: dir.appendingPathComponent("codex/sessions"), account: "work"),
            ConversationRoot(agent: .grok, url: dir.appendingPathComponent("grok/sessions"), account: nil),
        ]
        let cache = dir.appendingPathComponent("cache.plist")
        let index = ConversationIndex(cacheURL: cache)
        index.refresh(roots: roots, codexTitles: [titles])
        XCTAssertEqual(index.records.count, 3)
        let byAgent = Dictionary(index.records.map { ($0.agent, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byAgent[.claude]?.id, "11111111-2222-3333-4444-555555555555")
        XCTAssertNil(byAgent[.claude]?.account)
        XCTAssertEqual(byAgent[.codex]?.title, "Rate limits")
        XCTAssertEqual(byAgent[.codex]?.account, "work")
        XCTAssertEqual(byAgent[.grok]?.folder, "/Users/me")
        XCTAssertEqual(byAgent[.grok]?.id, "9e15f9e2-4237-48b4")

        // Appending reads only the new line, from where the last read stopped (a half-written
        // line waits until it's finished).
        let handle = try FileHandle(forWritingTo: claude)
        handle.seekToEndOfFile()
        handle.write(Data((#"{"type":"user","message":{"content":"second prompt about caching"}}"# + "\n" + #"{"type":"user","mess"#).utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: claude.path)
        let reopened = ConversationIndex(cacheURL: cache)
        reopened.refresh(roots: roots, codexTitles: [titles])
        let updated = try XCTUnwrap(reopened.records.first { $0.agent == .claude })
        XCTAssertEqual(text(updated), ["Fix the login redirect loop", "Found it in auth.ts.", "second prompt about caching"])
        XCTAssertLessThan(updated.parsed, updated.size)
        XCTAssertEqual(reopened.records.first?.agent, .claude, "newest first")
    }

    func testResumeCommands() {
        var record = ConversationRecord(agent: .claude, id: "11111111-2222", path: "/x", account: nil, modified: Date(), size: 0)
        XCTAssertEqual(ConversationResume.command(record), "command claude --resume 11111111-2222")
        record.account = "work login"
        XCTAssertEqual(ConversationResume.command(record), #"AGTERM_ACCOUNT=work\ login command claude --resume 11111111-2222"#)
        record.account = nil
        record.agent = .codex
        XCTAssertEqual(ConversationResume.command(record), "command codex resume 11111111-2222")
        record.agent = .grok
        XCTAssertEqual(ConversationResume.command(record), "command grok --resume 11111111-2222")
        record.id = "bad; rm -rf"
        XCTAssertNil(ConversationResume.command(record))
    }
}
