import XCTest
@testable import AgTermCore

/// Ported from agmux `remote/timeline.rs` (Codex cases) and the
/// `parse_session_history_content` tests in `commands/codex.rs`.
final class RemoteTimelineCodexTests: XCTestCase {
    func item(_ role: String, _ content: String, timestamp: String = "") -> CodexHistoryItem {
        CodexHistoryItem(role: role, content: content, timestamp: timestamp)
    }

    func rollout(_ records: [[String: Any]]) -> String {
        records.map(jsonLine).joined(separator: "\n")
    }

    func files(_ records: [[String: Any]]) -> [CodexHistoryItem] {
        CodexHistoryParser.items(rollout: rollout(records)).filter { $0.role == "file" }
    }

    func testToolResultUpdatesItsCallAndKeepsInterleavedCallsSeparate() {
        func tool(_ name: String, _ callID: String, _ content: String, _ error: Bool) -> CodexHistoryItem {
            .tool(name, content, "", JSONValue.parse(jsonLine(["callId": callID, "path": "a.rs"]))!, error)
        }
        XCTAssertEqual(CodexTimeline.itemsToEntries([tool("Read", "read", "", false)])[0].status, "running")
        let entries = CodexTimeline.itemsToEntries([
            tool("Read", "read", "", false),
            tool("WebSearch", "search", "", false),
            tool("ToolResult", "search", "Search unavailable", true),
            tool("ToolResult", "read", "file contents", false),
        ])
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].body, "file contents")
        XCTAssertEqual(entries[0].status, "ok")
        XCTAssertEqual(entries[1].body, "Search unavailable")
        XCTAssertEqual(entries[1].status, "error")
    }

    func testCommandSplitsIntoSubjectAndOutput() {
        let e = CodexTimeline.itemsToEntries([item("command", "$ cargo test\nrunning 3 tests\nFAILED\n[exit: 101]", timestamp: "2026-08-05T12:00:00Z")])
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(e[0].subject, "cargo test")
        XCTAssertEqual(e[0].body, "running 3 tests\nFAILED")
        // A non-zero exit is an error even though Codex sets no tool_error.
        XCTAssertEqual(e[0].status, "error")
    }

    func testHistorySkipsAgentsMDAndEnvironmentContext() {
        let ts = "2026-08-11T12:00:00Z"
        let e = CodexTimeline.itemsToEntries([
            item("user", "# AGENTS.md\n\nDo the thing.\n<environment_context>\ncwd=/tmp\n</environment_context>", timestamp: ts),
            item("user", "Hello?", timestamp: ts),
            item("assistant", "Hey! I'm here.", timestamp: ts),
            item("user", "mid-session\n<environment_context>\nfoo\n</environment_context>", timestamp: ts),
        ])
        XCTAssertEqual(e.count, 2)
        XCTAssertEqual(e[0].kind, "user")
        XCTAssertEqual(e[0].text, "Hello?")
        XCTAssertEqual(e[1].kind, "assistant")
        XCTAssertEqual(e[1].text, "Hey! I'm here.")
    }

    func testCommandWithoutOutputHasNoBody() {
        XCTAssertTrue(CodexTimeline.splitCommand("$ ls\n[exit: 0]") == ("ls", "", 0))
        XCTAssertTrue(CodexTimeline.splitCommand("$ ls") == ("ls", "", nil))
    }

    // MARK: commands/codex.rs history tests

    func testConvertsResponseItemsToGenericHistoryTools() {
        let cases: [([String: Any], String, String)] = [
            (["type": "web_search_call", "status": "completed",
              "action": ["type": "search", "query": "codex app-server", "queries": NSNull()]], "WebSearch", "codex app-server"),
            (["type": "tool_search_call", "status": "completed", "execution": "client",
              "arguments": ["query": "browser tools"]], "ToolSearch", "browser tools"),
            (["type": "image_generation_call", "status": "completed", "revised_prompt": "A crisp app screenshot",
              "result": "generated.png"], "ImageGeneration", "generated.png"),
            (["type": "function_call", "name": "mcp__docs__search", "arguments": #"{"q":"codex"}"#, "call_id": "call_1"],
             "mcp__docs__search", "codex"),
        ]
        for (payload, name, text) in cases {
            let row = CodexHistoryRows.toolItem(JSONValue.parse(jsonLine(payload))!, "2026-06-05T10:00:00Z")!
            XCTAssertEqual(row.role, "tool")
            XCTAssertEqual(row.toolName, name)
            XCTAssertTrue(row.content.contains(text) || (row.toolInput?.serdeString.contains(text) ?? false), "\(text) in \(row)")
        }
    }

    func testHistoryPreservesDistinctCallsAndIdenticalOutputs() {
        let payloads: [[String: Any]] = [
            ["type": "function_call", "name": "send_message", "call_id": "a", "arguments": "{}"],
            ["type": "custom_tool_call", "name": "exec", "call_id": "b", "input": "text(1);"],
            ["type": "function_call_output", "call_id": "a", "output": #"{"accepted":true}"#],
            ["type": "custom_tool_call_output", "call_id": "b", "output": #"{"accepted":true}"#],
            ["type": "function_call", "name": "send_message", "call_id": "c", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "c", "output": ""],
        ]
        let items = CodexHistoryParser.items(rollout: rollout(payloads.map { ["type": "response_item", "payload": $0] }))
        XCTAssertEqual(items.count, 6)
        XCTAssertEqual(items.map { $0.toolInput?["callId"]?.string }, ["a", "b", "a", "b", "c", "c"])
    }

    func native(_ diff: String) -> [String: Any] {
        ["type": "event_msg", "payload": ["type": "patch_apply_end", "call_id": "exec-native", "success": true,
                                          "changes": ["shared.rs": ["type": "update", "unified_diff": diff]]]]
    }

    func completedFileChange(_ status: String, type: String = "item_completed", itemType: String = "FileChange",
                             id: String = "exec-native") -> [String: Any] {
        ["type": "event_msg", "payload": [
            "type": type, "thread_id": "session", "turn_id": "turn",
            "item": ["type": itemType, "id": id, "status": status,
                     "changes": ["shared.rs": ["type": "update", "unified_diff": "@@\n-old\n+new"]]]]]
    }

    func testCompletedFileChangeRequiresSuccess() {
        let rows = files([completedFileChange("completed")])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.additions, 1)
        XCTAssertEqual(rows.first?.deletions, 1)
        for status in ["failed", "declined", "inProgress", "unknown", ""] {
            XCTAssertTrue(files([completedFileChange(status)]).isEmpty, status)
        }
        XCTAssertTrue(files([completedFileChange("completed", type: "item_started")]).isEmpty)
        XCTAssertTrue(files([completedFileChange("completed", itemType: "CommandExecution")]).isEmpty)
        XCTAssertTrue(files([completedFileChange("completed", id: "")]).isEmpty)
        XCTAssertEqual(files([completedFileChange("inProgress"), completedFileChange("completed")]).count, 1)
    }

    func testCompletedFileChangeDeduplicatesBothNativeSchemas() {
        let modern = completedFileChange("completed")
        let legacy = native("@@\n-old\n+new")
        XCTAssertEqual(files([modern, legacy]).count, 1)
        XCTAssertEqual(files([legacy, modern]).count, 1)
        XCTAssertEqual(files([modern, completedFileChange("completed", id: "exec-another")]).count, 2)
        XCTAssertTrue(files([completedFileChange("failed")]).isEmpty)
    }

    /// The direct (non-wrapper) half of `direct_patch_history_requires_confirmed_success`.
    func testDirectPatchHistoryRequiresConfirmedSuccess() {
        for name in ["apply_patch", "apply_patch_freeform"] {
            let request: [String: Any] = ["type": "response_item", "payload": [
                "type": "custom_tool_call", "name": name, "call_id": "exec-native",
                "input": "*** Begin Patch\n*** Update File: shared.rs\n@@\n-old\n+new\n*** End Patch"]]
            XCTAssertTrue(files([request]).isEmpty, "pending patch must not flush as success")
            for result in ["", "unknown", "Error: patch failed", "{}", #"{"error":"failed"}"#, #"{"metadata":{"exit_code":1}}"#] {
                let response: [String: Any] = ["type": "response_item", "payload": [
                    "type": "custom_tool_call_output", "call_id": "exec-native", "output": result]]
                XCTAssertTrue(files([request, response]).isEmpty, result)
            }
            let response: [String: Any] = ["type": "response_item", "payload": [
                "type": "custom_tool_call_output", "call_id": "exec-native",
                "output": #"{"output":"Success. Updated the following files:\nM shared.rs","metadata":{"exit_code":0}}"#]]
            XCTAssertEqual(files([request, response]).count, 1)
            // The native event wins over the direct output in either order.
            XCTAssertEqual(files([request, native("@@\n-old\n+new"), response]).count, 1)
            XCTAssertEqual(files([request, response, native("@@\n-old\n+new")]).count, 1)
        }
    }
}
