import XCTest
@testable import AgTermCore

/// Ported from agmux `src-tauri/src/remote/timeline.rs` `#[cfg(test)] mod tests`.
/// Tests that went through `agent_logs_to_entries` (agmux's DB log fallback,
/// which agterm has no equivalent of) are adapted to feed the same tool
/// payloads through a Claude transcript; expected values are unchanged.
final class RemoteTimelineTests: XCTestCase {
    let ts = "2026-07-13T12:00:00.000Z"

    func json(_ text: String) -> JSONValue {
        guard let value = JSONValue.parse(text) else {
            XCTFail("bad fixture \(text)")
            return .null
        }
        return value
    }

    /// One assistant `tool_use` line and the user `tool_result` line answering it.
    func toolTranscript(id: String, name: String, input: [String: Any], result: String, isError: Bool) -> String {
        let use = jsonLine(["type": "assistant", "uuid": "a-\(id)", "timestamp": ts,
                            "message": ["content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
        let res = jsonLine(["type": "user", "uuid": "u-\(id)", "timestamp": ts,
                            "message": ["content": [["type": "tool_result", "tool_use_id": id, "content": result, "is_error": isError]]]])
        return use + "\n" + res + "\n"
    }

    // MARK: Queue overlay

    func testClaudeQueueDequeueWithoutContentPopsOldest() {
        let log = [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-24T18:04:51.084Z","content":"cd site && git push"}"#,
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-24T18:04:55.000Z","content":"second"}"#,
            #"{"type":"queue-operation","operation":"dequeue","timestamp":"2026-09-24T18:05:45.022Z"}"#,
        ]
        let (delivered, pending) = ClaudeTimeline.scanQueue(log)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(pending.map(\.content), ["second"])
    }

    func testClaudeQueuePopAllReturnsMessageToInput() {
        let log = [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-24T18:04:51.084Z","content":"fix the tests"}"#,
            #"{"type":"queue-operation","operation":"popAll","timestamp":"2026-09-24T18:04:53.000Z","content":"fix the tests"}"#,
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-24T18:04:55.000Z","content":"fix the tests"}"#,
            #"{"type":"queue-operation","operation":"dequeue","timestamp":"2026-09-24T18:05:45.022Z"}"#,
        ]
        XCTAssertTrue(ClaudeTimeline.scanQueue(log).pending.isEmpty)
    }

    func testClaudeQueueRemoveMatchesContentAndKeepsUnrelated() {
        let log = [
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-24T17:57:26.010Z","content":"first"}"#,
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-09-24T17:57:27.000Z","content":"steer"}"#,
            #"{"type":"queue-operation","operation":"remove","timestamp":"2026-09-24T17:57:29.708Z","content":"steer","reason":"absorbed_mid_turn"}"#,
            #"{"type":"queue-operation","operation":"remove","timestamp":"2026-09-24T17:57:30.000Z","content":"never queued"}"#,
        ]
        XCTAssertEqual(ClaudeTimeline.scanQueue(log).pending.map(\.content), ["first"])
    }

    func testOverlayPromptMatchIgnoresWhitespaceAndSystemTags() {
        XCTAssertTrue(ClaudeText.overlayPromptsMatch("continue", "continue\n"))
        XCTAssertTrue(ClaudeText.overlayPromptsMatch("continue", "<system-reminder>x</system-reminder>continue"))
        XCTAssertFalse(ClaudeText.overlayPromptsMatch("continue", "yes"))
        XCTAssertFalse(ClaudeText.overlayPromptsMatch(nil, "continue"))
    }

    // MARK: Claude items

    func testClaudeCompactSummaryIsNotAUserTurn() {
        let items: [ClaudeChatItem] = [
            .userMessage(content: "real ask", timestamp: "2026-09-05T00:00:00.000Z", uuid: "u1"),
            .userMessage(content: "This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation.\n\nSummary:\n1. Primary Request",
                         timestamp: "2026-09-05T00:00:01.000Z", uuid: "compact-1"),
            .userMessage(content: "<system-reminder>skills dump</system-reminder>", timestamp: "2026-09-05T00:00:02.000Z", uuid: "sys-1"),
            .assistantText(text: "ok", timestamp: "2026-09-05T00:00:03.000Z", uuid: "a1"),
        ]
        let e = ClaudeTimeline.itemsToEntries(items)
        XCTAssertEqual(e.count, 2)
        XCTAssertEqual(e[0].kind, "user")
        XCTAssertEqual(e[0].text, "real ask")
        XCTAssertEqual(e[1].kind, "assistant")
        XCTAssertEqual(e[1].text, "ok")
    }

    func testClaudeAssistantTextKeepsMarkdownLayout() {
        let text = "Done.\n\n| Piece | State |\n|---|---|\n| cloud #2187 | merged |\n\n- item\n  - nested\n\n```sh\n  npm test\n```"
        let e = ClaudeTimeline.itemsToEntries([.assistantText(text: "\u{1b}[1m\(text)\u{1b}[0m\n", timestamp: "2026-09-05T00:00:03.000Z", uuid: "a1")])
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].text, text)
    }

    /// Adapted from `pty_fallback_strips_ansi_before_rendering`.
    func testANSIIsStrippedBeforeRendering() {
        let raw = "\u{1b}[?2026h\u{1b}[9;6H\u{1b}[38;2;108;108;108mBuilding project\u{1b}[0m"
        let e = ClaudeTimeline.itemsToEntries([.assistantText(text: raw, timestamp: ts, uuid: "l1")])
        XCTAssertEqual(e.count, 1)
        XCTAssertFalse(e[0].text!.contains("\u{1b}"))
        XCTAssertTrue(e[0].text!.contains("Building project"))
    }

    /// Adapted from `pty_fallback_drops_ansi_only_noise`.
    func testANSIOnlyNoiseIsDropped() {
        XCTAssertTrue(ClaudeTimeline.itemsToEntries([.assistantText(text: "\u{1b}[9;6H\u{1b}[0m", timestamp: ts, uuid: "l1")]).isEmpty)
    }

    // MARK: Tool rows through a Claude transcript

    /// Adapted from `failed_edit_shows_error_instead_of_unapplied_diff`.
    func testFailedEditShowsErrorInsteadOfUnappliedDiff() {
        let e = RemoteTimeline.claude(transcript: toolTranscript(
            id: "edit-1", name: "Edit", input: ["file_path": "a.rs", "old_string": "old", "new_string": "new"],
            result: "Old string not found", isError: true))
        XCTAssertEqual(e[0].status, "error")
        XCTAssertEqual(e[0].body, "Old string not found")
        XCTAssertNil(e[0].additions)
        XCTAssertNil(e[0].deletions)
    }

    /// Adapted from `agent_logs_tool_use_and_result`.
    func testToolUseAndResult() {
        let e = RemoteTimeline.claude(transcript: toolTranscript(id: "tu1", name: "Read", input: ["file_path": "a.rs"], result: "ok", isError: false))
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].lead, "Read")
        XCTAssertEqual(e[0].subject, "a.rs")
        XCTAssertEqual(e[0].status, "ok")
    }

    /// Adapted from `edit_tools_synthesize_diff_and_keep_it_across_result`.
    func testEditToolsSynthesizeDiffAndKeepItAcrossResult() {
        let e = RemoteTimeline.claude(transcript: toolTranscript(
            id: "tu1", name: "Edit", input: ["file_path": "src/a.ts", "old_string": "a\nb", "new_string": "a\nc"],
            result: "The file src/a.ts has been updated successfully.", isError: false))
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].lead, "Edited")
        XCTAssertEqual(e[0].subject, "src/a.ts")
        XCTAssertEqual(e[0].additions, 2)
        XCTAssertEqual(e[0].deletions, 2)
        let body = e[0].body!
        XCTAssertTrue(body.contains("-b"), body)
        XCTAssertTrue(body.contains("+c"), body)
        XCTAssertTrue(body.contains("@@"), body)
        XCTAssertFalse(body.contains("updated successfully"), body)
        XCTAssertEqual(e[0].status, "ok")
    }

    /// Adapted from `bash_result_still_becomes_body`.
    func testBashResultStillBecomesBody() {
        let e = RemoteTimeline.claude(transcript: toolTranscript(id: "tu1", name: "Bash", input: ["command": "ls"], result: "src\nCargo.toml", isError: false))
        XCTAssertEqual(e[0].lead, "Ran")
        XCTAssertEqual(e[0].body, "src\nCargo.toml")
        XCTAssertNil(e[0].additions)
    }

    // MARK: parse_tool_use

    func testWriteAndOpenCodeCamelCaseAndSearchReplace() {
        let write = TimelineTools.parseToolUse(#"{"name":"Write","input":{"file_path":"n.ts","content":"one\ntwo"}}"#, id: "w1", ts: 0)!
        XCTAssertEqual(write.lead, "Wrote")
        XCTAssertEqual(write.additions, 2)
        XCTAssertNil(write.deletions)
        XCTAssertTrue(write.body!.contains("+one"))

        let oc = TimelineTools.parseToolUse(#"{"name":"edit","input":{"filePath":"src/b.ts","oldString":"x","newString":"y"}}"#, id: "e1", ts: 0)!
        XCTAssertEqual(oc.lead, "Edited")
        XCTAssertEqual(oc.additions, 1)
        XCTAssertEqual(oc.deletions, 1)
        XCTAssertTrue(oc.body!.contains("-x"))
        XCTAssertTrue(oc.body!.contains("+y"))

        // The Grok half of this test fed chat_history.jsonl; the same
        // search_replace call through a transcript must keep its diff over "ok".
        let tool = RemoteTimeline.claude(transcript: toolTranscript(
            id: "t1", name: "search_replace", input: ["file_path": "a.rs", "old_string": "foo", "new_string": "bar"],
            result: "ok", isError: false))[0]
        XCTAssertEqual(tool.lead, "Edited")
        XCTAssertEqual(tool.additions, 1)
        XCTAssertEqual(tool.deletions, 1)
        XCTAssertTrue(tool.body!.contains("-foo") && tool.body!.contains("+bar"), tool.body!)
        XCTAssertNotEqual(tool.body, "ok")
    }

    func testParseToolUseUnwrapsUseToolWrapper() {
        let e = TimelineTools.parseToolUse(
            #"{"name":"use_tool","input":{"tool_name":"write_file","tool_input":{"file_path":"n.ts","content":"one\ntwo"}}}"#, id: "w1", ts: 0)!
        XCTAssertEqual(e.lead, "Wrote")
        XCTAssertEqual(e.subject, "n.ts")
        XCTAssertEqual(e.additions, 2)
        XCTAssertTrue(e.body!.contains("+one"))
    }

    func testCursorResultDiffIsRenderedInsteadOfWrappedJSON() {
        let e = TimelineTools.parseToolUse(#"{"toolUseId":"cursor-edit","name":"edit","input":{"path":"src/main.rs"}}"#, id: "entry", ts: 0)!
        let diff = "@@ -1 +1,2 @@\n-old\n+new\n+line\n"
        let result = jsonLine(["status": "success", "value": ["linesAdded": 2, "linesRemoved": 1, "diffString": diff]])
        let applied = TimelineTools.applyingResult(e, content: result, isError: false)
        XCTAssertEqual(applied.body, diff)
        XCTAssertEqual(applied.additions, 2)
        XCTAssertEqual(applied.deletions, 1)
    }

    func testMultiEditAndApplyPatch() {
        let multi = TimelineTools.parseToolUse(
            #"{"name":"MultiEdit","input":{"file_path":"a.ts","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d\ne"}]}}"#, id: "m1", ts: 0)!
        XCTAssertEqual(multi.additions, 3)
        XCTAssertEqual(multi.deletions, 2)
        let body = multi.body!
        XCTAssertTrue(body.contains("-a") && body.contains("+b"))
        XCTAssertTrue(body.contains("-c") && body.contains("+d"))

        let patch = TimelineTools.parseToolUse(
            #"{"name":"ApplyPatch","input":{"patch":"*** Begin Patch\n@@ -1,1 +1,2 @@\n-old\n+new\n+line\n"}}"#, id: "p1", ts: 0)!
        XCTAssertEqual(patch.lead, "Edited")
        XCTAssertEqual(patch.additions, 2)
        XCTAssertEqual(patch.deletions, 1)
    }

    // MARK: Leads, subjects, caps

    func testToolLeadsMatchDesktopChatVerbs() {
        let cases = [
            ("Read", "Read"), ("Bash", "Ran"), ("Edit", "Edited"), ("Write", "Wrote"), ("ApplyPatch", "Edited"),
            ("Task", "Agent"), ("mcp__foo__Read", "Read"), ("run_terminal_command", "Ran"), ("read_file", "Read"),
            ("search_replace", "Edited"), ("write_file", "Wrote"), ("spawn_subagent", "Agent"),
            ("get_command_or_subagent_output", "Subagent"), ("todo_write", "Todos"),
            ("mcp__firecrawl__firecrawl_search", "MCP"), ("some_custom_tool", "Some custom tool"),
        ]
        for (name, lead) in cases { XCTAssertEqual(TimelineTools.lead(name), lead, name) }
    }

    func testToolSubjectsUseChatFriendlyFields() {
        XCTAssertEqual(TimelineTools.subjectDetail("run_terminal_command", json(#"{"command":"ls -la src","description":"list"}"#)).subject, "ls -la src")
        XCTAssertEqual(TimelineTools.subjectDetail("read_file", json(#"{"target_file":"/Users/example/proj/src/main.rs"}"#)).subject, "src/main.rs")
        XCTAssertEqual(TimelineTools.subjectDetail("spawn_subagent", json(#"{"prompt":"explore the auth module deeply"}"#)).subject, "explore the auth module deeply")
    }

    func testCapEntriesKeepsTail() {
        let entries = (0..<5).map { MobileTimelineEntry(id: "\($0)", kind: "user", text: "m\($0)", ts: $0) }
        let capped = RemoteTimeline.capped(entries, max: 2)
        XCTAssertEqual(capped.map(\.text), ["m3", "m4"])
    }

    func testRenderableKindsMatchPWA() {
        XCTAssertTrue(RemoteTimeline.isRenderableKind("user"))
        XCTAssertTrue(RemoteTimeline.isRenderableKind("tool"))
        XCTAssertFalse(RemoteTimeline.isRenderableKind("approval"))
    }
}
