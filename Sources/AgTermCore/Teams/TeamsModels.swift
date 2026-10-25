import Foundation

/// One usage-bearing event from a provider log, stamped with the real time of
/// the work. Only counters and short labels: no prompt text, replies or paths.
public struct UsageEvent: Equatable, Sendable {
    public var at: Date
    /// `ClaudeCode` | `Codex` | … — matches the server's provider names.
    public var provider: String
    public var model: String
    /// A basename or opaque hash, never a path.
    public var projectKey: String
    /// Provider session identifier, for counting sessions and concurrency.
    public var sessionID: String
    /// Uncached input tokens.
    public var tokensIn = 0
    public var tokensOut = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    /// Reasoning tokens where the provider reports them (Codex). A subset of `tokensOut`.
    public var reasoning = 0
    public var costUSD = 0.0
    /// At least one required price or usage class was unavailable; `costUSD`
    /// then holds only the known part (often zero), never a guess.
    public var costIncomplete = false
    /// True when this event represents a completed agent turn.
    public var isTurn = false
    public var toolCalls = 0
    public var tools = ToolTally()
    /// Claude only: `message.id:requestId`, for parent/subagent dedupe.
    public var claudeRowKey: String?
    public var isSidechain = false
    /// Claude only: the transcript lives under a `subagents/` folder.
    public var isSubagentPath = false
    /// Native child thread (Codex subagent or auto-review): its usage counts, but
    /// it is not a session a person started.
    public var subagent = false

    public init(at: Date, provider: String, model: String, projectKey: String, sessionID: String) {
        self.at = at
        self.provider = provider
        self.model = model
        self.projectKey = projectKey
        self.sessionID = sessionID
    }
}

/// One hour of one provider/model/project: the wire shape the Teams service
/// accepts (`IncomingBucket` in teams-service/src/metrics.ts). Encodes to its
/// camelCase field names; `sessionsStarted` is omitted when unknown.
public struct HourlyBucket: Codable, Equatable, Sendable {
    /// `YYYY-MM-DDTHH`, UTC.
    public var hourUtc = ""
    public var provider = ""
    public var model = ""
    public var projectKey = ""
    public var tokensIn = 0
    public var tokensOut = 0
    public var tokensCacheRead = 0
    public var tokensCacheWrite = 0
    public var tokensReasoning = 0
    public var costUsd = 0.0
    /// Unknown coverage reads as incomplete: older payloads decode as `true`.
    public var costIncomplete = false
    public var activeMs = 0
    public var afterHoursMs = 0
    public var weekendMs = 0
    /// Sessions active in this hour (session-hours when summed).
    public var sessions = 0
    /// Top-level sessions whose first event falls in this bucket; nil only for
    /// batches built before the field existed, which the server stores as unknown.
    public var sessionsStarted: Int?
    public var turns = 0
    public var toolCalls = 0
    public var peakConcurrent = 0
    public var toolBash = 0
    public var toolEdit = 0
    public var toolRead = 0
    public var toolSearch = 0
    public var toolWeb = 0
    public var toolAgent = 0
    public var toolMcp = 0
    public var toolOther = 0
    /// Failed tool calls, among those whose outcome the log reports.
    public var toolErrors = 0
    /// Denominator for the error rate. Never divide errors by `toolCalls`.
    public var toolsMeasured = 0
    public var filesChanged = 0
    public var linesAdded = 0
    public var linesRemoved = 0
    /// Tool-approval prompts answered this hour. agterm does not measure them yet.
    public var approvalRequests = 0
    public var approvalWaitMs = 0
    /// Hour 0–23 and weekday (Monday = 0) in the member's own time zone.
    public var localHour = 0
    public var localDow = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case hourUtc, provider, model, projectKey, tokensIn, tokensOut, tokensCacheRead, tokensCacheWrite,
             tokensReasoning, costUsd, costIncomplete, activeMs, afterHoursMs, weekendMs, sessions, sessionsStarted,
             turns, toolCalls, peakConcurrent, toolBash, toolEdit, toolRead, toolSearch, toolWeb, toolAgent, toolMcp,
             toolOther, toolErrors, toolsMeasured, filesChanged, linesAdded, linesRemoved, approvalRequests,
             approvalWaitMs, localHour, localDow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) throws -> Int { try c.decode(Int.self, forKey: key) }
        hourUtc = try c.decode(String.self, forKey: .hourUtc)
        provider = try c.decode(String.self, forKey: .provider)
        model = try c.decode(String.self, forKey: .model)
        projectKey = try c.decode(String.self, forKey: .projectKey)
        (tokensIn, tokensOut, tokensCacheRead) = (try int(.tokensIn), try int(.tokensOut), try int(.tokensCacheRead))
        (tokensCacheWrite, tokensReasoning) = (try int(.tokensCacheWrite), try int(.tokensReasoning))
        costUsd = try c.decode(Double.self, forKey: .costUsd)
        costIncomplete = try c.decodeIfPresent(Bool.self, forKey: .costIncomplete) ?? true
        (activeMs, afterHoursMs, weekendMs, sessions) = (try int(.activeMs), try int(.afterHoursMs), try int(.weekendMs), try int(.sessions))
        sessionsStarted = try c.decodeIfPresent(Int.self, forKey: .sessionsStarted)
        (turns, toolCalls, peakConcurrent) = (try int(.turns), try int(.toolCalls), try int(.peakConcurrent))
        (toolBash, toolEdit, toolRead, toolSearch) = (try int(.toolBash), try int(.toolEdit), try int(.toolRead), try int(.toolSearch))
        (toolWeb, toolAgent, toolMcp, toolOther) = (try int(.toolWeb), try int(.toolAgent), try int(.toolMcp), try int(.toolOther))
        (toolErrors, toolsMeasured) = (try int(.toolErrors), try int(.toolsMeasured))
        (filesChanged, linesAdded, linesRemoved) = (try int(.filesChanged), try int(.linesAdded), try int(.linesRemoved))
        (approvalRequests, approvalWaitMs) = (try int(.approvalRequests), try int(.approvalWaitMs))
        (localHour, localDow) = (try int(.localHour), try int(.localDow))
    }
}
