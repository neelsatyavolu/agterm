import AgTermCore
import Foundation

/// The phone's side of the agmux relay, speaking agterm's dialect of it (`AgTermWire`).
/// Holds everything the screens show: the Mac's tabs, the live screen of the open tab and,
/// when asked for, its conversation.
@MainActor
final class Remote: ObservableObject {
    enum Link: Equatable { case unpaired, connecting, online, macOffline }

    @Published private(set) var pairing: Pairing?
    /// Showing `Demo`'s sample tabs instead of a Mac's.
    @Published private(set) var isDemo = false
    @Published private(set) var link: Link = .unpaired
    @Published private(set) var macName: String?
    @Published private(set) var tabs: [RemoteTabRow] = []
    /// Agents and folders the Mac offers for a new tab.
    @Published private(set) var newTabOptions: NewTabOptions?
    /// Set while a new tab is being opened; then the id of the tab the Mac opened, to show it.
    @Published private(set) var openingTab = false
    @Published var openedTab: String?
    private var openRequest: String?
    @Published private(set) var screens: [String: ScreenSnapshot] = [:]
    @Published private(set) var timelines: [String: [MobileTimelineEntry]] = [:]
    /// Something worth a line at the bottom of the screen ("That agterm tab is closed.").
    @Published var notice: String?
    /// Why the phone was signed out, or why pairing failed; shown on the pairing screen.
    @Published private(set) var unpairedReason: String?
    @Published private(set) var isPairing = false
    /// A reply the Mac never got, handed back so the reply box can show it again.
    @Published private(set) var returnedDraft: ReturnedDraft?

    struct ReturnedDraft: Equatable {
        let id = UUID()
        let tab: String
        let text: String
    }

    private var socket: URLSessionWebSocketTask?
    /// Bumped per socket, so callbacks from a replaced socket are ignored.
    private var generation = 0
    private var lastInbound = Date()
    private var backoff: Double = 1
    private var heartbeat: Task<Void, Never>?
    private var renewal: Task<Void, Never>?
    private var watching: String?
    private var watchingChat = false
    private var foreground = true
    /// Replies sent but not yet acknowledged by the Mac (`message.accepted`), by request id.
    private var pendingReplies: [String: (tab: String, text: String)] = [:]

    private static let heartbeatEvery: Duration = .seconds(15)
    private static let deadAfter: TimeInterval = 40
    private static let pairTimeout: TimeInterval = 15
    /// Byte for byte what the relay answers without waking its Durable Object.
    private static let ping = #"{"type":"ping"}"#

    init() {
        pairing = PairingStore.load()
        link = pairing == nil ? .unpaired : .connecting
        Push.shared.onToken = { [weak self] _ in self?.registerPush() }
        Push.shared.listenForOpens { [weak self] tab in self?.openedTab = tab }
        retireForgotten()
    }

    /// Tells the relay where to push this phone's alerts. Sent on every connect: tokens change.
    private func registerPush() {
        guard let token = Push.shared.token else { return }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        send(["type": "push.register", "token": token, "approvals": true, "finished": true,
              "environment": environment, "topic": Bundle.main.bundleIdentifier ?? ""])
    }

    // MARK: Lifecycle

    /// iOS suspends sockets in the background, so drop it there and dial again on return.
    func setForeground(_ on: Bool) {
        foreground = on
        if on {
            if socket == nil || Date().timeIntervalSince(lastInbound) > Self.deadAfter { reconnectNow() }
        } else {
            closeSocket()
        }
    }

