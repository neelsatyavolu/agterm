import Foundation

/// One row of an Antigravity conversation's `steps` table
/// (`~/.gemini/antigravity-cli/conversations/<id>.db`): its index, type, status and payload.
public struct AgyStep: Equatable, Sendable {
    public let index: Int
    public let type: Int
    public let status: Int
    public let payload: Data

    public init(index: Int, type: Int, status: Int, payload: Data) {
        self.index = index
        self.type = type
        self.status = status
        self.payload = payload
    }

    /// A step that can still change: reads keep re-reading from the first one of these.
    public var isSettled: Bool { AgyTimeline.settled.contains(status) }
}

/// Antigravity CLI (`agy`) steps → timeline. The payloads are protobuf without a published
/// schema; field numbers were read off real conversations (agy 1.5), the step type and status
/// numbers off the enums in its binary (`CORTEX_STEP_TYPE_*`, `CORTEX_STEP_STATUS_*`).
/// Every step carries its metadata in field 5 (5.1 is when it was created), plus one field of
/// its own:
/// - user input (14): 19.2 is the message;
/// - planner response (15): 20.3 its thinking, 20.1 its reply, each 20.7 a tool call
///   (1 id, 2 tool name, 3 JSON arguments);
/// - a tool run (132, and the older typed steps): 5.4 is the call, 140.2.1 the result's text
///   (140.2.3.10.3 a command's exit code and output), 31.2 an error.
public struct AgyTimeline {
    enum StepType {
        static let user = 14
        static let reply = 15
        static let errorMessage = 17
    }

    enum Status {
        static let done = 3
        static let canceled = 6
        static let error = 7
        static let queued = 11
        static let interrupted = 12
    }

    /// Statuses a step doesn't leave: done, cleared, canceled, error, interrupted (and invalid).
    static let settled: Set = [3, 4, 5, 6, 7, 12]

    public private(set) var entries: [MobileTimelineEntry] = []
    private var callIndex: [String: Int] = [:]

    public init() {}

    public static func entries(_ steps: [AgyStep]) -> [MobileTimelineEntry] {
        var timeline = AgyTimeline()
        steps.forEach { timeline.add($0) }
        return timeline.entries
    }

    public mutating func add(_ step: AgyStep) {
        let message = ProtoFields(step.payload)
        let ts = Self.timestamp(message.nested(5, 1))
        switch step.type {
        case StepType.user:
            guard let text = message.nested(19)?.string(2), !text.isBlank else { return }
            entries.append(MobileTimelineEntry(id: "agy-\(step.index)", kind: "user", text: text,
                                               state: step.status == Status.queued ? "queued" : nil, ts: ts))
        case StepType.reply:
            addReply(message.nested(20), step: step, ts: ts)
        case StepType.errorMessage:
            guard let text = Self.longestString(in: message, skipping: [5]) else { return }
            entries.append(MobileTimelineEntry(id: "agy-\(step.index)", kind: "assistant", text: "Antigravity stopped: " + text, ts: ts))
        default:
            if let call = message.nested(5, 4) { addRun(call, message: message, step: step, ts: ts) }
        }
    }

    private mutating func addReply(_ reply: ProtoFields?, step: AgyStep, ts: Int) {
        guard let reply else { return }
        let id = "agy-\(step.index)"
        if let thinking = reply.string(3)?.rustTrimmed, !thinking.isEmpty {
            entries.append(MobileTimelineEntry(id: id + "-t", kind: "thinking", text: thinking, ts: ts))
        }
        if let text = (reply.string(1) ?? reply.string(8))?.rustTrimmed, !text.isEmpty {
            entries.append(MobileTimelineEntry(id: id, kind: "assistant", text: text, ts: ts))
        }
        // The calls show as running until the step that runs each one arrives.
        for call in reply.messages(7) {
            guard let callID = call.string(1), callIndex[callID] == nil else { continue }
            callIndex[callID] = entries.count
            entries.append(Self.toolEntry(call, id: "agy-" + callID, status: "running", ts: ts))
        }
    }

    private mutating func addRun(_ call: ProtoFields, message: ProtoFields, step: AgyStep, ts: Int) {
        let callID = call.string(1) ?? "step\(step.index)"
        var entry = Self.toolEntry(call, id: "agy-" + callID, status: "running", ts: ts)
        let result = message.nested(140, 2)
        switch step.status {
        case Status.done:
            let command = result?.nested(3, 10, 3)
            let exit = command?.int(3) ?? 0
            let output = command?.string(4) ?? result?.string(1).map(Self.withoutHeader) ?? ""
            entry = TimelineTools.applyingResult(entry, content: output, isError: exit != 0)
        case Status.error, Status.canceled, Status.interrupted:
            let reason = message.nested(31)?.string(2).flatMap { $0.isBlank ? nil : $0 }
                ?? (step.status == Status.error ? "Failed" : "Canceled")
            entry = TimelineTools.applyingResult(entry, content: reason, isError: true)
        default:
            break
        }
        if entry.status != "running" { entry.endTs = Self.time(message.nested(5, 8)) ?? ts }
        if let index = callIndex[callID] {
            entry.ts = entries[index].ts
            entries[index] = entry
        } else {
            callIndex[callID] = entries.count
            entries.append(entry)
        }
    }

