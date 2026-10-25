import Foundation

/// What one Codex rollout yields: its own identity, lineage and usage events.
public struct CodexParse: Equatable, Sendable {
    public var sessionID: String
    public var forkedFromID: String?
    public var events: [UsageEvent]
}

/// Reads Codex rollouts (`~/.codex/sessions/YYYY/MM/DD/rollout-*-{session}.jsonl`).
///
/// `total_token_usage` is cumulative, so per-turn `last_token_usage` is preferred
/// and the running total is differenced, never summed. Codex is the provider that
/// reports reasoning tokens. Per-response `token_usage_record` rows, where present,
/// are the accounting authority for their turn.
public enum CodexTranscript {
    /// Parses one rollout's text into usage events.
    public static func parse(lines: String, sessionID: String, prices: PriceCatalog = .builtIn) -> [UsageEvent] {
        parseDetailed(lines: lines, sessionID: sessionID, prices: prices).events
    }

    /// Like `parse`, also returning the session ID and fork parent from the header.
    public static func parseDetailed(lines: String, sessionID: String, prices: PriceCatalog = .builtIn) -> CodexParse {
        var parser = CodexRolloutParser(sessionID: sessionID, prices: prices)
        for raw in rustLines(lines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let v = JSONValue.parse(line) else { continue }
            parser.consume(v)
        }
        return parser.finish()
    }

    /// `payload.originator` of a `session_meta` header line: the client that
    /// created the session (`codex-tui`, `codex_exec`, `agmux`, …). Nil otherwise.
    public static func originator(header: String) -> String? {
        guard let v = JSONValue.parse(header), v["type"]?.string == "session_meta" else { return nil }
        return v.pointer("/payload/originator")?.string
    }

    /// Rollout filenames end in the session UUID: `rollout-<ts>-<uuid>.jsonl`.
    public static func sessionID(fromPath path: String) -> String {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count >= 5 ? parts.suffix(5).joined(separator: "-") : stem
    }
}

/// Line-by-line state for one rollout. Tool calls sit on their own lines ahead of
/// the usage line that closes the turn, so they are held until it arrives.
private struct CodexRolloutParser {
    let prices: PriceCatalog
    var out: [UsageEvent] = []
    var eventTurns: [(turn: String, native: Bool)] = []
    var cwd: String?
    var model = ""
    var parsedID: String
    var headerSeen = false
    var forkedFromID: String?
    var subagent = false
    var counter = CodexSessionCounter()
    var boundary = CodexHistoryBoundary()
    var pendingTools = ToolTally()
    var turnID = ""
    var nativeTurns: Set<String> = []
    var nativeResponses: Set<String> = []
    /// Per turn: measured response usage, and the largest turn total reported.
    var nativeCoverage: [String: (measured: [Int], reported: [Int])] = [:]
    var toolsByTurn: [String: ToolTally] = [:]
    var eligibleToolTurns: Set<String> = []
    var firstNativeAt: Date?
    var seenPatches: Set<String> = []

    init(sessionID: String, prices: PriceCatalog) {
        self.parsedID = sessionID
        self.prices = prices
    }

    mutating func consume(_ v: JSONValue) {
        let type = v["type"]?.string
        if type == "session_meta" {
            // Forks can contain copied ancestor headers; only the first describes this rollout.
            if headerSeen { return }
            headerSeen = v["payload"]?.isObject ?? false
        }
        if let c = (v.pointer("/payload/cwd") ?? v["cwd"])?.string, !c.isEmpty { cwd = c }
        if let m = (v.pointer("/payload/model") ?? v.pointer("/payload/turn_context/model") ?? v["model"])?.string,
           !m.isEmpty { model = m }
        if type == "session_meta", let payload = v["payload"] { readHeader(payload) }
        if type == "turn_context" { turnID = v.pointer("/payload/turn_id")?.string ?? "" }

        let native = type == "token_usage_record"
        // A response record belongs to the thread that billed it.
        if native, v.pointer("/payload/thread_id")?.string != parsedID { return }
        let copied = !native && boundary.isCopied(v)
        recordTools(v, copied: copied)

        let info = v.pointer("/payload/info") ?? v["info"]
        let lastUsage = (native ? v.pointer("/payload/usage") : info?["last_token_usage"]).flatMap { $0.isObject ? $0 : nil }
        let totalUsage = native ? nil : info?["total_token_usage"].flatMap { $0.isObject ? $0 : nil }
        let last = lastUsage.map { CodexUsageFields($0) }
        let total = totalUsage.map { CodexUsageFields($0) }
        guard last != nil || total != nil, let at = v["timestamp"]?.string.flatMap(TeamsTime.parse) else { return }

        let eventTurn = native ? (v.pointer("/payload/turn_id")?.string ?? "") : turnID
        let usage: CodexUsageFields
        if native {
            guard let response = v.pointer("/payload/response_id")?.string, !response.isEmpty,
                  nativeResponses.insert(response).inserted, let last else { return }
            recordNativeCoverage(turn: eventTurn, usage: last, reported: CodexUsageFields(v.pointer("/payload/turn_token_usage")), at: at)
            usage = last
        } else {
            guard let delta = counter.apply(last: last, total: total) else { return }
            usage = delta
        }
        // Copied history is consumed as the baseline above but not billed again.
        if copied {
            pendingTools = ToolTally()
            return
        }
        appendEvent(at: at, usage: usage, last: last, lastUsage: lastUsage, turn: eventTurn, native: native)
    }

