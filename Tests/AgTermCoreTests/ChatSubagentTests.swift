import XCTest
@testable import AgTermCore

/// Subagents and workflows in the chat, in the record shapes Claude Code, Codex and Grok write:
/// a background agent stays running until the record that says it finished, then shows its answer.
final class ChatSubagentTests: XCTestCase {
    func rows(_ agent: TimelineFeed.Agent, _ lines: [String]) -> [ChatRow] {
        var feed = TimelineFeed(agent: agent)
        feed.feed(chunk: Data((lines.joined(separator: "\n") + "\n").utf8))
        return ChatRows.build(feed.entries, working: false)
    }

    func agents(_ rows: [ChatRow]) -> [ChatAgent] {
        rows.compactMap { if case .agent(let a) = $0 { return a }; return nil }
    }

    // MARK: Claude Code

    func claude(_ type: String, _ uuid: String, _ content: Any, minute: Int = 0, extra: [String: Any] = [:]) -> String {
        jsonLine(["type": type, "uuid": uuid, "timestamp": String(format: "2026-11-08T12:%02d:00.000Z", minute),
                  "message": ["content": content]].merging(extra) { $1 })
    }

    func use(_ uuid: String, _ id: String, _ name: String, _ input: [String: Any], minute: Int = 0) -> String {
        claude("assistant", uuid, [["type": "tool_use", "id": id, "name": name, "input": input]], minute: minute)
    }

    func result(_ uuid: String, _ id: String, _ text: String, minute: Int = 0) -> String {
        claude("user", uuid, [["type": "tool_result", "tool_use_id": id, "content": [["type": "text", "text": text]]]], minute: minute)
    }

    func notification(_ toolUseID: String, status: String, result: String) -> String {
        "<task-notification>\n<task-id>a1</task-id>\n<tool-use-id>\(toolUseID)</tool-use-id>\n<status>\(status)</status>\n"
            + "<summary>Agent finished</summary>\n<result>\(result)</result>\n</task-notification>"
    }

    func testClaudeForegroundAgentIsAnAgentRowWithItsAnswer() {
        let r = rows(.claude, [use("a1", "t1", "Agent", ["description": "Count lines", "subagent_type": "Explore", "prompt": "count"]),
                               result("u1", "t1", "**3** lines", minute: 2)])
        XCTAssertEqual(r.map(\.kindName), ["agent"])
        let a = agents(r)[0]
        XCTAssertEqual(a.kind, .agent)
        XCTAssertEqual(a.title, "Count lines")
        XCTAssertEqual(a.type, "Explore")
        XCTAssertEqual(a.status, .ok)
        XCTAssertEqual(a.result, "**3** lines")
        XCTAssertEqual(a.durationMs, 120_000)
    }

    func testClaudeBackgroundAgentRunsUntilItsNotification() {
        let launched = [use("a1", "t1", "Agent", ["description": "Review the branch", "subagent_type": "code-reviewer",
                                                  "prompt": "review", "run_in_background": true]),
                        result("u1", "t1", "Async agent launched successfully.\nagentId: a1 (internal ID)")]
        let running = agents(rows(.claude, launched))[0]
        XCTAssertEqual(running.status, .running)
        XCTAssertNil(running.result, "the launch receipt isn't its answer")

        let note = claude("user", "n1", notification("t1", status: "completed", result: "No issues found."), minute: 5,
                          extra: ["origin": ["kind": "task-notification"]])
        let r = rows(.claude, launched + [note])
        XCTAssertFalse(r.contains { if case .user = $0 { return true }; return false }, "the notification isn't a user row: \(r)")
        let done = agents(r)[0]
        XCTAssertEqual(done.status, .ok)
        XCTAssertEqual(done.result, "No issues found.")
        XCTAssertEqual(done.durationMs, 300_000)
    }