    // MARK: Tools

    /// A call as a tool row. agy's tools are renamed to the Claude Code tools they match, with
    /// Claude's argument names, so the shared rows (reads, searches, edits with diffs, commands)
    /// work unchanged.
    static func toolEntry(_ call: ProtoFields, id: String, status: String, ts: Int) -> MobileTimelineEntry {
        let raw = call.string(2) ?? "tool"
        let args = call.string(3).flatMap(JSONValue.parse) ?? .object([:])
        let (name, input) = normalized(raw, args)
        let (subject, detail) = TimelineTools.subjectDetail(name, input)
        let entry = MobileTimelineEntry(id: id, kind: "tool", lead: TimelineTools.lead(name), subject: subject, detail: detail,
                                        status: status, requestId: call.string(1), toolName: name, ts: ts)
        return TimelineTools.filled(entry, input: input)
    }

    static func normalized(_ name: String, _ args: JSONValue) -> (String, JSONValue) {
        let summary = args["toolSummary"]?.string
        func pick(_ keys: [String]) -> JSONValue? { args.firstPresent(keys) }
        func object(_ fields: [String: JSONValue?]) -> JSONValue { .object(fields.compactMapValues { $0 }) }
        switch name {
        case "view_file", "read_file":
            return ("Read", object(["file_path": pick(["AbsolutePath", "Path"])]))
        case "list_dir":
            return ("list_dir", object(["path": pick(["DirectoryPath"])]))
        case "grep_search":
            return ("Grep", object(["pattern": pick(["Query"]), "path": pick(["SearchPath"])]))
        case "find_by_name":
            return ("Glob", object(["pattern": pick(["Pattern"]), "path": pick(["SearchDirectory"])]))
        case "run_command":
            return ("Bash", object(["command": pick(["CommandLine"]), "description": summary.map(JSONValue.string)]))
        case "replace_file_content":
            return ("Edit", object(["file_path": pick(["TargetFile"]), "old_string": pick(["TargetContent"]),
                                    "new_string": pick(["ReplacementContent"])]))
        case "multi_replace_file_content":
            let chunks = pick(["ReplacementChunks"]).flatMap { $0.array ?? $0.string.flatMap(JSONValue.parse)?.array } ?? []
            let edits = chunks.map { chunk in
                object(["old_string": chunk.firstPresent(["TargetContent"]), "new_string": chunk.firstPresent(["ReplacementContent"])])
            }
            return ("MultiEdit", object(["file_path": pick(["TargetFile"]), "edits": .array(edits)]))
        case "write_to_file", "write_file":
            return ("Write", object(["file_path": pick(["TargetFile", "Path"]), "content": pick(["CodeContent", "Content"])]))
        case "search_web":
            return ("WebSearch", object(["query": pick(["query", "Query"])]))
        case "read_url_content":
            return ("WebFetch", object(["query": pick(["Url"])]))
        case "invoke_subagent":
            let first = pick(["Subagents"]).flatMap { $0.array?.first }
            return ("Task", object(["description": summary.map(JSONValue.string), "prompt": first?.firstPresent(["Prompt"]),
                                    "subagent_type": first?.firstPresent(["Role", "Name"])]))
        default:
            return (name, object(["description": summary.map(JSONValue.string)]))
        }
    }

    // MARK: Helpers

    /// `{1: seconds, 2: nanoseconds}` as milliseconds; 0 when missing.
    static func timestamp(_ time: ProtoFields?) -> Int {
        guard let seconds = time?.int(1) else { return 0 }
        return seconds * 1000 + (time?.int(2) ?? 0) / 1_000_000
    }

    static func time(_ time: ProtoFields?) -> Int? {
        guard let seconds = time?.int(1) else { return nil }
        return seconds * 1000 + (time?.int(2) ?? 0) / 1_000_000
    }

    /// A tool result's text without the `Created At:` / `Completed At:` lines agy puts first.
    static func withoutHeader(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let first = lines.first, first.hasPrefix("Created At:") || first.hasPrefix("Completed At:") { lines.removeFirst() }
        return lines.joined(separator: "\n").rustTrimmed
    }

    /// The longest readable string anywhere in `message` outside the `skipping` fields.
    static func longestString(in message: ProtoFields, skipping: Set<Int> = [], depth: Int = 4) -> String? {
        var best: String?
        for (number, value) in message.fields where !skipping.contains(number) {
            guard case .bytes(let data) = value else { continue }
            if let text = String(data: data, encoding: .utf8), text.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\n" || $0 == "\t" }),
               text.count > (best?.count ?? 0) {
                best = text
            } else if depth > 0, let inner = longestString(in: ProtoFields(data), depth: depth - 1), inner.count > (best?.count ?? 0) {
                best = inner
            }
        }
        return best
    }
}
