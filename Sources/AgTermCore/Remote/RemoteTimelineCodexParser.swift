import Foundation

/// The parts of agmux `parse_session_history_content` that produce timeline
/// rows. Code-mode `exec` wrappers (codex-cli 0.16x runs every tool through a
/// JavaScript `exec` call) show no row of their own: their shell commands,
/// edits, MCP calls and searches come from the native `item_completed`
/// records (`CodexCodeMode`).
///
/// Fed a record at a time: rows that wait on a later record (a command's
/// output, a tool's result) are tracked until it arrives, so a caller can stop
/// re-reading once `isSettled`.
struct CodexHistoryParser {
    private struct PendingCommand { let index: Int; let cmd: String }
    private struct PendingPatch { let timestamp: String; let changes: [CodexFileChange] }

    /// Rows since the last `takeSettledItems`.
    private(set) var items: [CodexHistoryItem] = []
    private var pendingPatches: [String: PendingPatch] = [:]
    private var pendingCommands: [String: PendingCommand] = [:]
    private var patchApplyEndIDs: Set<String> = []
    private var nativePatchIDs: Set<String> = []
    /// Direct apply_patch calls already shown from their output; a native event for them comes too late.
    private var directPatchIDs: Set<String> = []
    /// Tool calls (by call id) still waiting for their output.
    private var openCalls: Set<String> = []
    /// Code-mode `exec` calls still running: where their rows start.
    private var execCalls: [String: Int] = [:]
    /// Shell commands an `exec` call started that haven't reported back: (row index, command).
    private var execCommands: [(index: Int, cmd: String)] = []
    /// Each running `exec` call's script.
    private var execInputs: [String: String] = [:]
    /// Code-mode `wait` calls: plumbing, hidden with their output.
    private var hiddenCalls: Set<String> = []
    /// Native tool calls already shown from a `function_call` (MCP calls outside code mode).
    private var functionCallIDs: Set<String> = []
    /// Chat view extras the phone doesn't get: interrupted turns, commands still running.
    private var chatMarkers = false

    init(chatMarkers: Bool = false) {
        self.chatMarkers = chatMarkers
    }

    static func items(rollout: String) -> [CodexHistoryItem] {
        let records = rustLines(rollout).compactMap { line -> JSONValue? in
            let trimmed = line.rustTrimmed
            return trimmed.isEmpty ? nil : JSONValue.parse(trimmed)
        }
        return items(records: records)
    }

    static func items(records: [JSONValue], chatMarkers: Bool = false) -> [CodexHistoryItem] {
        var parser = CodexHistoryParser(chatMarkers: chatMarkers)
        // Native patch ids anywhere in the file: a direct apply_patch output is
        // superseded by its native event even when the event comes later.
        for record in records where record["type"]?.string == "event_msg" {
            if let native = record["payload"].flatMap(CodexHistoryRows.nativePatchEvent),
               let id = native["call_id"]?.string, !id.isEmpty {
                parser.nativePatchIDs.insert(id)
            }
        }
        for record in records { parser.consume(record) }
        return deduplicated(parser.finishedItems())
    }

    /// Nothing waits on a later record, so the rows so far won't change again.
    var isSettled: Bool {
        pendingCommands.isEmpty && pendingPatches.isEmpty && openCalls.isEmpty && execCalls.isEmpty && execCommands.isEmpty
    }

    /// The rows so far, with commands still waiting for output marked running (chat view).
    func finishedItems() -> [CodexHistoryItem] {
        guard chatMarkers else { return items }
        var out = items
        for pending in pendingCommands.values where pending.index < out.count { out[pending.index].running = true }
        return out
    }

    /// Hands over the rows of a settled parser and forgets them.
    mutating func takeSettledItems() -> [CodexHistoryItem] {
        precondition(isSettled)
        defer { items = [] }
        return items
    }

    mutating func consume(_ record: JSONValue) {
        guard let payload = record["payload"] else { return }
        let ts = record["timestamp"]?.string ?? ""
        switch record["type"]?.string {
        case "event_msg": consumeEvent(CodexHistoryRows.nativePatchEvent(payload) ?? payload, ts)
        case "response_item": consumeResponse(payload, ts)
        default: break
        }
    }

    private mutating func consumeEvent(_ payload: JSONValue, _ ts: String) {
        switch payload["type"]?.string {
        case "user_message":
            if let text = payload["message"]?.string { items.append(CodexHistoryItem(role: "user", content: text, timestamp: ts)) }
        case "patch_apply_end":
            let callID = payload["call_id"]?.string ?? ""
            if !callID.isEmpty && (patchApplyEndIDs.contains(callID) || directPatchIDs.contains(callID)) { return }
            let changes = CodexHistoryRows.changesFromPatchApplyEnd(payload)
            if !callID.isEmpty {
                patchApplyEndIDs.insert(callID)
                pendingPatches[callID] = nil
            }
            guard payload["success"]?.bool == true else { return }
            items += changes.map { CodexHistoryItem.file($0, ts, editID: callID, native: true) }
        case "item_completed":
            consumeCompletedItem(payload["item"] ?? .null, ts)
        case "turn_aborted":
            guard chatMarkers else { return endTurn() }
            // Esc stopped the turn: its unfinished commands won't report back.
            for pending in pendingCommands.values where pending.index < items.count { items[pending.index].toolError = true }
            for pending in execCommands where pending.index < items.count {
                items[pending.index].toolError = true
                items[pending.index].running = false
            }
            endTurn()
            items.append(CodexHistoryItem(role: "interrupted", content: "", timestamp: ts))
        case "task_complete":
            for pending in execCommands where pending.index < items.count { items[pending.index].running = false }
            endTurn()
        default:
            break
        }
    }

