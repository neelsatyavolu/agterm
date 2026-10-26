import Foundation

/// When a client that lost its helper connection tries to attach again. A client superseded by
/// another one never does (two apps would kick each other forever); otherwise it tries three
/// times with backoff, and a connection that drops again soon after counts as another try.
public struct ReattachPolicy {
    public enum Loss {
        /// The helper said another client attached to the session.
        case superseded
        /// Anything else: the helper dropped a slow client, restarted, or died.
        case dropped
    }

    public static let delays: [TimeInterval] = [0.2, 0.5, 1]
    /// A connection that stayed up this long starts the count again.
    public static let stableAfter: TimeInterval = 10

    private var tries = 0
    private var connectedAt: Date
    /// Whether a try succeeded since the last `delay` (the first connection counts).
    private var reconnected = true

    public init(now: Date = Date()) {
        connectedAt = now
    }

    /// How long to wait before the next try, or nil to give up.
    public mutating func delay(after loss: Loss, now: Date = Date()) -> TimeInterval? {
        guard loss == .dropped else { return nil }
        if reconnected, now.timeIntervalSince(connectedAt) >= Self.stableAfter { tries = 0 }
        reconnected = false
        guard tries < Self.delays.count else { return nil }
        defer { tries += 1 }
        return Self.delays[tries]
    }

    /// A try succeeded.
    public mutating func connected(now: Date = Date()) {
        connectedAt = now
        reconnected = true
    }
}