    mutating func finish() -> CodexParse {
        var kept: [UsageEvent] = []
        for (event, origin) in zip(out, eventTurns) {
            // Legacy token_count mirrors of a turn with response records are not added again.
            if !origin.native, nativeTurns.contains(origin.turn)
                || (origin.turn.isEmpty && firstNativeAt.map { event.at >= $0 } == true) { continue }
            var e = event
            if origin.native, let coverage = nativeCoverage[origin.turn],
               zip(coverage.measured, coverage.reported).contains(where: { $0 < $1 }) {
                e.costIncomplete = true // Missing responses cannot be reconstructed or priced.
            }
            if let tools = toolsByTurn.removeValue(forKey: origin.turn) {
                e.tools = e.tools.adding(tools)
                e.toolCalls = e.tools.calls
            }
            kept.append(e)
        }
        for (turn, tools) in toolsByTurn where eligibleToolTurns.contains(turn) {
            pendingTools = pendingTools.adding(tools)
        }
        // Tool calls never closed by a usage line still did work: credit the last event.
        if !pendingTools.isEmpty, let last = kept.indices.last {
            kept[last].tools = kept[last].tools.adding(pendingTools)
            kept[last].toolCalls = kept[last].tools.calls
        }
        if let cwd {
            let key = TeamsLabels.projectKey(workDir: cwd, private: false)
            for i in kept.indices where kept[i].projectKey.isEmpty { kept[i].projectKey = key }
        }
        return CodexParse(sessionID: parsedID, forkedFromID: forkedFromID, events: kept)
    }

    // MARK: - Steps

    private mutating func readHeader(_ payload: JSONValue) {
        if let id = (payload["id"] ?? payload["session_id"])?.string, !id.isEmpty { parsedID = id }
        if forkedFromID == nil, let fork = (payload["forked_from_id"] ?? payload["forkedFromId"])?.string, !fork.isEmpty {
            forkedFromID = fork
        }
        // Spawned subagents and auto-review threads: `"source": {"subagent": …}`.
        subagent = payload.pointer("/source/subagent") != nil
        boundary = CodexHistoryBoundary(meta: payload)
    }

    private mutating func recordTools(_ v: JSONValue, copied: Bool) {
        // The same edit can be recorded twice (a patch result and its item).
        var signal = Self.toolSignal(v)
        if let id = Self.patchID(v), !seenPatches.insert(id).inserted { signal = ToolTally() }
        if !turnID.isEmpty {
            if !copied { eligibleToolTurns.insert(turnID) }
            toolsByTurn[turnID] = (toolsByTurn[turnID] ?? ToolTally()).adding(signal)
        } else if !copied {
            pendingTools = pendingTools.adding(signal)
        }
    }

    private mutating func recordNativeCoverage(turn: String, usage: CodexUsageFields, reported: CodexUsageFields, at: Date) {
        nativeTurns.insert(turn)
        let zero = Array(repeating: 0, count: 5)
        let current = nativeCoverage[turn] ?? (measured: zero, reported: zero)
        nativeCoverage[turn] = (measured: zip(current.measured, usage.asArray).map { $0 + $1 },
                                reported: zip(current.reported, reported.asArray).map { max($0, $1) })
        firstNativeAt = min(firstNativeAt ?? at, at)
    }