    /// A finished turn leaves nothing to wait for.
    private mutating func endTurn() {
        pendingCommands.removeAll()
        pendingPatches.removeAll()
        openCalls.removeAll()
        execCalls.removeAll()
        execInputs.removeAll()
        execCommands.removeAll()
    }

    /// Native records for what a code-mode `exec` call did.
    private mutating func consumeCompletedItem(_ item: JSONValue, _ ts: String) {
        switch item["type"]?.string {
        case "CommandExecution":
            guard let done = CodexCodeMode.command(item) else { return }
            if let match = execCommands.firstIndex(where: { $0.cmd == done.cmd }) {
                let index = execCommands.remove(at: match).index
                if index < items.count {
                    items[index].content = done.content
                    items[index].running = false
                    items[index].toolError = done.failed ? true : nil
                    return
                }
            }
            var row = CodexHistoryItem(role: "command", content: done.content, timestamp: ts)
            if done.failed { row.toolError = true }
            items.append(row)
        default:
            if let id = item["id"]?.string, functionCallIDs.contains(id) { return }
            if let row = CodexCodeMode.toolItem(item, ts) { items.append(row) }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private mutating func consumeResponse(_ payload: JSONValue, _ ts: String) {
        let callID = payload["call_id"]?.string ?? ""
        switch payload["type"]?.string ?? "" {
        case "message":
            guard let content = payload["content"]?.array else { return }
            let text = content.compactMap { block -> String? in
                let type = block["type"]?.string
                return type == "output_text" || type == "input_text" ? block["text"]?.string : nil
            }.joined()
            let role = payload["role"]?.string ?? ""
            // Developer/system messages are AGENTS.md, permissions and memory setup.
            guard !text.isEmpty, role != "developer", role != "system" else { return }
            items.append(CodexHistoryItem(role: role == "user" ? "user" : "assistant", content: text, timestamp: ts))
        case "function_call":
            let name = payload["name"]?.string ?? "unknown"
            let args = payload["arguments"]?.string ?? ""
            if name == "exec_command" {
                guard let parsed = JSONValue.parse(args) else { return }
                let cmd = parsed["cmd"]?.string ?? args
                if !callID.isEmpty { pendingCommands[callID] = PendingCommand(index: items.count, cmd: cmd) }
                items.append(CodexHistoryItem(role: "command", content: "$ \(cmd)", timestamp: ts))
            } else if name == "wait", payload["namespace"]?.string == nil {
                if !callID.isEmpty { hiddenCalls.insert(callID) }
            } else {
                if !callID.isEmpty {
                    openCalls.insert(callID)
                    functionCallIDs.insert(callID)
                }
                appendTool(payload, ts)
            }
        case "custom_tool_call":
            let name = payload["name"]?.string ?? ""
            let input = payload["input"]?.string ?? ""
            if name == "exec" {
                startExec(callID, input, ts)
            } else if !callID.isEmpty && (name == "apply_patch" || name == "apply_patch_freeform") && !input.isEmpty {
                let changes = CodexHistoryRows.applyPatchChanges(input)
                if !changes.isEmpty { pendingPatches[callID] = PendingPatch(timestamp: ts, changes: changes) }
            } else {
                if !callID.isEmpty { openCalls.insert(callID) }
                appendTool(payload, ts)
            }
        case "custom_tool_call_output":
            openCalls.remove(callID)
            if let start = execCalls.removeValue(forKey: callID) {
                finishExec(callID, start: start, payload, ts)
            } else {
                consumeCustomOutput(payload, callID, ts)
            }
        case "function_call_output":
            openCalls.remove(callID)
            if hiddenCalls.remove(callID) != nil { return }
            if !callID.isEmpty, let pending = pendingCommands.removeValue(forKey: callID) {
                completeCommand(pending, payload)
            } else {
                appendTool(payload, ts)
            }
        case "reasoning":
            if let text = CodexHistoryRows.reasoningSummary(payload) {
                items.append(CodexHistoryItem(role: "thinking", content: text, timestamp: ts))
            }
        default:
            appendTool(payload, ts)
        }
    }

    /// A code-mode `exec` call: its shell commands show as running until their native records arrive.
    private mutating func startExec(_ callID: String, _ input: String, _ ts: String) {
        if !callID.isEmpty {
            execCalls[callID] = items.count
            execInputs[callID] = input
        }
        for cmd in CodexCodeMode.shellCommands(input) {
            execCommands.append((items.count, cmd))
            var row = CodexHistoryItem(role: "command", content: "$ \(cmd)", timestamp: ts)
            row.running = chatMarkers
            items.append(row)
        }
    }

    /// An `exec` call's output: commands it started that never reported are done, and a script
    /// that did nothing the rollout records natively shows its output as one row.
    private mutating func finishExec(_ callID: String, start: Int, _ payload: JSONValue, _ ts: String) {
        let output = CodexCodeMode.scriptOutput(payload["output"] ?? .null)
        let input = execInputs.removeValue(forKey: callID) ?? ""
        if output.running { return }
        let mine = execCommands.filter { $0.index >= start }
        execCommands.removeAll { $0.index >= start }
        for pending in mine where pending.index < items.count { items[pending.index].running = false }
        // Older codex-cli versions record no CommandExecution: a lone command takes the script's output.
        if mine.count == 1, let index = mine.first?.index, index < items.count, let result = CodexCodeMode.commandResult(output.text) {
            items[index].content = "$ \(mine[0].cmd)" + (result.output.isEmpty ? "" : "\n\(result.output)") + "\n[exit: \(result.exitCode)]"
            if result.exitCode != 0 { items[index].toolError = true }
        }
        // Rows other than this script's own command rows came from native records, which say it all.
        guard items[min(start, items.count)...].allSatisfy({ $0.role == "command" }) else { return }
        // codex-cli 0.166 records no FileChange for `tools.apply_patch`: the script holds the patch.
        let changes = output.failed || nativePatchIDs.contains(callID) ? [] : CodexCodeMode.patches(input).flatMap(CodexHistoryRows.applyPatchChanges)
        if !changes.isEmpty {
            if !callID.isEmpty { directPatchIDs.insert(callID) }
            insert(changes.map { CodexHistoryItem.file($0, ts, editID: callID, native: false) }, at: start)
            return
        }
        guard items.count == start, let row = CodexCodeMode.scriptItem(input, output, ts) else { return }
        items.append(row)
    }

    /// Rows placed before a script's command rows (its patch came first), moving the indices kept for later rows.
    private mutating func insert(_ rows: [CodexHistoryItem], at start: Int) {
        let at = min(start, items.count)
        items.insert(contentsOf: rows, at: at)
        let shift = { (index: Int) in index >= at ? index + rows.count : index }
        pendingCommands = pendingCommands.mapValues { PendingCommand(index: shift($0.index), cmd: $0.cmd) }
        execCalls = execCalls.mapValues(shift)
        execCommands = execCommands.map { (shift($0.index), $0.cmd) }
    }

    private mutating func consumeCustomOutput(_ payload: JSONValue, _ callID: String, _ ts: String) {
        // Already counted from this call's native patch event.
        if !callID.isEmpty && patchApplyEndIDs.contains(callID) {
            pendingPatches[callID] = nil
            return
        }
        if pendingPatches[callID] != nil && nativePatchIDs.contains(callID) {
            pendingPatches[callID] = nil
            return
        }
        guard !callID.isEmpty, let pending = pendingPatches.removeValue(forKey: callID) else {
            appendTool(payload, ts)
            return
        }
        let output = payload["output"]?.string ?? ""
        // Only a confirmed exit 0 turns a direct patch into file rows.
        guard JSONValue.parse(output)?.pointer("/metadata/exit_code")?.int == 0 else {
            appendTool(payload, ts)
            return
        }
        let stamp = ts.isEmpty ? pending.timestamp : ts
        directPatchIDs.insert(callID)
        items += pending.changes.map { CodexHistoryItem.file($0, stamp, editID: callID, native: false) }
    }

    private mutating func completeCommand(_ pending: PendingCommand, _ payload: JSONValue) {
        let raw = payload["output"]?.string ?? ""
        var text = raw
        var exitCode: Int?
        if let parsed = JSONValue.parse(raw) {
            text = parsed["output"]?.string ?? raw
            exitCode = (parsed["exit_code"] ?? parsed.pointer("/metadata/exit_code"))?.int
        }
        guard pending.index < items.count else { return }
        let trimmed = text.rustTrimmed
        let status = exitCode.map { "\n[exit: \($0)]" } ?? ""
        items[pending.index].content = trimmed.isEmpty ? "$ \(pending.cmd)\(status)" : "$ \(pending.cmd)\n\(trimmed)\(status)"
    }

    private mutating func appendTool(_ payload: JSONValue, _ ts: String) {
        if let item = CodexHistoryRows.toolItem(payload, ts) { items.append(item) }
    }

    /// Drops consecutive duplicates (the same prompt arrives as `event_msg`
    /// and `response_item`); tool and file rows keep their call identity.
    static func deduplicated(_ items: [CodexHistoryItem]) -> [CodexHistoryItem] {
        items.reduce(into: []) { out, item in
            if let last = out.last, isDuplicate(item, after: last) { return }
            out.append(item)
        }
    }

    static func isDuplicate(_ item: CodexHistoryItem, after last: CodexHistoryItem) -> Bool {
        item.role != "file" && item.role != "tool" && item.role != "command" && last.role == item.role && last.content == item.content
    }
}
