import Foundation

/// Queues anonymous usage events and hands them to a transport in one batch per flush. It never
/// retries: a batch that fails to send is gone. Thread-safe; the app flushes every few minutes
/// and at quit.
public final class AnalyticsClient: @unchecked Sendable {
    /// agmux's analytics service, which keeps agterm's numbers apart by the `app` field.
    public static let baseURL = URL(string: "https://owner.agmux.dev")!
    public static let heartbeatPath = "/v1/heartbeat"
    public static let eventsPath = "/v1/events"
    /// How often the app sends what it has queued.
    public static let flushInterval: TimeInterval = 5 * 60
    /// The service takes at most 100 events per request; past that, new events are dropped.
    public static let maxQueued = 100

    /// Sends one JSON body to a path under `baseURL`, then calls `done` however it went.
    public typealias Transport = @Sendable (_ path: String, _ body: Data, _ done: @escaping @Sendable () -> Void) -> Void

    private let installID: String
    private let isAllowed: @Sendable () -> Bool
    private let transport: Transport
    private let lock = NSLock()
    private var queue: [AnalyticsEvent] = []

    /// `isAllowed` is asked on every call, so turning analytics off takes effect at once.
    public init(installID: String, isAllowed: @escaping @Sendable () -> Bool, transport: @escaping Transport) {
        self.installID = installID
        self.isAllowed = isAllowed
        self.transport = transport
    }

    public var queuedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.count
    }

    /// Sent at once, not queued: it marks this install active today.
    public func sendHeartbeat(_ beat: AnalyticsHeartbeat) {
        guard isAllowed() else { return }
        transport(Self.heartbeatPath, AnalyticsPayload.heartbeat(installID: installID, beat), {})
    }

    /// Queues an event; nil (an event outside the allow-list) is ignored.
    public func record(_ event: AnalyticsEvent?) {
        guard let event, isAllowed() else { return }
        lock.lock()
        defer { lock.unlock() }
        if queue.count < Self.maxQueued { queue.append(event) }
    }

    /// Sends everything queued as one batch and empties the queue. Returns whether it sent
    /// anything; `done` runs either way, once the transport has finished.
    @discardableResult
    public func flush(done: @escaping @Sendable () -> Void = {}) -> Bool {
        lock.lock()
        let batch = queue
        queue = []
        lock.unlock()
        guard !batch.isEmpty, isAllowed() else {
            done()
            return false
        }
        transport(Self.eventsPath, AnalyticsPayload.events(installID: installID, batch), done)
        return true
    }
}
