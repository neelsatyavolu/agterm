import Foundation

/// One row of a phone timeline, wire-identical to agmux's
/// `remote::protocol::MobileTimelineEntry` (serde `rename_all = "camelCase"`,
/// every optional omitted when nil) and `remote-relay/src/protocol.ts`.
///
/// Kinds the phone paints: `user`, `assistant`, `thinking`, `tool`.
public struct MobileTimelineEntry: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var text: String?
    public var streaming: Bool?
    /// Tool verb shown first on a tool row ("Read", "Ran", "Edited", ...).
    public var lead: String?
    public var subject: String?
    public var detail: String?
    /// `running`, `ok` or `error` for tool rows.
    public var status: String?
    public var additions: Int?
    public var deletions: Int?
    public var body: String?
    /// Tool call id, so results can patch the row.
    public var requestId: String?
    public var toolName: String?
    /// `queued` for a Claude message still waiting in the input queue.
    public var state: String?
    public var message: String?
    /// Milliseconds since the Unix epoch; 0 when the source had no timestamp.
    public var ts: Int

    public init(id: String, kind: String, text: String? = nil, streaming: Bool? = nil,
                lead: String? = nil, subject: String? = nil, detail: String? = nil,
                status: String? = nil, additions: Int? = nil, deletions: Int? = nil,
                body: String? = nil, requestId: String? = nil, toolName: String? = nil,
                state: String? = nil, message: String? = nil, ts: Int) {
        self.id = id
        self.kind = kind
        self.text = text
        self.streaming = streaming
        self.lead = lead
        self.subject = subject
        self.detail = detail
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.body = body
        self.requestId = requestId
        self.toolName = toolName
        self.state = state
        self.message = message
        self.ts = ts
    }
}
