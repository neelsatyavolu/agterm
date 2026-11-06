import Foundation

/// From `fromMs` on, a session ran on the login with this identity hash. agterm records one
/// when it starts or resumes a Claude or Codex session; an automatic account switch resumes the
/// same session on another login, which starts a new span.
public struct LoginSpan: Codable, Equatable, Sendable {
    /// `claude` | `codex`, the Teams service's names for account buckets.
    public var provider: String
    /// Claude's session id, or the Codex rollout file's name without `.jsonl`: the ids the
    /// transcript readers put on their events.
    public var sessionID: String
    public var identityHash: String
    /// Claude only: the login's email, uploaded only to teams whose owner turned that on.
    public var label: String?
    public var fromMs: Int64

    public init(provider: String, sessionID: String, identityHash: String, label: String?, fromMs: Int64) {
        (self.provider, self.sessionID, self.identityHash, self.label, self.fromMs) = (provider, sessionID, identityHash, label, fromMs)
    }

    /// The account-bucket provider for an event's provider name, nil for providers not split by login.
    public static func provider(forEvent name: String) -> String? {
        switch name {
        case "ClaudeCode": "claude"
        case "Codex": "codex"
        default: nil
        }
    }
}

/// Spans by session, for finding the login an event ran on.
public struct LoginSpanIndex: Sendable {
    private var bySession: [String: [LoginSpan]] = [:]

    public init(_ spans: [LoginSpan]) {
        for span in spans { bySession[Self.key(span.provider, span.sessionID), default: []].append(span) }
        for key in bySession.keys { bySession[key]?.sort { $0.fromMs < $1.fromMs } }
    }

    /// The latest span of this session that had started by `atMs`; nil means not attributed.
    public func span(provider: String, sessionID: String, atMs: Int64) -> LoginSpan? {
        bySession[Self.key(provider, sessionID)]?.last { $0.fromMs <= atMs }
    }

    private static func key(_ provider: String, _ session: String) -> String { provider + "|" + session }
}

/// One hour of one login: the `accountBuckets` wire shape the Teams service accepts
/// (docs/teams-usage-by-login.md in agmux). Counters are absolute for the hour.
public struct AccountBucket: Codable, Equatable, Sendable {
    public var hourUtc = ""
    public var provider = ""
    public var identityHash = ""
    public var tokensIn = 0
    public var tokensOut = 0
    public var tokensCacheRead = 0
    public var tokensCacheWrite = 0
    public var tokensReasoning = 0
    public var costUsd = 0.0
    public var costIncomplete = false
    public var activeMs = 0
    public var turns = 0

    public init() {}
}

/// A login's email for `accountLabels`.
public struct AccountLabel: Codable, Equatable, Sendable {
    public var provider: String
    public var identityHash: String
    public var label: String

    public init(provider: String, identityHash: String, label: String) {
        (self.provider, self.identityHash, self.label) = (provider, identityHash, label)
    }

    /// The Service takes at most this many per upload.
    public static let maxPerUpload = 50

    /// Claude logins' emails from the spans, the newest label per login, newest logins first.
    public static func from(_ spans: [LoginSpan]) -> [AccountLabel] {
        var newest: [String: LoginSpan] = [:]
        for span in spans where span.provider == "claude" && !(span.label ?? "").isEmpty {
            if let seen = newest[span.identityHash], seen.fromMs >= span.fromMs { continue }
            newest[span.identityHash] = span
        }
        return newest.values.sorted { ($0.fromMs, $0.identityHash) > ($1.fromMs, $1.identityHash) }
            .prefix(maxPerUpload)
            .map { AccountLabel(provider: "claude", identityHash: $0.identityHash, label: $0.label ?? "") }
    }
}