    private func connect() {
        guard foreground, socket == nil, let pairing, var url = URLComponents(string: pairing.relay) else { return }
        url.queryItems = [URLQueryItem(name: "desktopId", value: pairing.desktopId)]
        guard let address = url.url else { return }
        let task = URLSession.shared.webSocketTask(with: address)
        task.maximumMessageSize = 2 << 20
        generation += 1
        let current = generation
        socket = task
        if link != .online { link = .connecting }
        lastInbound = Date()
        task.resume()
        send(["type": "hello", "role": "phone", "token": pairing.phoneToken, "desktopId": pairing.desktopId])
        Task { await receive(task, generation: current) }
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatEvery)
                guard let self, self.generation == current else { return }
                self.socket?.send(.string(Self.ping)) { _ in }
                if Date().timeIntervalSince(self.lastInbound) > Self.deadAfter { self.reconnectNow() }
            }
        }
    }

    private func closeSocket() {
        generation += 1
        heartbeat?.cancel()
        if let request = openRequest { giveUpOpening(request, "Lost the connection while opening the tab.") }
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func reconnectNow() {
        closeSocket()
        backoff = 1
        connect()
    }

    private func reconnectLater() {
        closeSocket()
        guard pairing != nil else { return }
        link = .connecting
        let delay = backoff
        backoff = min(backoff * 2, 30)
        let current = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.generation == current else { return }
            self.connect()
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, generation current: Int) async {
        while true {
            do {
                let message = try await task.receive()
                guard current == generation else { return }
                lastInbound = Date()
                switch message {
                case .string(let text): handle(Data(text.utf8))
                case .data(let data): handle(data)
                @unknown default: break
                }
            } catch {
                guard current == generation else { return }
                // 4001: the relay doesn't know this token. 4003: the Mac revoked it, or it expired.
                if [4001, 4003].contains(task.closeCode.rawValue) {
                    unpair("This iPhone was unpaired from the Mac. Pair it again from agterm Settings.")
                } else {
                    reconnectLater()
                }
                return
            }
        }
    }

    // MARK: Incoming

    private struct Incoming: Decodable {
        let type: String
        var threadId: String?
        var requestId: String?
        var threads: [RemoteTabRow]?
        var thread: RemoteTabRow?
        var entries: [MobileTimelineEntry]?
        var screen: ScreenSnapshot?
        var deviceName: String?
        var message: String?
        var agterm: NewTabOptions?
    }

    private func handle(_ data: Data) {
        let message: Incoming
        do {
            message = try JSONDecoder().decode(Incoming.self, from: data)
        } catch {
            NSLog("agterm Remote: unreadable message: %@", String(describing: error))
            return
        }
        switch message.type {
        case "hello.ok":
            backoff = 1
            registerPush()
        case "desktop.online":
            link = .online
            macName = message.deviceName ?? macName
            send(["type": "threads.list"])
            subscribe(renew: false)
        case "desktop.offline":
            link = .macOffline
        case "threads.snapshot":
            tabs = message.threads ?? []
            newTabOptions = message.agterm ?? newTabOptions
        case "thread.created":
            if let row = message.thread, !tabs.contains(where: { $0.id == row.id }) { tabs.append(row) }
            if let request = message.requestId, request == openRequest {
                openRequest = nil
                openingTab = false
                openedTab = message.thread?.id
            }
        case "threads.upsert":
            if let row = message.thread {
                if let index = tabs.firstIndex(where: { $0.id == row.id }) { tabs[index] = row } else { tabs.append(row) }
            }
        case "timeline.snapshot":
            guard let thread = message.threadId else { return }
            if let tab = AgTermWire.tabID(screenThread: thread) {
                if let screen = message.screen { screens[tab] = screen }
            } else {
                timelines[thread] = message.entries ?? []
            }
        case "message.accepted":
            if let request = message.requestId { pendingReplies[request] = nil }
        case "error":
            let text = message.message ?? "Something went wrong."
            // The relay names the request it couldn't deliver (e.g. "desktop offline").
            if let request = message.requestId { giveBack(request) }
            if let request = message.requestId, request == openRequest {
                openRequest = nil
                openingTab = false
            }
            if text.contains("invalid phone token") {
                unpair("This iPhone was unpaired from the Mac. Pair it again from agterm Settings.")
            } else if text == "desktop offline" {
                link = .macOffline
            } else if text.hasPrefix("cannot forward push.") || text.hasPrefix("cannot forward app.state")
                        || text.contains("push token") || text.contains("push topic") {
                // A relay without push for this app (e.g. a local one); the app works without it.
                NSLog("agterm Remote: push unavailable: %@", text)
            } else if text.contains("re-hello") {
                // The relay woke from hibernation without this socket's session.
                reconnectNow()
            } else {
                notice = text
            }
        default:
            break
        }
    }

    // MARK: Watching a tab

    /// Leases the open tab's live screen and, when `chat`, its conversation (Claude Code and
    /// Codex transcripts). The Mac stops sending once a lease lapses, so leaving needs no message.
    func watch(_ tab: String, chat: Bool) {
        guard !isDemo else { return }
        watching = tab
        watchingChat = chat
        subscribe(renew: false)
        renewal?.cancel()
        renewal = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AgTermWire.screenRenew))
                guard let self, !Task.isCancelled, self.watching == tab else { return }
                self.subscribe(renew: true)
            }
        }
    }

    func stopWatching(_ tab: String) {
        guard watching == tab else { return }
        watching = nil
        renewal?.cancel()
    }

    /// A renewal only extends the leases; anything else asks for full frames too.
    private func subscribe(renew: Bool) {
        guard let watching else { return }
        send(["type": "thread.subscribe", "threadId": watching, "screen": true, "renew": renew])
        if watchingChat { send(["type": "thread.subscribe", "threadId": watching, "lease": true, "renew": renew]) }
    }

    // MARK: Acting on a tab

    /// Types a reply and presses Enter, after clearing whatever was half-typed (as agmux does).
    /// False when the Mac can't be reached, so the caller keeps the draft.
    func reply(_ text: String, to tab: String) -> Bool {
        if isDemo { return demoReply(text, to: tab) }
        guard link == .online else {
            notice = "Not connected to the Mac. Your reply wasn't sent."
            return false
        }
        let request = UUID().uuidString
        pendingReplies[request] = (tab, text)
        return send(["type": "message.send", "requestId": request, "threadId": tab, "text": text]) { [weak self] in
            self?.giveBack(request)
        }
    }

    private func giveBack(_ request: String) {
        guard let reply = pendingReplies.removeValue(forKey: request) else { return }
        returnedDraft = ReturnedDraft(tab: reply.tab, text: reply.text)
        notice = "Your reply didn't reach the Mac. It's back in the reply box."
    }

    /// Presses keys in the tab exactly, without clearing the line or adding Enter.
    func press(_ keys: [TerminalKey] = [], text: String = "", in tab: String) {
        if isDemo { return demoPress(keys, text: text, in: tab) }
        send(["type": "message.send", "requestId": UUID().uuidString, "threadId": tab, "text": text,
              "raw": true, "keys": keys.map(\.rawValue)])
    }

    /// Asks the Mac for a new tab running `provider` (an agent id, or `AgTermWire.shellProvider`) in `folder`.
    func openTab(provider: String, folder: String) {
        if isDemo { return demoOpenTab(provider: provider, folder: folder) }
        guard link == .online else {
            notice = "Not connected to the Mac."
            return
        }
        let request = UUID().uuidString
        openRequest = request
        openingTab = true
        let sent = send(["type": "thread.create", "requestId": request, "provider": provider, "projectId": folder]) { [weak self] in
            self?.giveUpOpening(request, "The new tab request didn't reach the Mac.")
        }
        guard sent else { return giveUpOpening(request, "Not connected to the Mac.") }
        // Never resent: the Mac may have opened it and only the answer got lost.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            self?.giveUpOpening(request, "The Mac didn't answer. Check its tab list before trying again.")
        }
    }

    private func giveUpOpening(_ request: String, _ message: String) {
        guard openRequest == request else { return }
        openRequest = nil
        openingTab = false
        notice = message
    }

    func interrupt(_ tab: String) {
        if isDemo { return demoSettle(tab, .idle, line: "Interrupted.") }
        send(["type": "turn.interrupt", "threadId": tab])
    }

    @discardableResult
    private func send(_ message: [String: Any], failed: (@MainActor () -> Void)? = nil,
                      sent: (@MainActor () -> Void)? = nil) -> Bool {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return false }
        // The completion-handler form queues in call order; key presses must not overtake each other.
        socket.send(.string(text)) { error in
            if let error {
                NSLog("agterm Remote: send failed: %@", error.localizedDescription)
                Task { @MainActor in failed?() }
            } else {
                Task { @MainActor in sent?() }
            }
        }
        return true
    }

    // MARK: Pairing

    /// Pairs with the Mac from a scanned or opened link, replacing any Mac paired before.
    func pair(_ link: PairLink) {
        guard !isPairing else { return }
        isPairing = true
        unpairedReason = nil
        Task {
            let failure = await exchange(link)
            isPairing = false
            // Already paired: the tab list is showing, so say it there.
            if let failure { if pairing == nil { unpairedReason = failure } else { notice = failure } }
        }
    }

    /// Trades the Mac's one-time code for this phone's token. Returns an error to show, or nil.
    private func exchange(_ link: PairLink) async -> String? {
        let relay = link.relay ?? AgTermWire.defaultRelay
        guard var url = URLComponents(string: relay) else { return "That pairing link has a bad relay address." }
        url.queryItems = [URLQueryItem(name: "desktopId", value: link.desktopId)]
        guard let address = url.url else { return "That pairing link has a bad relay address." }
        let task = URLSession.shared.webSocketTask(with: address)
        task.resume()
        let started = Date()
        let timeout = Task {
            try await Task.sleep(for: .seconds(Self.pairTimeout))
            task.cancel(with: .goingAway, reason: nil)
        }
        defer {
            timeout.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }
        do {
            let submit = try JSONSerialization.data(withJSONObject: ["type": "pair.submit", "code": link.code])
            try await task.send(.string(String(decoding: submit, as: UTF8.self)))
            while true {
                guard case .string(let text) = try await task.receive(),
                      let reply = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { continue }
                switch reply["type"] as? String {
                case "pair.ok":
                    guard let token = reply["phoneToken"] as? String else { return "The relay sent an incomplete answer." }
                    let paired = Pairing(desktopId: link.desktopId, phoneToken: token,
                                         deviceId: reply["deviceId"] as? String, relay: relay)
                    guard PairingStore.save(paired) else { return "Couldn't save the pairing in the Keychain." }
                    adopt(paired)
                    return nil
                case "pair.fail":
                    return (reply["reason"] as? String).map { "Pairing failed: \($0)." } ?? "Pairing failed."
                case "error":
                    return reply["message"] as? String ?? "Pairing failed."
                default:
                    continue
                }
            }
        } catch {
            return Date().timeIntervalSince(started) < Self.pairTimeout - 1
                ? "Couldn't reach the relay. Check your connection and try again."
                : "Pairing timed out. Make a new code on the Mac and try again."
        }
    }

    private func adopt(_ paired: Pairing) {
        closeSocket()
        isDemo = false
        pairing = paired
        unpairedReason = nil
        tabs = []
        newTabOptions = nil
        screens = [:]
        timelines = [:]
        link = .connecting
        connect()
    }

    /// Forgets the Mac on this phone. The Mac still lists the phone until it's removed there.
    func forget() {
        if isDemo { return unpair(nil) }
        guard let old = pairing else { return unpair(nil) }
        // The relay keeps pushing until it hears push.unregister, so keep the old credentials
        // until it has; retireForgotten() tries again on later launches.
        PairingStore.saveForgotten(old)
        let delivered = link == .online && send(["type": "push.unregister"], sent: { PairingStore.clearForgotten() })
        if delivered {
            // Let the queued frame leave before the socket closes.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.unpair(nil)
            }
        } else {
            unpair(nil)
        }
    }

    /// Sends push.unregister for a Mac forgotten while offline, then drops its credentials.
    private func retireForgotten() {
        guard let old = PairingStore.loadForgotten(), var url = URLComponents(string: old.relay) else { return }
        url.queryItems = [URLQueryItem(name: "desktopId", value: old.desktopId)]
        guard let address = url.url else { return PairingStore.clearForgotten() }
        let task = URLSession.shared.webSocketTask(with: address)
        task.resume()
        Task {
            defer { task.cancel(with: .normalClosure, reason: nil) }
            let hello = try? JSONSerialization.data(withJSONObject: ["type": "hello", "role": "phone", "token": old.phoneToken, "desktopId": old.desktopId])
            try? await task.send(.string(String(decoding: hello ?? Data(), as: UTF8.self)))
            guard case .string(let text)? = try? await task.receive() else {
                // 4001/4003: the token is gone, and so is its push registration.
                if [4001, 4003].contains(task.closeCode.rawValue) { PairingStore.clearForgotten() }
                return
            }
            if text.contains("hello.ok") {
                try? await task.send(.string(#"{"type":"push.unregister"}"#))
                try? await Task.sleep(for: .milliseconds(500))
                PairingStore.clearForgotten()
            }
        }
    }

    private func unpair(_ reason: String?) {
        closeSocket()
        isDemo = false
        PairingStore.clear()
        pairing = nil
        link = .unpaired
        unpairedReason = reason
        macName = nil
        tabs = []
        newTabOptions = nil
        screens = [:]
        timelines = [:]
        watching = nil
        renewal?.cancel()
    }

    // MARK: Demo

    /// Shows `Demo`'s sample tabs, answered on the phone. Pairing or Exit Demo leaves it.
    func startDemo() {
        isDemo = true
        unpairedReason = nil
        link = .online
        macName = Demo.macName
        tabs = Demo.tabs
        newTabOptions = Demo.options
        screens = Demo.screens
        timelines = Demo.timelines
    }

    private func demoReply(_ text: String, to tab: String) -> Bool {
        demoAppend(tab, line: [Demo.run("> ", 4), Demo.run(text)], entry: Demo.user(text))
        demoSetStatus(tab, .working)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.demoSettle(tab, .done, line: Demo.answer, entry: Demo.assistant(Demo.answer))
        }
        return true
    }

    /// A numbered answer to the sample approval runs the edit; Esc declines it.
    private func demoPress(_ keys: [TerminalKey], text: String, in tab: String) {
        guard tabs.first(where: { $0.id == tab })?.agterm?.prompt != nil else { return }
        if keys == [.esc] || text == "3" { return demoSettle(tab, .idle, line: "Edit declined.") }
        guard ["1", "2"].contains(text) else { return }
        demoSetStatus(tab, .working)
        // The approved edit ran.
        timelines[tab] = timelines[tab]?.map { var entry = $0; if entry.status == "running" { entry.status = "done" }; return entry }
        demoAppend(tab, line: [Demo.run("● ", 2), Demo.run("Run npm test -- checkout --repeat 50")], entry: Demo.tool("Run", "npm test -- checkout --repeat 50"))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            let done = "The checkout test passed 50 runs in a row. The fix waits for the retry instead of a fixed delay."
            self?.demoSettle(tab, .done, line: done, entry: Demo.assistant(done))
        }
    }

    private func demoOpenTab(provider: String, folder: String) {
        let id = "demo-\(UUID().uuidString)"
        let agent = provider == AgTermWire.shellProvider ? nil : provider
        let title = Demo.options.agents.first { $0.id == provider }?.title ?? "zsh"
        tabs.append(Demo.row(id, title, .idle, agent: agent, folder: (folder as NSString).lastPathComponent, branch: nil))
        screens[id] = Demo.shell
        if agent != nil { timelines[id] = [] }
        openedTab = id
    }

    private func demoSettle(_ tab: String, _ status: TabStatus, line: String, entry: MobileTimelineEntry? = nil) {
        demoAppend(tab, line: [Demo.run(line)], entry: entry)
        demoSetStatus(tab, status)
    }

    private func demoSetStatus(_ tab: String, _ status: TabStatus) {
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { return }
        tabs[index].agterm?.status = status.wireName
        tabs[index].agterm?.prompt = nil
        tabs[index].processing = status == .working
        tabs[index].needsApproval = false
    }

    private func demoAppend(_ tab: String, line: [ScreenRun], entry: MobileTimelineEntry?) {
        if var screen = screens[tab] {
            screen.lines += [[], line]
            screen.rows = screen.lines.count
            screens[tab] = screen
        }
        if let entry, timelines[tab] != nil { timelines[tab]?.append(entry) }
    }
}
