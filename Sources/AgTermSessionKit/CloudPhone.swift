import AgTermCore
import Foundation

/// agterm Remote with the Mac off: on a cloud machine, the helper connects to the phone relay as
/// the Mac's desktop (`CloudPhoneHandoff`, which the Mac leaves in the home folder) once the Mac
/// has gone (`CloudPhoneRule`), and serves its sessions the way the Mac's `RemoteClient` serves
/// tabs: the tab list with status, pushes for finished agents and prompts, live screens, the
/// agent's conversation, typing and keys. Used only on the server's queue.
final class CloudPhone {
    /// What it needs from the server, read on the server's queue.
    struct Host {
        var sessions: () -> [HostedSession]
        /// A client is connected (the Mac, through the gateway).
        var macConnected: () -> Bool
        var macLastSeen: () -> Date
        /// The phone is using the machine, so it isn't idle.
        var touch: () -> Void
    }

    private let queue: DispatchQueue
    private let host: Host
    private let handoffPath: String
    private let build: String
    private let macGoneAfter: TimeInterval
    private var handoff: CloudPhoneHandoff?
    private var handoffModified: Date?
    private var socket: RelaySocket?
    private var connecting = false
    private var online = false
    private var replacedAt: Date?
    /// The relay turned the identity down: wait for a new handoff.
    private var rejected = false
    private var retryAt = Date.distantPast
    private var backoff: TimeInterval = 1
    private var lastInbound = Date()
    private var lastPing = Date.distantPast
    private var timers: [DispatchSourceTimer] = []
    /// Bumped by every disconnect, so a connection that finishes after one is dropped.
    private var generation = 0

    private var lastThreads = ""
    private var approvals: [String: String] = [:] // tab id → request id
    private var lastProcessing: [String: Bool] = [:]
    private var screenLeases: [String: Date] = [:]
    private var sentScreen: [String: String] = [:]
    private var chatLeases: [String: Date] = [:]
    private var subscribed = Set<String>()
    private var sentTimeline: [String: String] = [:]
    private let transcripts: CloudPhoneTranscripts

    init(queue: DispatchQueue, host: Host, handoffPath: String, build: String, macGoneAfter: TimeInterval) {
        self.macGoneAfter = macGoneAfter
        self.queue = queue
        self.host = host
        self.handoffPath = handoffPath
        self.build = build
        transcripts = CloudPhoneTranscripts(queue: queue)
    }

    func start() {
        timers = [repeatEvery(2) { [weak self] in self?.tick() },
                  repeatEvery(0.3) { [weak self] in self?.pushScreens() }]
    }

    func stop() {
        timers.forEach { $0.cancel() }
        timers = []
        disconnect()
    }

    private func repeatEvery(_ seconds: TimeInterval, _ work: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler(handler: work)
        timer.resume()
        return timer
    }

    // MARK: Connection

    private func tick() {
        readHandoff()
        let sessions = host.sessions()
        if socket != nil || connecting {
            if handoff == nil || sessions.isEmpty { return disconnect() }
            if online {
                if Date().timeIntervalSince(lastInbound) > 40 { return disconnect() }
                if Date().timeIntervalSince(lastPing) >= 15 { lastPing = Date(); send(["type": "ping"]) }
                pushUpdates(sessions)
            }
            return
        }
        guard !rejected, Date() >= retryAt,
              CloudPhoneRule.shouldConnect(hasHandoff: handoff != nil, hasTabs: !sessions.isEmpty, macConnected: host.macConnected(),
                                           macLastSeen: host.macLastSeen(), replacedAt: replacedAt, now: Date(),
                                           goneAfter: macGoneAfter) else { return }
        connect()
    }

    private func readHandoff() {
        let modified = (try? FileManager.default.attributesOfItem(atPath: handoffPath))?[.modificationDate] as? Date
        guard modified != handoffModified else { return }
        handoffModified = modified
        let next = (try? Data(contentsOf: URL(fileURLWithPath: handoffPath))).flatMap { try? JSONDecoder().decode(CloudPhoneHandoff.self, from: $0) }
        if next?.desktopId != handoff?.desktopId || next?.desktopSecret != handoff?.desktopSecret { rejected = false }
        handoff = next
        lastThreads = ""
    }