    private mutating func appendEvent(at: Date, usage t: CodexUsageFields, last: CodexUsageFields?, lastUsage: JSONValue?,
                                      turn: String, native: Bool) {
        let tools = turn.isEmpty ? pendingTools : ToolTally()
        if turn.isEmpty { pendingTools = ToolTally() }
        let split = t.splitInput
        // A missing write counter is not an explicit zero on write-priced models.
        let writeReported = (lastUsage?["cache_write_input_tokens"]?.int).map { $0 >= 0 } ?? false
        let cost = prices.cost(model: model, TokenCostSpec(pureInput: split.uncached, pureOutput: t.output,
                                                           cacheRead: split.cached, cacheWrite: split.cacheWrite))
        // A cumulative-only delta may cover several requests, so request-tier
        // pricing cannot be reconstructed from it.
        let incomplete = model.isEmpty || last == nil || (try? cost.get()) == nil || last.map { $0 != t } == true
            || (prices.requiresCacheWriteUsage(model: model) && !writeReported)
        var e = UsageEvent(at: at, provider: "Codex", model: model,
                           projectKey: TeamsLabels.projectKey(workDir: cwd ?? "", private: false), sessionID: parsedID)
        (e.tokensIn, e.tokensOut, e.cacheRead, e.cacheWrite, e.reasoning) =
            (split.uncached, t.output, split.cached, split.cacheWrite, t.reasoning)
        e.costUSD = incomplete ? 0 : ((try? cost.get()) ?? 0)
        e.costIncomplete = incomplete
        e.isTurn = true
        e.tools = tools
        e.toolCalls = tools.calls
        e.subagent = subagent
        out.append(e)
        eventTurns.append((turn, native))
    }

    // MARK: - Tool signals

    /// Tool activity on one rollout line. Codex has no general outcome flag (a
    /// command's output reads the same whether it exited 0 or 1), so only patch
    /// applies count toward `measured`.
    static func toolSignal(_ v: JSONValue) -> ToolTally {
        guard let payload = v["payload"] else { return ToolTally() }
        switch payload["type"]?.string {
        case "function_call", "custom_tool_call", "local_shell_call":
            return ToolTally().counting(TeamsTools.classify(payload["name"]?.string ?? "local_shell_call"))
        case "patch_apply_end":
            return patchSignal(ok: payload["success"]?.bool != false, changes: payload["changes"])
        case "item_completed":
            // Current Codex records edits only as completed FileChange items.
            let item = payload["item"]
            guard item?["type"]?.string == "FileChange" else { return ToolTally() }
            switch item?["status"]?.string {
            case "completed": return patchSignal(ok: true, changes: item?["changes"])
            case "failed", "declined": return patchSignal(ok: false, changes: nil)
            default: return ToolTally()
            }
        default:
            return ToolTally()
        }
    }

    private static func patchSignal(ok: Bool, changes: JSONValue?) -> ToolTally {
        var t = ToolTally(measured: 1)
        // A patch that failed changed nothing; don't credit its lines.
        guard ok else { return ToolTally(errors: 1, measured: 1) }
        for change in (changes?.object ?? [:]).values {
            t.filesChanged += 1
            let content = change["content"]?.string
            let diff = TeamsTools.unifiedDiffLines(change["unified_diff"]?.string ?? "")
            switch change["type"]?.string {
            case "add":
                t.linesAdded += TeamsTools.lineCount(content ?? "")
            case "delete":
                if let content, !content.isEmpty { t.linesRemoved += TeamsTools.lineCount(content) } else { t.linesRemoved += diff.removed }
            default:
                (t.linesAdded, t.linesRemoved) = (t.linesAdded + diff.added, t.linesRemoved + diff.removed)
            }
        }
        return t
    }

    /// Call ID of an edit record: `patch_apply_end.call_id` or the FileChange item ID.
    static func patchID(_ v: JSONValue) -> String? {
        guard let payload = v["payload"] else { return nil }
        let id: JSONValue?
        switch payload["type"]?.string {
        case "patch_apply_end": id = payload["call_id"]
        case "item_completed" where payload.pointer("/item/type")?.string == "FileChange": id = payload.pointer("/item/id")
        default: id = nil
        }
        guard let text = id?.string, !text.isEmpty else { return nil }
        return text
    }
}