    func testClaudeNotificationInsideReminderBlocksAndFailures() {
        let note = "<system-reminder>\n[SYSTEM NOTIFICATION]\n" + notification("t1", status: "failed", result: "Error: out of turns") + "\n</system-reminder>"
        let r = rows(.claude, [use("a1", "t1", "Agent", ["description": "Fix it", "prompt": "fix"]),
                               result("u1", "t1", "Async agent launched successfully."),
                               claude("user", "n1", [["type": "text", "text": note]], minute: 1)])
        XCTAssertEqual(agents(r).first?.status, .error)
        XCTAssertEqual(agents(r).first?.result, "Error: out of turns")
    }

    func testClaudeWorkflowShowsItsMetaAndResult() {
        let script = "export const meta = {\n  name: 'porchlight-phase1',\n  description: 'Research carriers and build the API',\n"
            + "  phases: [{ title: 'Research' }],\n}\nawait agent('x')"
        let launched = [use("a1", "w1", "Workflow", ["script": script]),
                        result("u1", "w1", "Workflow launched in background. Task ID: w14i3dbm8\nSummary: Research carriers")]
        let running = agents(rows(.claude, launched))[0]
        XCTAssertEqual(running.kind, .workflow)
        XCTAssertEqual(running.label, "Workflow")
        XCTAssertEqual(running.title, "Research carriers and build the API")
        XCTAssertEqual(running.type, "porchlight-phase1")
        XCTAssertEqual(running.status, .running)

        let r = rows(.claude, launched + [claude("user", "n1", notification("w1", status: "completed", result: "{\"research\":\"done\"}"), minute: 9)])
        XCTAssertEqual(agents(r)[0].status, .ok)
        XCTAssertEqual(agents(r)[0].result, "{\"research\":\"done\"}")
    }

    func testClaudeNotificationForAnUnknownCallIsIgnored() {
        let r = rows(.claude, [claude("user", "u1", "go"), claude("user", "n1", notification("nope", status: "completed", result: "x"))])
        XCTAssertEqual(r.map(\.kindName), ["user"])
    }

    func testPhoneTimelineKeepsABackgroundAgentRunning() {
        let text = [use("a1", "t1", "Agent", ["description": "Review", "prompt": "r"]),
                    result("u1", "t1", "Async agent launched successfully.")].joined(separator: "\n") + "\n"
        XCTAssertEqual(RemoteTimeline.claude(transcript: text).first?.status, "running")
    }

    // MARK: Codex

    func codex(_ type: String, _ payload: [String: Any], minute: Int = 0) -> String {
        jsonLine(["timestamp": String(format: "2026-11-08T12:%02d:00.000Z", minute), "type": type, "payload": payload])
    }

    var codexSpawn: [String] {
        [codex("event_msg", ["type": "user_message", "message": "review both halves"]),
         codex("response_item", ["type": "function_call", "name": "spawn_agent", "namespace": "collaboration", "call_id": "c1",
                                 "arguments": jsonLine(["task_name": "ts_review", "agent_type": "explorer", "message": "gAAAAABq7t"])]),
         codex("event_msg", ["type": "item_completed", "item": ["type": "SubAgentActivity", "kind": "started", "id": "c1",
                                                                  "agent_path": "/root/ts_review"]]),
         codex("response_item", ["type": "function_call_output", "call_id": "c1", "output": jsonLine(["task_name": "/root/ts_review"])]),
         codex("response_item", ["type": "function_call", "name": "wait_agent", "namespace": "collaboration", "call_id": "c2",
                                 "arguments": jsonLine(["timeout_ms": 10000])]),
         codex("response_item", ["type": "function_call_output", "call_id": "c2", "output": jsonLine(["message": "Wait timed out.", "timed_out": true])])]
    }

