import AgTermCore
import AppKit
import CryptoKit
import Foundation

/// Connects agterm to the agmux remote relay so agterm Remote (iPhone) and the agmux phone app can
/// watch and drive its tabs. agterm is its own desktop on the relay (own id and secret, never agmux's,
/// which would knock agmux off). Each tab is a "terminal" thread: agmux shows its transcript or its
/// screen as a code block; agterm Remote also leases the live colored screen and presses keys
/// (see `AgTermWire`). Replies are typed into the tab the way agmux does it.
@MainActor
final class RemoteClient: ObservableObject {
    static let shared = RemoteClient()

    static let relayURL = relayOverride ?? AgTermWire.defaultRelay
    static let relayOverride = ProcessInfo.processInfo.environment["AGTERM_RELAY_URL"]
    static let phoneURL = "https://remote.agmux.dev"
    static let enabledKey = "remoteEnabled"

    enum Connection: Equatable { case off, connecting, online }
    /// `url` opens agterm Remote; `agmuxURL` pairs the agmux phone app instead.
    struct Pairing: Equatable { let code: String; let url: String; let agmuxURL: String; let expires: Date }

    @Published private(set) var connection: Connection = .off
    @Published private(set) var pairing: Pairing?
    @Published private(set) var phones: [String] = []
    @Published private(set) var phonesOnline = 0

    /// The window's tabs; set by MainWindowController.
    var tabs: () -> [TerminalSession] = { [] }
    /// Opens a tab in a folder, typing a command at its first prompt; returns the new tab's id.
    /// Set by MainWindowController.
    var openTab: (_ folder: String, _ command: String?) -> String? = { _, _ in nil }
    /// Called when the phone remote is turned on or off. Set by MainWindowController.
    var onEnabledChange: () -> Void = {}
    /// agmux's projects, re-read at most once a minute for the phone's New Tab folders.
    private var projects: (read: Date, paths: [String]) = (.distantPast, [])

    private var socket: URLSessionWebSocketTask?
    private var timers: [Timer] = []
    private var lastInbound = Date()
    private var backoff: TimeInterval = 1
    private var subscribed = Set<String>()
    private var sentTimeline: [String: String] = [:]
    private var lastThreads = ""
    private var approvals: [String: String] = [:] // tab id → request id
    private var lastProcessing: [String: Bool] = [:]
    /// Tabs whose live screen agterm Remote is watching, until when; and the last frame sent.
    private var screenLeases: [String: Date] = [:]
    private var sentScreen: [String: String] = [:]
    /// Conversations agterm Remote is reading, until when. agmux's subscriptions never lapse.
    private var chatLeases: [String: Date] = [:]
    /// Agent tabs render from the agent's transcript (like agmux), rebuilt off the main thread
    /// only when the file changes.
    private struct Transcript { var path: URL; var modified: Date; var entries: [MobileTimelineEntry]; var model: String? }
    private var transcripts: [String: Transcript] = [:]
    private var transcriptPaths: [String: URL] = [:]
    private var refreshing = Set<String>()
    private let reader = DispatchQueue(label: "agterm.remote-transcripts", qos: .utility)

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    // MARK: Identity

    private struct Credentials: Codable { let desktopId: String; let desktopSecret: String }
    private static let credentialsURL = AgentIntegration.supportDir.appendingPathComponent("remote-credentials.json")

