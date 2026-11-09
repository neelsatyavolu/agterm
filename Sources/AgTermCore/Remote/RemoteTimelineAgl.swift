import Foundation

/// agl session files (`~/.agl/sessions/<cwd>/<stamp>-<id>.jsonl`) → timeline, a line at a time.
/// Lines carry `type` session / user / assistant / tool_call / tool_result / error / model and a
/// `ts` in milliseconds. A tool call follows the assistant line it came with; its result follows it.
struct AglTimeline {
    private(set) var entries: [MobileTimelineEntry] = []
    /// The model in use: the session's, or the latest `/model` switch.
    private(set) var model: String?
    private var toolIndex: [String: Int] = [:]
    private var line = 0

    static func entries(session: String) -> [MobileTimelineEntry] {
        var timeline = AglTimeline()
        timeline.feed(completeLinesOf: session)
        return timeline.entries
    }

    static func modelLabel(session: String) -> String? {
        var timeline = AglTimeline()
        timeline.feed(completeLinesOf: session)
        return timeline.model
    }

    private mutating func feed(completeLinesOf text: String) {
        let bytes = text.utf8
        guard let lastNewline = bytes.lastIndex(of: 0x0A) else { return }
        rustLines(String(decoding: bytes[...lastNewline], as: UTF8.self)).forEach { feed($0) }
    }

    /// One line, without its newline. Every line counts toward ids, so they stay stable as the file grows.
    mutating func feed(_ text: String) {
        defer { line += 1 }
        let trimmed = text.rustTrimmed
        guard !trimmed.isEmpty, let v = JSONValue.parse(trimmed) else { return }
        let id = "agl-\(line)", ts = v["ts"]?.int ?? 0
        switch v["type"]?.string {
        case "session": model = v["model"]?.string ?? model
        case "model": model = v["name"]?.string ?? model
        case "user":
            if let text = v["text"]?.string, !text.isBlank { entries.append(MobileTimelineEntry(id: id, kind: "user", text: text, ts: ts)) }
        case "assistant":
            if let r = v["reasoning"]?.string, !r.isBlank {
                entries.append(MobileTimelineEntry(id: id + "-r", kind: "thinking", text: r.rustTrimmed, ts: ts))
            }
            if let t = v["text"]?.string, !t.isBlank {
                entries.append(MobileTimelineEntry(id: id, kind: "assistant", text: t.rustTrimmed, ts: ts))
            }
        case "tool_call": addCall(v, id: id, ts: ts)
        case "tool_result": addResult(v, ts: ts)
        case "error":
            if let message = v["message"]?.string {
                entries.append(MobileTimelineEntry(id: id, kind: "assistant", text: "agl stopped: " + message, ts: ts))
            }
        default: break
        }
    }

    private mutating func addCall(_ v: JSONValue, id: String, ts: Int) {
        let name = v["name"]?.string ?? "tool"
        let input = Self.normalized(v["arguments"] ?? .object([:]))
        let (subject, detail) = TimelineTools.subjectDetail(name, input)
        let entry = MobileTimelineEntry(id: id, kind: "tool", lead: TimelineTools.lead(name), subject: subject, detail: detail,
                                        status: "running", requestId: v["id"]?.string, toolName: name, ts: ts)
        if let callID = v["id"]?.string, !callID.isEmpty { toolIndex[callID] = entries.count }
        entries.append(TimelineTools.filled(entry, input: input))
    }

    /// agl's `edit` takes `path`, `old` and `new`; the shared tool rows read Claude's names.
    private static func normalized(_ input: JSONValue) -> JSONValue {
        guard var fields = input.object else { return input }
        for (from, to) in [("path", "file_path"), ("old", "old_string"), ("new", "new_string")] where fields[to] == nil {
            if let value = fields[from] { fields[to] = value }
        }
        return .object(fields)
    }

    private mutating func addResult(_ v: JSONValue, ts: Int) {
        guard let callID = v["id"]?.string, let index = toolIndex[callID] else { return }
        var entry = TimelineTools.applyingResult(entries[index], content: v["output"]?.string ?? "", isError: v["ok"]?.bool == false)
        entry.endTs = ts
        entries[index] = entry
    }
}

/// Where a running agl writes: `~/.agl/run/<pid>.json` names its session file.
public enum AglSessions {
    public static var home: URL {
        ProcessInfo.processInfo.environment["AGL_HOME"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".agl")
    }

    /// The session file agl process `pid` is writing, if it's running.
    public static func running(pid: Int32, home: URL = home) -> URL? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("run/\(pid).json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["session"] as? String, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
}