    func testCodexSpawnedAgentRunsUntilItCompletes() {
        let r = rows(.codex, codexSpawn)
        let running = agents(r)
        XCTAssertEqual(running.count, 1, "\(r)")
        XCTAssertEqual(running[0].title, "ts_review")
        XCTAssertEqual(running[0].type, "explorer")
        XCTAssertEqual(running[0].status, .running)
        XCTAssertNil(running[0].result)
        guard case .tool(let wait)? = r.last else { return XCTFail("\(r)") }
        XCTAssertEqual(wait.lead, "Subagent")

        let finished = codexSpawn + [
            codex("event_msg", ["type": "item_completed", "item": ["type": "SubAgentActivity", "kind": "completed",
                                                                     "agent_path": "/root/ts_review"]], minute: 3),
            codex("response_item", ["type": "agent_message", "author": "/root/ts_review", "recipient": "/root",
                                    "content": [["type": "input_text", "text": "Message Type: FINAL_ANSWER\nTask name: /root\nSender: /root/ts_review\nPayload:\n1. **High**: a bug"]]]),
        ]
        let done = agents(rows(.codex, finished))[0]
        XCTAssertEqual(done.status, .ok)
        XCTAssertEqual(done.result, "1. **High**: a bug")
        XCTAssertEqual(done.durationMs, 180_000)
        XCTAssertEqual(RemoteTimeline.codex(rollout: finished.joined(separator: "\n") + "\n").first { $0.toolName?.contains("spawn") == true }?.status, "ok")
    }

    // MARK: Grok

    func grokCall(_ id: String, _ name: String, _ args: [String: Any]) -> String {
        jsonLine(["type": "assistant", "content": "", "model_id": "grok-4.7-build-fast",
                  "tool_calls": [["id": id, "name": name, "arguments": jsonLine(args)]]])
    }

    func grokResult(_ id: String, _ content: String) -> String {
        jsonLine(["type": "tool_result", "tool_call_id": id, "content": content])
    }

    var grokSpawn: [String] {
        [grokCall("g1", "spawn_subagent", ["description": "Write the item", "prompt": "write", "subagent_type": "general-purpose"]),
         grokResult("g1", "Subagent started in background.\nsubagent_id: 01a0\ntype: general-purpose\ndescription: Write the item")]
    }

    func testGrokBackgroundSubagentFinishesFromItsOutput() {
        let running = agents(rows(.grok, grokSpawn))[0]
        XCTAssertEqual(running.title, "Write the item")
        XCTAssertEqual(running.type, "general-purpose")
        XCTAssertEqual(running.status, .running)

        let stillRunning = grokSpawn + [grokCall("g2", "get_command_or_subagent_output", ["task_ids": ["01a0"]]),
                                        grokResult("g2", "=== Task 01a0 ===\nStatus: running\n\n=== Output ===\nSubagent is still running.")]
        XCTAssertEqual(agents(rows(.grok, stillRunning))[0].status, .running)

        let output = "=== Task 01a0 ===\nCommand: [subagent:general-purpose] Write the item\nStatus: completed\nExit Code: 0\n\n"
            + "=== Output ===\nWrote `item.json`.\n\n<subagent_meta>id=01a0, tool_calls=24</subagent_meta>\n\n<subagent_result>\nsubagent_id: 01a0\n</subagent_result>"
        let done = agents(rows(.grok, stillRunning + [grokCall("g3", "get_command_or_subagent_output", ["task_ids": ["01a0"]]),
                                                       grokResult("g3", output)]))[0]
        XCTAssertEqual(done.status, .ok)
        XCTAssertEqual(done.result, "Wrote `item.json`.")
    }

    func testGrokTaskNoticeFinishesASubagent() {
        let notice = jsonLine(["type": "user", "synthetic_reason": "task_completed", "content": [["type": "text", "text":
            "<system-reminder>\nBackground task \"01a0\" completed (terminated by signal killed).\nDescription: Write the item\n</system-reminder>"]]])
        let r = rows(.grok, grokSpawn + [notice])
        XCTAssertEqual(agents(r)[0].status, .error)
        XCTAssertEqual(r.count, 1, "the notice isn't a row of its own: \(r)")
    }

    // MARK: Helpers

    func testMetaFieldReadsQuotedValues() {
        XCTAssertEqual(Subagents.metaField("export const meta = { name: \"a-b\", description: `Do x` }", "description"), "Do x")
        XCTAssertEqual(Subagents.metaField("export const meta = { name: \"a-b\" }", "name"), "a-b")
        XCTAssertNil(Subagents.metaField("const x = 1", "name"))
    }
}