    private lazy var credentials: Credentials = {
        if let data = try? Data(contentsOf: Self.credentialsURL), let saved = try? JSONDecoder().decode(Credentials.self, from: data) {
            return saved
        }
        let secret = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let fresh = Credentials(desktopId: UUID().uuidString.lowercased(), desktopSecret: secret)
        try? FileManager.default.createDirectory(at: Self.credentialsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(fresh).write(to: Self.credentialsURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.credentialsURL.path)
        return fresh
    }()

    // MARK: Lifecycle

    func startIfEnabled() {
        if isEnabled { connect() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        on ? connect() : disconnect()
        onEnabledChange()
    }

    /// What a cloud machine needs to answer the phone for these tabs while this Mac is off;
    /// nil while the phone remote is off.
    func cloudHandoff(tabs: [CloudPhoneHandoff.Tab]) -> CloudPhoneHandoff? {
        guard isEnabled else { return nil }
        return CloudPhoneHandoff(desktopId: credentials.desktopId, desktopSecret: credentials.desktopSecret, relay: Self.relayURL,
                                 deviceName: "agterm Cloud for " + (Host.current().localizedName ?? "your Mac"),
                                 theme: Theme.palette.id, home: NSHomeDirectory(), tabs: tabs)
    }

    private func connect() {
        guard socket == nil, let url = URL(string: Self.relayURL + "?desktopId=" + credentials.desktopId) else { return }
        connection = .connecting
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 1 << 20
        socket = task
        task.resume()
        send(["type": "hello", "role": "desktop", "token": credentials.desktopSecret, "desktopId": credentials.desktopId,
              "deviceName": "agterm on " + (Host.current().localizedName ?? "Mac"),
              "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
              "capabilities": ["message-ack"]])
        receive(task)
        lastInbound = Date()
        timers.forEach { $0.invalidate() }
        timers = [
            repeatEvery(15) { [weak self] in self?.send(["type": "ping"]) },
            repeatEvery(5) { [weak self] in self?.checkAlive() },
            repeatEvery(2) { [weak self] in self?.pushUpdates() },
            repeatEvery(0.3) { [weak self] in self?.pushScreens() },
            repeatEvery(60) { [weak self] in self?.send(["type": "devices.list"]) },
        ]
    }

    private func disconnect() {
        timers.forEach { $0.invalidate() }
        timers = []
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connection = .off
        pairing = nil
    }

    private func reconnectLater() {
        socket?.cancel()
        socket = nil
        timers.forEach { $0.invalidate() }
        timers = []
        guard isEnabled else { return connection = .off }
        connection = .connecting
        let delay = backoff
        backoff = min(backoff * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isEnabled else { return }
            self.connect()
        }
    }

    private func checkAlive() {
        if Date().timeIntervalSince(lastInbound) > 40 { reconnectLater() }
    }

    private func repeatEvery(_ seconds: TimeInterval, _ work: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: seconds, repeats: true) { _ in Task { @MainActor in work() } }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: Pairing

    func pair() {
        if socket == nil { setEnabled(true) }
        send(["type": "pair.create"])
    }

    // MARK: Wire

    private func send(_ message: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { error in
            if let error { NSLog("agterm: remote send failed: %@", error.localizedDescription) }
        }
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, task === self.socket else { return }
                switch result {
                case .failure(let error):
                    NSLog("agterm: remote connection lost: %@", error.localizedDescription)
                    if task.closeCode.rawValue == 4001 { self.credentialsRejected() } else { self.reconnectLater() }
                case .success(let message):
                    self.lastInbound = Date()
                    if case .string(let text) = message,
                       let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                        self.handle(object)
                    }
                    self.receive(task)
                }
            }
        }
    }

    private func credentialsRejected() {
        NSLog("agterm: the relay rejected agterm's desktop identity; turning the phone remote off")
        disconnect()
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        onEnabledChange()
    }

    private func handle(_ m: [String: Any]) {
        let thread = m["threadId"] as? String
        switch m["type"] as? String {
        case "hello.ok":
            connection = .online
            backoff = 1
            lastThreads = ""
            pushUpdates()
        case "devices.snapshot":
            phones = (m["devices"] as? [[String: Any]])?.compactMap { $0["label"] as? String } ?? []
            phonesOnline = m["phonesOnline"] as? Int ?? 0
        case "pair.created":
            if let code = m["code"] as? String {
                let expires = (m["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date().addingTimeInterval(600)
                let link = PairLink(code: code, desktopId: credentials.desktopId, relay: Self.relayOverride)
                pairing = Pairing(code: code, url: link.url.absoluteString,
                                  agmuxURL: "\(Self.phoneURL)#pair=\(code)&desktopId=\(credentials.desktopId)", expires: expires)
            }
        case "pair.ok", "phone.paired":
            pairing = nil
            send(["type": "devices.list"])
        case "threads.list":
            lastThreads = ""
            pushUpdates()
        case "thread.subscribe" where m["screen"] as? Bool == true:
            if let thread {
                screenLeases[thread] = Date().addingTimeInterval(AgTermWire.screenLease)
                // Any other phone may be the one asking, so only a renewal skips the full frame.
                if m["renew"] as? Bool != true { sentScreen[thread] = nil }
                sendScreen(thread)
            }
        case "thread.subscribe" where m["lease"] as? Bool == true:
            if let thread {
                chatLeases[thread] = Date().addingTimeInterval(AgTermWire.screenLease)
                if m["renew"] as? Bool != true { sentTimeline[thread] = nil }
                sendTimeline(thread)
            }
        case "thread.subscribe":
            if let thread {
                subscribed.insert(thread)
                sentTimeline[thread] = nil
                sendTimeline(thread)
            }
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
            createTab(provider: m["provider"] as? String ?? "", folder: m["projectId"] as? String ?? "",
                      request: m["requestId"] as? String)
        case "turn.interrupt":
            if let thread, let tab = tab(thread) { tab.view.send(txt: tab.agentName == "grok" ? "\u{3}" : "\u{1b}") }
        case "approval.respond":
            if let thread, let tab = tab(thread), let request = m["requestId"] as? String {
                tab.view.send(txt: (m["decision"] as? String) == "allow" ? "1" : "\u{1b}")
                approvals[thread] = nil
                send(["type": "approval.resolved", "threadId": thread, "requestId": request])
            }
        case "error":
            NSLog("agterm: relay error: %@", m["message"] as? String ?? "unknown")
        default:
            break
        }
    }

    // MARK: Tabs as threads

    private func tab(_ id: String) -> TerminalSession? { tabs().first { $0.tabID == id } }

    /// Same as agmux for terminals: clear the line, type, wait, then Enter.
    private func type(_ text: String, into thread: String) {
        guard let tab = tab(thread) else {
            return send(["type": "error", "threadId": thread, "message": "That agterm tab is closed."])
        }
        tab.view.send(txt: "\u{15}" + text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { tab.view.send(txt: "\r") }
    }

    /// agterm Remote's New Tab: an agent agterm knows (or a shell) in an existing folder.
    private func createTab(provider: String, folder: String, request: String?) {
        func fail(_ message: String) {
            var error: [String: Any] = ["type": "error", "message": message]
            error["requestId"] = request
            send(error)
        }
        guard let command = NewTabOptions.command(provider: provider) else { return fail("agterm doesn't know that agent.") }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), isFolder.boolValue else {
            return fail("That folder isn't on the Mac any more.")
        }
        guard let id = openTab(folder, command), let session = tab(id) else { return fail("agterm couldn't open a tab.") }
        lastThreads = ""
        pushUpdates()
        var created: [String: Any] = ["type": "thread.created", "thread": row(session)]
        created["requestId"] = request
        send(created)
    }

    private func newTabOptions(_ sessions: [TerminalSession]) -> [String: Any] {
        if Date().timeIntervalSince(projects.read) > 60 {
            projects = (Date(), AgentIntegration.agmuxProjects().map(\.repoPath))
        }
        let agents = (AgentIntegration.installedAgents() ?? []).map { NewTabOptions.Agent(id: $0.id, title: $0.title) }
        let folders = NewTabOptions.folders(tabs: sessions.map(\.cwd), projects: projects.paths, home: NSHomeDirectory()) {
            var isFolder: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isFolder) && isFolder.boolValue
        }
        let options = NewTabOptions(agents: agents, folders: folders, home: NSHomeDirectory())
        guard let data = try? JSONEncoder().encode(options),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// agterm Remote's keys: `text` exactly as given, then each named key, with no Enter of our own.
    private func press(_ text: String, keys: [String], into thread: String) {
        guard let tab = tab(thread) else {
            return send(["type": "error", "threadId": thread, "message": "That agterm tab is closed."])
        }
        let cursorKeys = tab.view.getTerminal().applicationCursor
        let bytes = text + keys.compactMap { TerminalKey(rawValue: $0)?.bytes(applicationCursor: cursorKeys) }.joined()
        if !bytes.isEmpty { tab.view.send(txt: bytes) }
    }

    private static let iso = ISO8601DateFormatter()

    private func row(_ s: TerminalSession) -> [String: Any] {
        let prompt = s.status == .waiting ? PermissionPrompt.read(s.screenText().components(separatedBy: "\n")) : nil
        let row = RemoteTabRow(
            id: s.tabID, title: s.topic, provider: Self.provider(s.agentName), projectName: s.folder,
            processing: s.status == .working, unread: s.status == .done, needsApproval: s.status == .waiting,
            lastActive: Self.iso.string(from: s.signals.lastOutput ?? Date()),
            status: s.status == .working ? "Running" : (s.status == .done ? "Done" : "Idle"),
            // The raw model id, as agmux sends it; the phone shortens it ("Opus 5.5").
            model: transcripts[s.tabID]?.model, linesAdded: s.agentDiff?.added, linesRemoved: s.agentDiff?.removed,
            agterm: TabInfo(status: s.status, agent: s.agentName, folder: s.folder, branch: s.git?.branch, prompt: prompt))
        guard let data = try? JSONEncoder().encode(row),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func provider(_ agent: String?) -> String { AgTermWire.provider(agent: agent) }

    /// Thread list when it changes, upserts for finished agents (the relay turns those into
    /// "Agent finished" pushes), approvals for tabs that need you, and screens being watched.
    private func pushUpdates() {
        guard connection == .online else { return }
        let sessions = tabs()
        sessions.forEach(refreshTranscript)
        let rows = sessions.map(row)
        let options = newTabOptions(sessions)
        if let data = try? JSONSerialization.data(withJSONObject: [rows, options], options: .sortedKeys),
           let key = String(data: data, encoding: .utf8), key != lastThreads {
            lastThreads = key
            send(["type": "threads.snapshot", "threads": rows, "agterm": options])
        }
        for (s, row) in zip(sessions, rows) {
            let processing = s.status == .working
            if lastProcessing[s.tabID] == true, !processing { send(["type": "threads.upsert", "thread": row]) }
            lastProcessing[s.tabID] = processing
            if s.status == .waiting, approvals[s.tabID] == nil {
                let request = UUID().uuidString
                approvals[s.tabID] = request
                send(["type": "approval.requested", "threadId": s.tabID, "requestId": request,
                      "toolName": "Permission", "detail": Self.tail(s.screenText(), lines: 12)])
            } else if s.status != .waiting, let request = approvals.removeValue(forKey: s.tabID) {
                send(["type": "approval.resolved", "threadId": s.tabID, "requestId": request])
            }
        }
        let now = Date()
        chatLeases = chatLeases.filter { $0.value > now }
        subscribed.union(chatLeases.keys).forEach(sendTimeline)
    }

    /// Finds the tab's transcript and rebuilds its entries in the background when it changed.
    private func refreshTranscript(_ s: TerminalSession) {
        let id = s.tabID
        guard s.agentName == "claude" || s.agentName == "codex", !refreshing.contains(id) else {
            if s.agentName == nil { transcripts[id] = nil; transcriptPaths[id] = nil }
            return
        }
        let agent = s.agentName, session = s.claudeSessionID, cwd = s.cwd, start = s.agentStartedAt
        let known = transcriptPaths[id], cached = transcripts[id]
        refreshing.insert(id)
        reader.async { [weak self] in
            let path: URL? = {
                if agent == "claude", let session {
                    if let known, known.lastPathComponent == session + ".jsonl" { return known }
                    return TranscriptDiff.claudeTranscript(session)
                }
                if agent == "codex", let start { return known ?? TranscriptDiff.codexRollout(cwd: cwd, since: start) }
                return nil
            }()
            var result: Transcript?
            // Not URL.resourceValues: it caches on the URL, and `known` is reused, so the date never moved.
            if let path, let modified = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date {
                if let cached, cached.path == path, cached.modified == modified {
                    result = cached
                } else if let text = try? String(contentsOf: path, encoding: .utf8) {
                    let entries = agent == "claude" ? RemoteTimeline.claude(transcript: text) : RemoteTimeline.codex(rollout: text)
                    let model = agent == "claude" ? RemoteTimeline.modelLabel(claude: text) : RemoteTimeline.modelLabel(codex: text)
                    result = Transcript(path: path, modified: modified, entries: entries, model: model)
                }
            }
            Task { @MainActor in
                guard let self else { return }
                self.refreshing.remove(id)
                self.transcriptPaths[id] = path
                let changed = result?.modified != self.transcripts[id]?.modified || result?.model != self.transcripts[id]?.model
                self.transcripts[id] = result
                if changed {
                    self.lastThreads = ""
                    if self.subscribed.contains(id) || self.chatLeases[id] != nil { self.sendTimeline(id) }
                }
            }
        }
    }

    private func sendTimeline(_ thread: String) {
        guard let s = tab(thread) else { return }
        if let transcript = transcripts[thread], !transcript.entries.isEmpty {
            let encoder = JSONEncoder()
            var entries = transcript.entries.compactMap { try? JSONSerialization.jsonObject(with: encoder.encode($0)) }
            // The relay drops frames over 1 MiB; keep the newest entries that fit.
            while entries.count > 1, ((try? JSONSerialization.data(withJSONObject: entries))?.count ?? 0) > 900_000 {
                entries.removeFirst(max(1, entries.count / 10))
            }
            let digest = "t:\(transcript.path.path):\(transcript.modified.timeIntervalSince1970)"
            guard sentTimeline[thread] != digest else { return }
            sentTimeline[thread] = digest
            return send(["type": "timeline.snapshot", "threadId": thread, "entries": entries])
        }
        let screen = s.screenText()
        let digest = SHA256.hash(data: Data(screen.utf8)).map { String(format: "%02x", $0) }.joined()
        guard sentTimeline[thread] != digest else { return }
        sentTimeline[thread] = digest
        let fence = screen.contains("```") ? "~~~~" : "```"
        let entry: [String: Any] = ["id": "screen-" + thread, "kind": "assistant",
                                    "text": fence + "\n" + screen + "\n" + fence, "ts": Int(Date().timeIntervalSince1970 * 1000)]
        send(["type": "timeline.snapshot", "threadId": thread, "entries": [entry]])
    }

    /// Live screens for agterm Remote: frames only when the screen changed, until the lease runs out.
    private func pushScreens() {
        guard connection == .online, !screenLeases.isEmpty else { return }
        let now = Date()
        for (thread, expiry) in screenLeases where expiry < now {
            screenLeases[thread] = nil
            sentScreen[thread] = nil
        }
        screenLeases.keys.forEach(sendScreen)
    }

    private func sendScreen(_ thread: String) {
        guard let s = tab(thread), let data = try? JSONEncoder().encode(s.screenSnapshot()),
              let screen = try? JSONSerialization.jsonObject(with: data) else { return }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard sentScreen[thread] != digest else { return }
        sentScreen[thread] = digest
        send(["type": "timeline.snapshot", "threadId": AgTermWire.screenThread(thread), "entries": [], "screen": screen])
    }

    private static func tail(_ text: String, lines: Int) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
