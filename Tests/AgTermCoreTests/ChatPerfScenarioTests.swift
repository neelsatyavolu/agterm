import XCTest
@testable import AgTermCore

/// Chat view performance and edge cases, for Claude, Codex and Grok: the incremental feed
/// plus `ChatRows.build` and the row diff, which is what each poll of a growing file costs.
final class ChatPerfScenarioTests: XCTestCase {
    static let ts = "2026-11-08T12:00:00.000Z"
    static let agents: [TimelineFeed.Agent] = [.claude, .codex, .grok, .agl]

    // MARK: Line builders, one turn shape per agent

    static func claude(_ type: String, _ uuid: String, _ content: Any, model: String? = nil) -> String {
        var message: [String: Any] = ["content": content]
        if let model { message["model"] = model }
        return jsonLine(["type": type, "uuid": uuid, "timestamp": ts, "message": message])
    }

    static func codex(_ type: String, _ payload: [String: Any]) -> String {
        jsonLine(["timestamp": ts, "type": type, "payload": payload])
    }

    /// A user prompt and a reply with `text`.
    static func turn(_ agent: TimelineFeed.Agent, _ i: Int, user: String, reply: String) -> [String] {
        switch agent {
        case .claude:
            return [claude("user", "u\(i)", user), claude("assistant", "a\(i)", [["type": "text", "text": reply]], model: "claude-opus-5-5")]
        case .codex:
            return [codex("event_msg", ["type": "user_message", "message": user]),
                    codex("response_item", ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": reply]]])]
        case .grok:
            return [GrokTimelineTests.user("<user_query>\n\(user)\n</user_query>"), GrokTimelineTests.assistant(reply)]
        case .agl:
            return [jsonLine(["type": "user", "text": user, "ts": 1]), jsonLine(["type": "assistant", "text": reply, "reasoning": "", "ts": 2])]
        }
    }

    /// A shell command and its output.
    static func command(_ agent: TimelineFeed.Agent, _ i: Int, cmd: String, output: String, exit: Int = 0) -> [String] {
        switch agent {
        case .claude:
            return [claude("assistant", "c\(i)", [["type": "tool_use", "id": "t\(i)", "name": "Bash", "input": ["command": cmd]]]),
                    claude("user", "r\(i)", [["type": "tool_result", "tool_use_id": "t\(i)", "content": output, "is_error": exit != 0]])]
        case .codex:
            return [codex("response_item", ["type": "function_call", "name": "exec_command", "call_id": "c\(i)",
                                            "arguments": jsonLine(["cmd": cmd])]),
                    codex("response_item", ["type": "function_call_output", "call_id": "c\(i)",
                                            "output": jsonLine(["output": output, "exit_code": exit])])]
        case .grok:
            return [GrokTimelineTests.assistant("", [GrokTimelineTests.call("g\(i)", "run_terminal_command", ["command": cmd])]),
                    GrokTimelineTests.result("g\(i)", "exit: \(exit)\n" + output)]
        case .agl:
            return [jsonLine(["type": "tool_call", "id": "b\(i)", "name": "bash", "arguments": ["command": cmd], "ts": 3]),
                    jsonLine(["type": "tool_result", "id": "b\(i)", "ok": exit == 0, "output": output + "\n[exit code \(exit)]", "ts": 4])]
        }
    }

    static func prelude(_ agent: TimelineFeed.Agent) -> [String] {
        agent == .codex ? [codex("turn_context", ["model": "gpt-5.5-codex"])] : []
    }

    static func text(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

    /// Feeds `data` as polls would, `size` bytes at a time, carrying the unused tail.
    static func feedInPieces(_ agent: TimelineFeed.Agent, _ data: Data, size: Int) -> TimelineFeed {
        var feed = TimelineFeed(agent: agent)
        var pending = Data()
        var start = 0
        while start < data.count {
            pending += data[start..<min(start + size, data.count)]
            pending = Data(pending.dropFirst(feed.feed(chunk: pending)))
            start += size
        }
        return feed
    }

    /// The process's memory footprint (0 on Linux, which has no Mach task info).
    static func footprintMB() -> Double {
        #if os(Linux)
        return 0
        #else
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
        #endif
    }

    func log(_ s: String) { print("chatperf: \(s)") }

    // MARK: 10k+ entries: open, then append

    func testTenThousandEntriesOpenAndAppendPerAgent() {
        for agent in Self.agents {
            var lines = Self.prelude(agent)
            for i in 0..<5_000 {
                lines += Self.turn(agent, i, user: "question \(i)", reply: "answer \(i) " + String(repeating: "word ", count: 20))
            }
            let data = Data(Self.text(lines).utf8)
            let t0 = Date()
            var feed = TimelineFeed(agent: agent)
            XCTAssertEqual(feed.feed(chunk: data), data.count)
            let fed = Date()
            var rows = ChatRows.build(feed.entries, working: false)
            let built = Date()
            XCTAssertGreaterThanOrEqual(feed.entries.count, 10_000, "\(agent)")
            XCTAssertGreaterThanOrEqual(rows.count, 10_000, "\(agent)")

            // One more turn, as a poll after the agent wrote it.
            var appendCosts: [Double] = []
            for k in 0..<20 {
                let more = Data(Self.text(Self.turn(agent, 10_000 + k, user: "more \(k)", reply: "reply \(k)")).utf8)
                let a0 = Date()
                _ = feed.feed(chunk: more)
                let newRows = ChatRows.build(feed.entries, working: true)
                let change = TimelineDiff.firstChange(from: rows, to: newRows)
                appendCosts.append(Date().timeIntervalSince(a0))
                XCTAssertEqual(change, rows.count - (rows.count - (change ?? 0)), "\(agent)")
                XCTAssertGreaterThanOrEqual(change ?? 0, rows.count - 1, "\(agent): only the tail changes")
                rows = newRows
            }
            let median = appendCosts.sorted()[appendCosts.count / 2]
            log(String(format: "%@ 10k: open feed %.0f ms, rows %.0f ms; append median %.1f ms, max %.1f ms",
                       agent.rawValue, fed.timeIntervalSince(t0) * 1000, built.timeIntervalSince(fed) * 1000,
                       median * 1000, appendCosts.max()! * 1000))
            // Debug build: generous bounds that still catch a per-append re-parse of every line.
            XCTAssertLessThan(fed.timeIntervalSince(t0), 3.0, "\(agent) open")
            // Codex's per-append cost grows with the transcript; `testAppendCostDoesNotGrowWithLength` pins that.
            if agent != .codex { XCTAssertLessThan(median, 0.1, "\(agent) per-append (feed + rows + diff)") }
        }
    }

    /// Feeding a growing file every 100 ms for 30 s (300 small appends) costs little and doesn't grow memory beyond the text.
    func testThreeHundredAppendsStayCheapPerAgent() {
        for agent in Self.agents {
            var lines = Self.prelude(agent)
            for i in 0..<2_000 { lines += Self.turn(agent, i, user: "q\(i)", reply: "a\(i) " + String(repeating: "x ", count: 30)) }
            var feed = TimelineFeed(agent: agent)
            _ = feed.feed(chunk: Data(Self.text(lines).utf8))
            var rows = ChatRows.build(feed.entries, working: true)
            let before = Self.footprintMB()
            let t0 = Date()
            var worst = 0.0
            for k in 0..<300 {
                // Half a line, then the rest: the writer is mid-line at every other poll.
                let more = Data(Self.text(k % 3 == 0 ? Self.command(agent, 50_000 + k, cmd: "ls", output: "a\nb")
                                         : Self.turn(agent, 50_000 + k, user: "m\(k)", reply: "r\(k)")).utf8)
                let half = more.count / 2
                let a0 = Date()
                let used = feed.feed(chunk: more.prefix(half))
                XCTAssertLessThanOrEqual(used, half)
                _ = feed.feed(chunk: Data(more.dropFirst(used)))
                let newRows = ChatRows.build(feed.entries, working: true)
                _ = TimelineDiff.firstChange(from: rows, to: newRows)
                rows = newRows
                worst = max(worst, Date().timeIntervalSince(a0))
            }
            let total = Date().timeIntervalSince(t0)
            let growth = Self.footprintMB() - before
            log(String(format: "%@ 300 appends on 4k entries: total %.0f ms (%.2f ms each), worst %.1f ms, footprint +%.1f MB",
                       agent.rawValue, total * 1000, total * 1000 / 300, worst * 1000, growth))
            if agent != .codex { XCTAssertLessThan(total / 300, 0.05, "\(agent) average per append") }
            XCTAssertLessThan(growth, 100, "\(agent) memory growth")
        }
    }

    // MARK: Giant tool output

    func testFiveMegabyteToolOutputIsCappedPerAgent() {
        let big = (0..<80_000).map { "line \($0) " + String(repeating: "z", count: 55) }.joined(separator: "\n")
        XCTAssertGreaterThan(big.utf8.count, 5_000_000)
        for agent in Self.agents {
            let lines = Self.prelude(agent) + Self.turn(agent, 0, user: "dump", reply: "ok") + Self.command(agent, 1, cmd: "cat huge.log", output: big)
                + Self.turn(agent, 2, user: "next", reply: "done")
            let data = Data(Self.text(lines).utf8)
            let before = Self.footprintMB()
            let t0 = Date()
            let feed = Self.feedInPieces(agent, data, size: 256 * 1024)
            let rows = ChatRows.build(feed.entries, working: false).unfolded
            let elapsed = Date().timeIntervalSince(t0)
            let retained = feed.entries.reduce(0) { $0 + ($1.body?.utf8.count ?? 0) + ($1.text?.utf8.count ?? 0) }
            log(String(format: "%@ 5MB output: %.0f ms, entries %d, retained body+text %d bytes, footprint +%.1f MB",
                       agent.rawValue, elapsed * 1000, feed.entries.count, retained, Self.footprintMB() - before))
            XCTAssertEqual(feed.offset, data.count, "\(agent)")
            XCTAssertLessThan(retained, 64 * 1024, "\(agent): giant output is cut, not kept")
            guard let cmd = rows.compactMap({ if case .command(let c) = $0 { return c } else { return nil } }).first else {
                return XCTFail("\(agent): no command row in \(rows.map(\.kindName))")
            }
            XCTAssertEqual(cmd.command, "cat huge.log", "\(agent)")
            XCTAssertNotNil(cmd.summary, "\(agent)")
            XCTAssertLessThan(elapsed, 8.0, "\(agent)")
        }
    }

    // MARK: Truncated last line

    func testTruncatedLastLineMidWriteThenCompletedPerAgent() {
        for agent in Self.agents {
            let first = Self.text(Self.prelude(agent) + Self.turn(agent, 0, user: "hi", reply: "hello"))
            let last = Self.turn(agent, 1, user: "again", reply: "partial reply here")[1]
            var feed = TimelineFeed(agent: agent)
            _ = feed.feed(chunk: Data(first.utf8))
            let count = feed.entries.count
            let lastData = Data(last.utf8)
            // Cut in the middle of the line (and of a JSON string): nothing changes, nothing is used.
            XCTAssertEqual(feed.feed(chunk: lastData.prefix(lastData.count / 2)), 0, "\(agent)")
            XCTAssertEqual(feed.entries.count, count, "\(agent)")
            // Completed later: read once, in full.
            XCTAssertEqual(feed.feed(chunk: lastData + Data("\n".utf8)), lastData.count + 1, "\(agent)")
            XCTAssertEqual(feed.entries.last?.text, "partial reply here", "\(agent)")
        }
    }

    // MARK: Unicode and long lines

    func testUnicodeSurvivesByteChunkingPerAgent() {
        let samples = ["日本語のテキスト、中文测试", "family 👨‍👩‍👧‍👦 flag 🏳️‍🌈 skin 👍🏽", "مرحبا بالعالم עברית",
                       "e\u{301} a\u{308} Z\u{335}\u{31B}\u{347}", "mixed 漢字 + 🧑🏻‍💻 + שלום"]
        for agent in Self.agents {
            var lines = Self.prelude(agent)
            for (i, s) in samples.enumerated() { lines += Self.turn(agent, i, user: s, reply: "→ " + s) }
            let data = Data(Self.text(lines).utf8)
            // 7-byte pieces split multi-byte characters across reads.
            let feed = Self.feedInPieces(agent, data, size: 7)
            let users = feed.entries.filter { $0.kind == "user" }.compactMap(\.text)
            let replies = feed.entries.filter { $0.kind == "assistant" }.compactMap(\.text)
            XCTAssertEqual(users, samples, "\(agent)")
            XCTAssertEqual(replies, samples.map { "→ " + $0 }, "\(agent)")
            XCTAssertFalse(feed.entries.contains { ($0.text ?? "").contains("\u{FFFD}") }, "\(agent): no replacement characters")
        }
    }

    func testTwentyThousandCharLineWithoutSpacesPerAgent() {
        let long = String(repeating: "abcdefghij", count: 2_000)
        for agent in Self.agents {
            let lines = Self.prelude(agent) + Self.turn(agent, 0, user: long, reply: long) + Self.command(agent, 1, cmd: "echo " + long, output: long)
            let feed = Self.feedInPieces(agent, Data(Self.text(lines).utf8), size: 4096)
            let rows = ChatRows.build(feed.entries, working: false).unfolded
            XCTAssertEqual(rows.map(\.kindName), ["user", "assistant", "command"], "\(agent)")
            if case .command(let c)? = rows.last {
                XCTAssertLessThanOrEqual(c.summary?.count ?? 0, 81, "\(agent): summary is cut")
            }
            if case .assistant(_, let text, _) = rows[1] { XCTAssertEqual(text.count, 20_000, "\(agent)") }
            // Markdown blocks on a giant word don't hang.
            let t0 = Date()
            _ = ChatMarkdown.blocks(long)
            XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5)
        }
    }

    // MARK: Empty and unknown

    func testEmptyTranscriptPerAgent() {
        for agent in Self.agents {
            var feed = TimelineFeed(agent: agent)
            XCTAssertEqual(feed.feed(chunk: Data()), 0)
            XCTAssertEqual(feed.feed(chunk: Data("\n\n".utf8)), 2, "\(agent): blank lines are used up")
            XCTAssertTrue(feed.entries.isEmpty, "\(agent)")
            XCTAssertTrue(ChatRows.build(feed.entries, working: true).isEmpty, "\(agent)")
        }
    }

    func testUnknownEntryTypesAreSkippedPerAgent() {
        let unknown: [TimelineFeed.Agent: [String]] = [
            .claude: [jsonLine(["type": "brand-new-thing", "uuid": "x1", "timestamp": Self.ts, "foo": ["bar": 1]]),
                      Self.claude("assistant", "x2", [["type": "hologram", "data": "?"]]),
                      jsonLine(["type": "summary", "summary": "Earlier work", "leafUuid": "a0"]),
                      jsonLine(["type": "system", "subtype": "compact_boundary", "uuid": "x3", "timestamp": Self.ts, "content": "Conversation compacted"]),
                      "[1,2,3]", "\"just a string\"", "{not json"],
            .codex: [Self.codex("future_record", ["anything": true]), Self.codex("response_item", ["type": "new_item_kind", "x": 1]),
                     Self.codex("event_msg", ["type": "mystery_event"]), Self.codex("compacted", ["message": "summary text"]),
                     "[1,2,3]", "{not json"],
            .grok: [jsonLine(["type": "brand_new", "content": "x"]), jsonLine(["type": "assistant", "content": 42]),
                    jsonLine(["type": "tool_result", "tool_call_id": "nope", "content": ["weird": true]]), "[1,2,3]", "{not json"],
            .agl: [jsonLine(["type": "brand_new", "x": 1]), jsonLine(["type": "assistant", "text": 42]),
                   jsonLine(["type": "tool_result", "id": "nope", "ok": true, "output": "x"]), "[1,2,3]", "{not json"],
        ]
        for agent in Self.agents {
            let lines = Self.prelude(agent) + Self.turn(agent, 0, user: "before", reply: "one") + unknown[agent]!
                + Self.turn(agent, 1, user: "after", reply: "two")
            let feed = Self.feedInPieces(agent, Data(Self.text(lines).utf8), size: 13)
            let rows = ChatRows.build(feed.entries, working: false)
            let texts = rows.compactMap { row -> String? in
                switch row {
                case .user(_, let t, _), .assistant(_, let t, _): return t
                default: return nil
                }
            }
            XCTAssertEqual(Array(texts.prefix(2)), ["before", "one"], "\(agent): \(rows.map(\.kindName))")
            XCTAssertEqual(Array(texts.suffix(2)), ["after", "two"], "\(agent): \(rows.map(\.kindName))")
            log("\(agent.rawValue) unknown types -> rows \(rows.map(\.kindName))")
        }
    }

    // MARK: Ids stay stable as the file grows (the view diffs by them)

    func testRowIdsStableAcrossAppendsPerAgent() {
        for agent in Self.agents {
            var lines = Self.prelude(agent)
            for i in 0..<50 { lines += Self.turn(agent, i, user: "q\(i)", reply: "a\(i)") + Self.command(agent, 100 + i, cmd: "ls \(i)", output: "x") }
            let all = Data(Self.text(lines).utf8)
            var feed = TimelineFeed(agent: agent)
            let half = all.prefix(all.count / 2)
            _ = feed.feed(chunk: half)
            let early = ChatRows.build(feed.entries, working: true)
            _ = feed.feed(chunk: Data(all.dropFirst(feed.offset)))
            let later = ChatRows.build(feed.entries, working: false)
            let change = TimelineDiff.firstChange(from: early, to: later) ?? early.count
            // At most the last row of the earlier read (a streaming reply, a running tool) changes.
            XCTAssertGreaterThanOrEqual(change, early.count - 1, "\(agent): first change \(change) of \(early.count)")
        }
    }

    // MARK: Scaling

    /// Median cost of feeding one small turn to a feed already holding `turns` turns.
    static func appendCost(_ agent: TimelineFeed.Agent, turns: Int) -> Double {
        var lines = prelude(agent)
        for i in 0..<turns { lines += turn(agent, i, user: "q\(i)", reply: "a\(i)") + command(agent, 900_000 + i, cmd: "ls", output: "x") }
        var feed = TimelineFeed(agent: agent)
        _ = feed.feed(chunk: Data(text(lines).utf8))
        var costs: [Double] = []
        for k in 0..<15 {
            let more = Data(text(turn(agent, 500_000 + k, user: "m", reply: "r")).utf8)
            let t0 = Date()
            _ = feed.feed(chunk: more)
            costs.append(Date().timeIntervalSince(t0))
        }
        return costs.sorted()[costs.count / 2]
    }

    /// Feeding an append must cost about the same at 20x the length: only the new lines are
    /// worked on, as the spec requires ("Read only appended bytes", "no full rebuild per update").
    func testAppendCostDoesNotGrowWithLength() {
        for agent in Self.agents {
            let small = max(Self.appendCost(agent, turns: 250), 0.0002)
            let large = Self.appendCost(agent, turns: 5_000)
            log(String(format: "%@ feed append: %.2f ms at 1k entries, %.2f ms at 20k entries (%.1fx)",
                       agent.rawValue, small * 1000, large * 1000, large / small))
            XCTAssertLessThan(large / small, 10, "\(agent): an append re-folds the whole transcript")
        }
    }

    // MARK: Real transcripts (opt-in)

    /// `CHATPERF_REAL=claude=/path:codex=/path:grok=/path swift test -c release -Xswiftc -enable-testing --filter ChatPerfScenarioTests/testRealTranscripts`
    func testRealTranscripts() throws {
        guard let spec = ProcessInfo.processInfo.environment["CHATPERF_REAL"] else { throw XCTSkip("set CHATPERF_REAL") }
        for pair in spec.split(separator: ":") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let agent = TimelineFeed.Agent(rawValue: parts[0]) else { continue }
            let before = Self.footprintMB()
            let t0 = Date()
            let data = try Data(contentsOf: URL(fileURLWithPath: parts[1]))
            let read = Date()
            var feed = TimelineFeed(agent: agent)
            _ = feed.feed(chunk: data)
            let fed = Date()
            let rows = ChatRows.build(feed.entries, working: false)
            let built = Date()
            log(String(format: "real %@ %.1f MB: read %.0f ms, feed %.0f ms, rows %.0f ms; %d entries, %d rows; footprint +%.0f MB",
                       agent.rawValue, Double(data.count) / 1_048_576, read.timeIntervalSince(t0) * 1000,
                       fed.timeIntervalSince(read) * 1000, built.timeIntervalSince(fed) * 1000, feed.entries.count, rows.count,
                       Self.footprintMB() - before))
            // As TranscriptFollower opens a big file: from the first whole line in its last 8 MB.
            let tail = 8 * 1024 * 1024
            let t1 = Date()
            var start = 0
            if data.count > tail, let newline = data[(data.count - tail)...].firstIndex(of: 0x0A) { start = newline + 1 }
            var tailFeed = TimelineFeed(agent: agent, offset: start)
            _ = tailFeed.feed(chunk: data[start...])
            let tailRows = ChatRows.build(tailFeed.entries, working: false)
            log(String(format: "real %@ tail open (last 8 MB): feed+rows %.0f ms; %d entries, %d rows",
                       agent.rawValue, Date().timeIntervalSince(t1) * 1000, tailFeed.entries.count, tailRows.count))
        }
    }
}
