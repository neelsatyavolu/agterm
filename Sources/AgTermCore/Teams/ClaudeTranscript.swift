import Foundation

/// Reads Claude Code transcripts (`~/.claude/projects/{encoded_cwd}/{session}.jsonl`)
/// into usage events. Every assistant message carries `message.usage`,
/// `message.model` and its own `timestamp`. Only counters and short labels are
/// read; `cwd` is reduced to a basename and prompt or reply text is never kept.
public enum ClaudeTranscript {
    /// Parses one session file's text. `sessionID` is the file stem; `fallbackDir`
    /// is the project folder, used for the project only when no line has a `cwd`
    /// and to recognise `/subagents` transcripts.
    public static func parse(lines: String, sessionID: String, fallbackDir: String,
                             prices: PriceCatalog = .builtIn) -> [UsageEvent] {
        var out: [UsageEvent] = []
        var cwdSeen: String?
        // Tool results arrive on the user line after the assistant message that
        // issued the calls; results before the first usage line wait here.
        var pendingResults = ToolTally()
        // Streaming chunks share message.id + requestId: the last cumulative usage wins.
        var keyed: [String: Int] = [:]
        // One response's blocks span several lines; a repeated block is still one call.
        var seenToolIDs: Set<String> = []

        for raw in rustLines(lines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let v = JSONValue.parse(line) else { continue }

            if let cwd = v["cwd"]?.string, !cwd.isEmpty { cwdSeen = cwd }

            let results = toolResults(v)
            if !results.isEmpty {
                if let last = out.indices.last {
                    out[last].tools = out[last].tools.adding(results)
                } else {
                    pendingResults = pendingResults.adding(results)
                }
            }

            if let type = v["type"]?.string, type != "assistant" { continue }
            guard let usage = v.pointer("/message/usage") ?? v["usage"],
                  let at = v["timestamp"]?.string.flatMap(TeamsTime.parse) else { continue }
            let model = ((v.pointer("/message/model") ?? v["model"])?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // `<synthetic>` marks messages Claude Code makes itself; no real model.
            if model.isEmpty || model.hasPrefix("<") { continue }

            let tokensIn = count(usage, "input_tokens")
            let tokensOut = count(usage, "output_tokens")
            let cacheRead = count(usage, "cache_read_input_tokens")
            let cacheWrite = count(usage, "cache_creation_input_tokens")
            if tokensIn + tokensOut + cacheRead + cacheWrite == 0 { continue }
            let hourWrite = min(max(usage.pointer("/cache_creation/ephemeral_1h_input_tokens")?.int ?? 0, 0), cacheWrite)

            var tools = toolUses(v, seen: &seenToolIDs)
            if !pendingResults.isEmpty {
                tools = tools.adding(pendingResults)
                pendingResults = ToolTally()
            }
            let cost = prices.cost(model: model, TokenCostSpec(
                pureInput: tokensIn, pureOutput: tokensOut, cacheRead: cacheRead,
                cacheWrite: max(cacheWrite - hourWrite, 0), cacheWrite1h: hourWrite))

            var event = UsageEvent(at: at, provider: "ClaudeCode", model: model,
                                   projectKey: TeamsLabels.projectKey(workDir: cwdSeen ?? fallbackDir, private: false),
                                   sessionID: sessionID)
            (event.tokensIn, event.tokensOut, event.cacheRead, event.cacheWrite) = (tokensIn, tokensOut, cacheRead, cacheWrite)
            switch cost {
            case .success(let usd): event.costUSD = usd
            case .failure: event.costIncomplete = true
            }
            // One assistant message with usage is one agent turn.
            event.isTurn = true
            event.tools = tools
            event.toolCalls = tools.calls
            event.claudeRowKey = rowKey(v)
            event.isSidechain = v["isSidechain"]?.bool ?? false
            event.isSubagentPath = fallbackDir.contains("/subagents") || fallbackDir.contains("\\subagents")

            if let key = event.claudeRowKey {
                if let index = keyed[key] {
                    event.tools = out[index].tools.adding(event.tools)
                    event.toolCalls = event.tools.calls
                    out[index] = event
                    continue
                }
                keyed[key] = out.count
            }
            out.append(event)
        }

        // Results trailing the last usage line still belong to the session.
        if !pendingResults.isEmpty, let last = out.indices.last {
            out[last].tools = out[last].tools.adding(pendingResults)
        }
        // `cwd` often appears only after the first usage line; backfill early events.
        if let cwd = cwdSeen {
            let key = TeamsLabels.projectKey(workDir: cwd, private: false)
            for i in out.indices where out[i].projectKey.isEmpty { out[i].projectKey = key }
        }
        return out
    }

    /// Drops duplicate requests that appear in both a parent transcript and a fork,
    /// `subagents/` or sidechain file. Keeps the most complete usage, then the
    /// non-sidechain parent copy, then the earliest `(at, sessionID)`.
    public static func reconcile(_ events: [UsageEvent]) -> [UsageEvent] {
        var best: [String: Int] = [:]
        var dropped: Set<Int> = []
        for (i, candidate) in events.enumerated() {
            guard let key = candidate.claudeRowKey else { continue }
            guard let j = best[key] else {
                best[key] = i
                continue
            }
            if wins(candidate, over: events[j]) {
                dropped.insert(j)
                best[key] = i
            } else {
                dropped.insert(i)
            }
        }
        return events.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }

    /// The session ID is the file stem, which is Claude's own session UUID.
    public static func sessionID(fromPath path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    // MARK: - Helpers

    private static func wins(_ cand: UsageEvent, over exist: UsageEvent) -> Bool {
        func total(_ e: UsageEvent) -> Int { e.tokensIn + e.tokensOut + e.cacheRead + e.cacheWrite }
        if total(cand) != total(exist) { return total(cand) > total(exist) }
        if cand.isSidechain != exist.isSidechain { return exist.isSidechain }
        if cand.isSubagentPath != exist.isSubagentPath { return exist.isSubagentPath }
        if cand.at != exist.at { return cand.at < exist.at }
        return byteLess(cand.sessionID, exist.sessionID)
    }

    private static func count(_ usage: JSONValue, _ key: String) -> Int {
        max(usage[key]?.int ?? 0, 0)
    }

    private static func rowKey(_ v: JSONValue) -> String? {
        guard let id = v.pointer("/message/id")?.string, !id.isEmpty,
              let request = v["requestId"]?.string, !request.isEmpty else { return nil }
        return "\(id):\(request)"
    }

    private static func contentBlocks(_ v: JSONValue) -> [JSONValue] {
        v.pointer("/message/content")?.array ?? []
    }

    /// Classifies `tool_use` blocks and measures any edit they request. Only the
    /// tool name and the line counts of the edit strings are read.
    private static func toolUses(_ v: JSONValue, seen: inout Set<String>) -> ToolTally {
        var t = ToolTally()
        for block in contentBlocks(v) where block["type"]?.string == "tool_use" {
            if let id = block["id"]?.string, !seen.insert(id).inserted { continue }
            let name = block["name"]?.string ?? ""
            t = t.counting(TeamsTools.classify(name))
            let input = block["input"]
            switch name {
            case "Edit":
                let lines = TeamsTools.replacementLines(old: text(input, "old_string"), new: text(input, "new_string"))
                (t.linesAdded, t.linesRemoved, t.filesChanged) = (t.linesAdded + lines.added, t.linesRemoved + lines.removed, t.filesChanged + 1)
            case "Write":
                // A Write replaces the file and the log does not say what was there.
                t.linesAdded += TeamsTools.lineCount(text(input, "content"))
                t.filesChanged += 1
            case "MultiEdit":
                for edit in input?["edits"]?.array ?? [] {
                    let lines = TeamsTools.replacementLines(old: text(edit, "old_string"), new: text(edit, "new_string"))
                    (t.linesAdded, t.linesRemoved) = (t.linesAdded + lines.added, t.linesRemoved + lines.removed)
                }
                // One file per MultiEdit call, however many hunks it carries.
                t.filesChanged += 1
            default:
                break
            }
        }
        return t
    }

    /// Outcomes of `tool_result` blocks: Claude flags every one with `is_error`,
    /// so every result is measurable.
    private static func toolResults(_ v: JSONValue) -> ToolTally {
        var t = ToolTally()
        for block in contentBlocks(v) where block["type"]?.string == "tool_result" {
            t.measured += 1
            if block["is_error"]?.bool == true { t.errors += 1 }
        }
        return t
    }

    private static func text(_ value: JSONValue?, _ key: String) -> String {
        value?[key]?.string ?? ""
    }
}