    private func connect() {
        guard let handoff, let url = URL(string: handoff.relay + "?desktopId=" + handoff.desktopId) else { return }
        connecting = true
        let attempt = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let socket = try? RelaySocket(url: url)
            guard let self else { return socket?.close() ?? () }
            self.queue.async { self.connected(socket, handoff, attempt: attempt) }
        }
    }

    private func connected(_ socket: RelaySocket?, _ handoff: CloudPhoneHandoff, attempt: Int) {
        // Meanwhile it was stopped, the handoff changed, or the Mac came back: the relay is the Mac's.
        guard attempt == generation, !timers.isEmpty, handoff == self.handoff, !host.macConnected() else {
            if attempt == generation { connecting = false }
            socket?.close()
            return
        }
        connecting = false
        guard let socket else { return retryLater() }
        self.socket = socket
        lastInbound = Date()
        socket.start(on: queue) { [weak self, weak socket] event in
            guard let self, let socket, socket === self.socket else { return }
            self.received(event)
        }
        send(["type": "hello", "role": "desktop", "token": handoff.desktopSecret, "desktopId": handoff.desktopId,
              "deviceName": handoff.deviceName, "appVersion": build, "capabilities": ["message-ack"]])
    }

    private func disconnect() {
        generation += 1
        connecting = false
        socket?.close()
        socket = nil
        online = false
        screenLeases = [:]
        chatLeases = [:]
        subscribed = []
    }

    private func retryLater() {
        retryAt = Date().addingTimeInterval(backoff)
        backoff = min(backoff * 2, 60)
    }

    private func received(_ event: RelaySocket.Event) {
        switch event {
        case .text(let text):
            lastInbound = Date()
            guard let message = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
            handle(message)
        case .closed(let code):
            disconnect()
            if code == CloudPhoneRule.replacedCode {
                // The Mac is back on the relay.
                replacedAt = Date()
            } else if code == 4001 || code == 4003 {
                rejected = true
            } else {
                retryLater()
            }
        }
    }

    private func send(_ message: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        socket.send(String(decoding: data, as: UTF8.self))
    }

    // MARK: Messages

    private func handle(_ m: [String: Any]) {
        let thread = m["threadId"] as? String
        let kind = m["type"] as? String
        if kind != "pong", kind != "hello.ok", kind != "devices.snapshot" { host.touch() }
        switch kind {
        case "hello.ok":
            online = true
            backoff = 1
            lastThreads = ""
            // Work done while the Mac was watching isn't news.
            host.sessions().forEach { $0.status.seen() }
            pushUpdates(host.sessions())
        case "threads.list":
            lastThreads = ""
            pushUpdates(host.sessions())
        case "thread.subscribe" where m["screen"] as? Bool == true:
            guard let thread else { return }
            screenLeases[thread] = Date().addingTimeInterval(AgTermWire.screenLease)
            if m["renew"] as? Bool != true { sentScreen[thread] = nil }
            sendScreen(thread)
        case "thread.subscribe" where m["lease"] as? Bool == true:
            guard let thread else { return }
            chatLeases[thread] = Date().addingTimeInterval(AgTermWire.screenLease)
            if m["renew"] as? Bool != true { sentTimeline[thread] = nil }
            sendTimeline(thread)
        case "thread.subscribe":
            guard let thread else { return }
            subscribed.insert(thread)
            sentTimeline[thread] = nil
            sendTimeline(thread)
        case "thread.unsubscribe":
            if let thread { subscribed.remove(thread) }
        case "message.send":
            if let thread, m["raw"] as? Bool == true {
                press(m["text"] as? String ?? "", keys: m["keys"] as? [String] ?? [], into: thread)
            } else if let thread, let text = m["text"] as? String {
                type(text, into: thread)
            }
            if let thread, let request = m["requestId"] as? String {
                send(["type": "message.accepted", "threadId": thread, "requestId": request])
            }
        case "thread.create":
            var error: [String: Any] = ["type": "error", "message": "New tabs open on your Mac. Your cloud tabs are all here."]
            error["requestId"] = m["requestId"] as? String
            send(error)
        case "turn.interrupt":
            if let thread, let session = session(thread) { session.type(session.status.agent == "grok" ? "\u{3}" : "\u{1b}") }
        case "approval.respond":
            if let thread, let session = session(thread), let request = m["requestId"] as? String {
                session.type((m["decision"] as? String) == "allow" ? "1" : "\u{1b}")
                approvals[thread] = nil
                send(["type": "approval.resolved", "threadId": thread, "requestId": request])
            }
        default:
            break
        }
    }

    private func session(_ tabID: String) -> HostedSession? {
        host.sessions().first { $0.tabID == tabID }
    }

    /// As the Mac does: clear the line, type, wait, then Enter.
    private func type(_ text: String, into thread: String) {
        guard let session = session(thread) else {
            return send(["type": "error", "threadId": thread, "message": "That agterm tab is closed."])
        }
        session.type("\u{15}" + text)
        queue.asyncAfter(deadline: .now() + 0.3) { [weak session] in session?.type("\r") }
    }

    private func press(_ text: String, keys: [String], into thread: String) {
        guard let session = session(thread) else {
            return send(["type": "error", "threadId": thread, "message": "That agterm tab is closed."])
        }
        let bytes = text + keys.compactMap { TerminalKey(rawValue: $0)?.bytes(applicationCursor: session.applicationCursor) }.joined()
        if !bytes.isEmpty { session.type(bytes) }
    }

    // MARK: Updates

    /// The Mac's tab order first, then any other session by age.
    private func ordered(_ sessions: [HostedSession]) -> [HostedSession] {
        let order = Dictionary((handoff?.tabs ?? []).enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return sessions.sorted { (order[$0.tabID] ?? Int.max, $0.startedAt) < (order[$1.tabID] ?? Int.max, $1.startedAt) }
    }

    private func pushUpdates(_ all: [HostedSession]) {
        guard online else { return }
        let sessions = ordered(all)
        let now = Date()
        for session in sessions {
            if screenLeases[session.tabID] != nil || chatLeases[session.tabID] != nil { session.status.seen(now) }
            session.status.observe(session.foreground(), screen: session.screenText(), now: now)
            transcripts.refresh(session) { [weak self] tabID in
                guard let self else { return }
                self.lastThreads = ""
                if self.subscribed.contains(tabID) || self.chatLeases[tabID] != nil { self.sendTimeline(tabID) }
            }
        }
        let rows = sessions.map(row)
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: .sortedKeys),
           let key = String(data: data, encoding: .utf8), key != lastThreads {
            lastThreads = key
            send(["type": "threads.snapshot", "threads": rows])
        }
        for (session, row) in zip(sessions, rows) {
            let id = session.tabID, status = session.status.status
            if lastProcessing[id] == true, status != .working { send(["type": "threads.upsert", "thread": row]) }
            lastProcessing[id] = status == .working
            if status == .waiting, approvals[id] == nil {
                let request = UUID().uuidString
                approvals[id] = request
                send(["type": "approval.requested", "threadId": id, "requestId": request,
                      "toolName": "Permission", "detail": Self.tail(session.screenText(), lines: 12)])
            } else if status != .waiting, let request = approvals.removeValue(forKey: id) {
                send(["type": "approval.resolved", "threadId": id, "requestId": request])
            }
        }
        chatLeases = chatLeases.filter { $0.value > now }
        subscribed.union(chatLeases.keys).forEach(sendTimeline)
    }

    private static let iso = ISO8601DateFormatter()

    private func row(_ session: HostedSession) -> [String: Any] {
        let s = session.status, status = s.status
        let home = handoff?.home ?? NSHomeDirectory()
        let folder = PathDisplay.folder(s.foreground?.cwd ?? session.cwd, home: home)
        let named = handoff?.tabs.first { $0.id == session.tabID }?.name
        let program = s.foreground.flatMap { $0.isShell || $0.name.isEmpty ? nil : $0.name }
        let title = named ?? (s.title.topic.isEmpty ? nil : s.title.topic) ?? program ?? "Terminal"
        let prompt = status == .waiting ? PermissionPrompt.read(session.screenText().components(separatedBy: "\n")) : nil
        let row = RemoteTabRow(
            id: session.tabID, title: title, provider: AgTermWire.provider(agent: s.agent), projectName: folder,
            processing: status == .working, unread: status == .done, needsApproval: status == .waiting,
            lastActive: Self.iso.string(from: s.signals.lastOutput ?? session.startedAt),
            status: status == .working ? "Running" : (status == .done ? "Done" : "Idle"),
            model: transcripts.model(session.tabID), linesAdded: nil, linesRemoved: nil,
            agterm: TabInfo(status: status, agent: s.agent, folder: folder, branch: nil, prompt: prompt))
        guard let data = try? JSONEncoder().encode(row),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private func sendTimeline(_ thread: String) {
        guard let session = session(thread) else { return }
        if let (entries, digest) = transcripts.entries(thread) {
            guard sentTimeline[thread] != digest else { return }
            sentTimeline[thread] = digest
            return send(["type": "timeline.snapshot", "threadId": thread, "entries": entries])
        }
        let screen = session.screenText()
        let digest = "s:" + String(screen.hashValue)
        guard sentTimeline[thread] != digest else { return }
        sentTimeline[thread] = digest
        let fence = screen.contains("```") ? "~~~~" : "```"
        let entry: [String: Any] = ["id": "screen-" + thread, "kind": "assistant",
                                    "text": fence + "\n" + screen + "\n" + fence, "ts": Int(Date().timeIntervalSince1970 * 1000)]
        send(["type": "timeline.snapshot", "threadId": thread, "entries": [entry]])
    }

    private func pushScreens() {
        guard online, !screenLeases.isEmpty else { return }
        let now = Date()
        for (thread, expiry) in screenLeases where expiry < now {
            screenLeases[thread] = nil
            sentScreen[thread] = nil
        }
        screenLeases.keys.forEach(sendScreen)
    }

    private func sendScreen(_ thread: String) {
        guard let session = session(thread),
              let data = try? JSONEncoder().encode(session.screenSnapshot(theme: handoff?.theme ?? "ink")),
              let screen = try? JSONSerialization.jsonObject(with: data) else { return }
        let digest = String(data.hashValue)
        guard sentScreen[thread] != digest else { return }
        sentScreen[thread] = digest
        send(["type": "timeline.snapshot", "threadId": AgTermWire.screenThread(thread), "entries": [], "screen": screen])
    }

    private static func tail(_ text: String, lines: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
