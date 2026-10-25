import Foundation

/// An OpenAI/Codex usage object. `input` is the full prompt and includes cached
/// reads (and writes); `reasoning` is a subset of `output`.
struct CodexUsageFields: Equatable {
    var input = 0
    var cached = 0
    var cacheWrite = 0
    var output = 0
    var reasoning = 0

    /// Reads the usage keys; cached is the larger of the two cache aliases.
    init(_ u: JSONValue?) {
        func n(_ key: String) -> Int { max(u?[key]?.int ?? 0, 0) }
        input = n("input_tokens")
        cached = max(n("cached_input_tokens"), n("cache_read_input_tokens"))
        cacheWrite = n("cache_write_input_tokens")
        output = n("output_tokens")
        reasoning = min(n("reasoning_output_tokens"), output)
    }

    init(input: Int = 0, cached: Int = 0, cacheWrite: Int = 0, output: Int = 0, reasoning: Int = 0) {
        (self.input, self.cached, self.cacheWrite, self.output, self.reasoning) = (input, cached, cacheWrite, output, reasoning)
    }

    /// `(uncached, cached, cacheWrite)`, clamped so tokens are never invented.
    var splitInput: (uncached: Int, cached: Int, cacheWrite: Int) {
        let total = max(input, 0)
        let cached = min(max(self.cached, 0), total)
        let remaining = total - cached
        let write = min(max(cacheWrite, 0), remaining)
        return (remaining - write, cached, write)
    }

    var isEmpty: Bool { input + output + cached + cacheWrite + reasoning == 0 }

    var asArray: [Int] { [input, cached, cacheWrite, output, reasoning] }

    func minus(_ p: CodexUsageFields) -> CodexUsageFields {
        CodexUsageFields(input: max(input - p.input, 0), cached: max(cached - p.cached, 0),
                         cacheWrite: max(cacheWrite - p.cacheWrite, 0), output: max(output - p.output, 0),
                         reasoning: max(reasoning - p.reasoning, 0))
    }

    func plus(_ o: CodexUsageFields) -> CodexUsageFields {
        CodexUsageFields(input: input + o.input, cached: cached + o.cached, cacheWrite: cacheWrite + o.cacheWrite,
                         output: output + o.output, reasoning: reasoning + o.reasoning)
    }

    func componentMin(_ o: CodexUsageFields) -> CodexUsageFields {
        CodexUsageFields(input: min(input, o.input), cached: min(cached, o.cached), cacheWrite: min(cacheWrite, o.cacheWrite),
                         output: min(output, o.output), reasoning: min(reasoning, o.reasoning))
    }

    func isBelow(_ p: CodexUsageFields) -> Bool {
        input < p.input || cached < p.cached || output < p.output
    }
}

/// Within-file accounting of Codex's cumulative `total_token_usage`.
///
/// When both per-turn and cumulative usage exist, a response is capped at the
/// cumulative growth. An explicit zero total starts a fresh segment; repeated
/// totals are not counted twice.
struct CodexSessionCounter {
    private static let seenLimit = 64
    private var counted = CodexUsageFields()
    private var watermark: CodexUsageFields?
    private var seen: [CodexUsageFields] = []

    /// The usage this line adds, or nil when it adds nothing.
    mutating func apply(last: CodexUsageFields?, total: CodexUsageFields?) -> CodexUsageFields? {
        let before = counted
        if let total {
            // A repeated zero is still a reset; rebase before deduplication.
            if total.isEmpty {
                watermark = total
                seen.removeAll()
                return nil
            }
            if seen.contains(total) { return nil }
            if let previous = watermark, total.isBelow(previous) {
                remember(total)
                if let last { counted = counted.plus(last) }
                watermark = total
                return delta(since: before)
            }
            let growth = total.minus(watermark ?? CodexUsageFields())
            counted = counted.plus(last.map { $0.componentMin(growth) } ?? growth)
            watermark = total
            remember(total)
            return delta(since: before)
        }
        if let last {
            counted = counted.plus(last)
            watermark = counted
            return delta(since: before)
        }
        return nil
    }

    private func delta(since before: CodexUsageFields) -> CodexUsageFields? {
        let d = counted.minus(before)
        return d.isEmpty ? nil : d
    }

    private mutating func remember(_ total: CodexUsageFields) {
        guard !seen.contains(total) else { return }
        seen.append(total)
        if seen.count > Self.seenLimit { seen.removeFirst() }
    }
}

/// Where a forked or subagent rollout's own history begins. Copied parent rows
/// before it are consumed as a baseline but never billed again. Paginated forks
/// can retimestamp inherited rows, so the ordinal wins when both exist.
struct CodexHistoryBoundary {
    var createdAt: Date?
    var ownOrdinal: Int?

    init() {}

    init(meta: JSONValue) {
        let forkID = (meta["forked_from_id"] ?? meta["forkedFromId"])?.string
        let isFork = forkID.map { !$0.isEmpty } ?? false
        createdAt = isFork ? meta["timestamp"]?.string.flatMap(TeamsTime.parse) : nil
        ownOrdinal = meta["subagent_history_start_ordinal"]?.unsigned
            ?? (isFork ? meta["forked_from_ordinal_exclusive"]?.unsigned : nil)
    }

    func isCopied(_ row: JSONValue) -> Bool {
        if let ordinal = row["ordinal"]?.unsigned, let start = ownOrdinal { return ordinal < start }
        guard let created = createdAt, let at = TeamsTime.eventTimestamp(row) else { return false }
        return at < created
    }
}
