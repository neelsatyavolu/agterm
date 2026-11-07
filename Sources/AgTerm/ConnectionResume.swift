import AgTermCore
import Foundation

/// Tells Claude Code to continue when a turn ended because the connection dropped, as soon as
/// Anthropic's API answers again:
/// 1. Each Claude tab's transcript is followed for the drop record (`ConnectionDrop`).
/// 2. While any tab has one, the API is checked every few seconds.
/// 3. Once it answers, a tab still sitting at its prompt, with nothing typed since the drop, gets
///    "Continue where you left off." typed in.
final class ConnectionResume {
    static let shared = ConnectionResume()
    static let enabledKey = "resumeAfterConnectionDrop"
    static let probeURL = URL(string: "https://api.anthropic.com/")!
    static let probeEvery: TimeInterval = 3
    /// A check this recent counts as the connection being back.
    static let freshFor: TimeInterval = 5
    /// At most this many resumes per tab in `window`, so a connection that keeps failing isn't retried forever.
    static let maxResumes = 5
    static let window: TimeInterval = 30 * 60

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// One tab's transcript and the drop in it still waiting; both used only on `queue`.
    private final class Watch {
        let key: String
        let tail: TranscriptTail
        let since: Date
        var drop: ConnectionDrop.Drop?

        init(key: String, tail: TranscriptTail, since: Date) {
            self.key = key
            self.tail = tail
            self.since = since
        }
    }

    private let queue = DispatchQueue(label: "agterm.connection-resume", qos: .utility)
    private var watches: [String: Watch] = [:]
    /// Each tab's waiting drop as last read on `queue`.
    private var waiting: [String: ConnectionDrop.Drop] = [:]
    /// Newest drop already resumed (or taken over by you) per tab, so it isn't resumed twice.
    private var handled: [String: Date] = [:]
    private var history: [String: [Date]] = [:]
    private var probing = false
    private var probedAt = Date.distantPast
    private var reachableAt: Date?
    private lazy var probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Called every second with the open tabs.
    func poll(_ sessions: [TerminalSession]) {
        guard Self.isEnabled else {
            watches = [:]; waiting = [:]
            return
        }
        let claude = sessions.filter { $0.agentName == "claude" }
        let open = Set(claude.map(\.tabID))
        for key in Set(watches.keys).union(waiting.keys).union(handled.keys).union(history.keys) where !open.contains(key) {
            watches[key] = nil; waiting[key] = nil; handled[key] = nil; history[key] = nil
        }
        for session in claude {
            follow(session)
            resumeIfReady(session)
        }
        if !waiting.isEmpty { probe() }
    }

    /// Reads what this tab's agent wrote since the last poll.
    private func follow(_ session: TerminalSession) {
        guard let sessionID = session.claudeSessionID, let started = session.agentStartedAt else { return }
        let tabID = session.tabID
        let key = sessionID + ":" + String(session.foregroundGroup ?? 0)
        if watches[tabID]?.key != key {
            // Finding the transcript scans folders, so only when the agent or conversation changes.
            guard let url = TranscriptDiff.claudeTranscript(sessionID) else { return }
            watches[tabID] = Watch(key: key, tail: TranscriptTail(url: url, backlog: AccountSwitcher.backlog),
                                   since: started.addingTimeInterval(-5))
            waiting[tabID] = nil
        }
        guard let watch = watches[tabID] else { return }
        queue.async {
            watch.drop = ConnectionDrop.fold(watch.tail.newLines().map(\.0.text), pending: watch.drop, since: watch.since)
            let drop = watch.drop
            DispatchQueue.main.async { [weak self] in
                guard let self, self.watches[tabID] === watch else { return }
                self.waiting[tabID] = drop
            }
        }
    }

    private func resumeIfReady(_ session: TerminalSession) {
        let tabID = session.tabID
        guard let drop = waiting[tabID], drop.timestamp > handled[tabID] ?? .distantPast else { return }
        // You typed in the tab since: it's yours to continue.
        if let input = session.signals.lastInput, input > drop.timestamp {
            handled[tabID] = drop.timestamp
            return
        }
        let now = Date()
        guard let reachableAt, reachableAt > drop.timestamp, now.timeIntervalSince(reachableAt) < Self.freshFor,
              session.signals.agentBusy != true, session.status != .working, !session.signals.promptVisible else { return }
        handled[tabID] = drop.timestamp
        let recent = (history[tabID] ?? []).filter { now.timeIntervalSince($0) < Self.window }
        guard recent.count < Self.maxResumes else {
            return Notifier.shared.post(title: "Claude Code lost its connection again",
                                        body: "agterm stopped continuing it after \(Self.maxResumes) tries in 30 minutes. \(drop.message)",
                                        tabID: tabID)
        }
        history[tabID] = recent + [now]
        // Same as typing from the phone: clear the line, type, wait, then Enter.
        session.view.send(txt: "\u{15}" + AccountSwitcher.continuePrompt)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak session] in session?.view.send(txt: "\r") }
        Notifier.shared.post(title: "Back online", body: "Claude Code lost its connection; agterm told it to continue.", tabID: tabID)
    }

    /// Any HTTP answer from the API, even an error status, means the connection is back.
    private func probe() {
        let now = Date()
        guard !probing, now.timeIntervalSince(probedAt) >= Self.probeEvery else { return }
        probing = true
        probedAt = now
        var request = URLRequest(url: Self.probeURL, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        probeSession.dataTask(with: request) { [weak self] _, response, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.probing = false
                if response is HTTPURLResponse { self.reachableAt = Date() }
            }
        }.resume()
    }
}
