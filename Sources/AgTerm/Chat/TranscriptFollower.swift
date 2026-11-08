import AgTermCore
import AgTermSessionKit
import Foundation

/// Finds a tab's agent transcript and reads it as it grows: only the bytes appended since the
/// last read, and nothing at all while the file's size and date are unchanged. A different
/// file (Claude's `/clear`, Codex's `/new`, a new Grok conversation) or a shorter one starts
/// over. Shared by the phone remote and the Chat view. Use each instance from one queue at a time.
final class TranscriptFollower: @unchecked Sendable {
    /// What identifies the tab's conversation, captured on the main thread.
    struct Target: Equatable, Sendable {
        var agent: TimelineFeed.Agent
        var claudeSession: String?
        var cwd: String
        /// When the agent started: Codex and Grok files written before it aren't this run's.
        var since: Date?
        /// The agent's process group: Codex holds its rollout open, which finds a resumed one.
        var group: pid_t?
        /// The Grok conversation agterm started or resumed for this run (`--session-id`, `--resume`, `-c`).
        var grokSession: String?
        /// The Codex session this run resumed (`codex resume <id>`), whose rollout is older than the run.
        var codexSession: String?
        /// Grok: when typing in the tab stopped since the agent started, which tells this tab's
        /// `/new` from a conversation started elsewhere in the same folder.
        var typing: [Date] = []
        /// A file to read instead of looking (self-tests).
        var fixed: URL?

        /// The tab's agent, when agterm can read its transcript on this Mac.
        @MainActor init?(_ session: TerminalSession) {
            guard !session.isCloud, let name = session.agentName, let agent = TimelineFeed.Agent(rawValue: name) else { return nil }
            let since = session.agentStartedAt
            let launched = agent == .claude ? nil : TranscriptFollower.launchSession(tabID: session.tabID, agent: agent, since: since)
            self.init(agent: agent, claudeSession: session.claudeSessionID, cwd: session.cwd, since: since,
                      group: agent == .codex ? session.foregroundGroup : nil,
                      grokSession: agent == .grok ? launched : nil, codexSession: agent == .codex ? launched : nil,
                      typing: agent == .grok ? session.typingStops.filter { stop in since.map { stop >= $0 } ?? false } : [])
        }

        init(agent: TimelineFeed.Agent, claudeSession: String? = nil, cwd: String, since: Date? = nil, group: pid_t? = nil,
             grokSession: String? = nil, codexSession: String? = nil, typing: [Date] = [], fixed: URL? = nil) {
            self.agent = agent
            self.claudeSession = claudeSession
            self.cwd = cwd
            self.since = since
            self.group = group
            self.grokSession = grokSession
            self.codexSession = codexSession
            self.typing = typing
            self.fixed = fixed
        }
    }

    /// Codex and Grok start a new file for a new conversation without telling agterm, so the
    /// folder is listed again this often.
    static let relocateInterval: TimeInterval = 3
    /// A transcript bigger than this is read from its last this-many bytes (the latest turns),
    /// so a session with hundreds of megabytes of history still opens at once.
    static let tailBytes = 8 * 1024 * 1024

    private(set) var path: URL?
    private(set) var feed: TimelineFeed?
    /// Bumped whenever `feed` changes, so readers can tell an update from a repeat.
    private(set) var version = 0
    private var size: UInt64 = 0
    private var modified: Date?
    private var target: Target?
    private var locatedAt = Date.distantPast

    var entries: [MobileTimelineEntry] { feed?.entries ?? [] }
    var model: String? { feed?.model }

    /// Reads whatever is new; true when the entries may have changed.
    @discardableResult
    func refresh(_ target: Target, now: Date = Date()) -> Bool {
        let due = now.timeIntervalSince(locatedAt) >= Self.relocateInterval && (path == nil || target.agent != .claude)
        if target != self.target || due {
            let sameRun = self.target.map { $0.agent == target.agent && $0.since == target.since && $0.cwd == target.cwd } ?? false
            self.target = target
            locatedAt = now
            let found = Self.locate(target, following: sameRun ? path : nil)
            // A lookup that finds nothing for the same run (Codex closed its rollout) keeps the file.
            if found != path, found != nil || !sameRun {
                path = found
                return restart()
            }
        }
        guard let path, let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let fileSize = attributes[.size] as? UInt64 else { return false }
        let fileDate = attributes[.modificationDate] as? Date
        if fileSize == size, fileDate == modified { return false }
        guard let handle = try? FileHandle(forReadingFrom: path) else { return false }
        defer { try? handle.close() }
        var changed = false
        if feed == nil || fileSize < UInt64(feed!.offset) {
            feed = TimelineFeed(agent: target.agent, offset: Self.firstLineStart(handle, from: fileSize))
            changed = true
        }
        size = fileSize
        modified = fileDate
        guard var current = feed else { return changed }
        guard (try? handle.seek(toOffset: UInt64(current.offset))) != nil, let chunk = try? handle.readToEnd(), !chunk.isEmpty
        else { return bump(changed) }
        changed = current.feed(chunk: chunk) > 0 || changed
        feed = current
        return bump(changed)
    }

    /// Where reading starts: 0, or for a big file the first whole line in its last `tailBytes`.
    static func firstLineStart(_ handle: FileHandle, from size: UInt64, tail: Int = tailBytes) -> Int {
        guard size > UInt64(tail) else { return 0 }
        let start = size - UInt64(tail)
        guard (try? handle.seek(toOffset: start)) != nil,
              let window = try? handle.read(upToCount: 1 << 20), let newline = window.firstIndex(of: 0x0A) else { return 0 }
        return Int(start) + (newline - window.startIndex) + 1
    }

    private func restart() -> Bool {
        feed = nil
        size = 0
        modified = nil
        if let target, path != nil { _ = refresh(target, now: locatedAt) }
        version += 1
        return true
    }

    private func bump(_ changed: Bool) -> Bool {
        if changed { version += 1 }
        return changed
    }

    /// Where the target's conversation is written.
    static func locate(_ target: Target, following: URL? = nil) -> URL? {
        if let fixed = target.fixed { return fixed }
        switch target.agent {
        case .claude:
            return target.claudeSession.flatMap(TranscriptDiff.claudeTranscript)
        case .codex:
            // The rollout Codex holds open: also a resumed session's, which was created long before.
            if let group = target.group,
               let open = ProcInfo.openFiles(group: group, matching: { $0.contains("/sessions/") && $0.hasSuffix(".jsonl") && $0.contains("rollout-") }).first {
                return URL(fileURLWithPath: open)
            }
            // A new rollout since the run started (a fresh session, `/new`), else the resumed one.
            return target.since.flatMap { TranscriptDiff.codexRollout(cwd: target.cwd, since: $0) }
                ?? target.codexSession.flatMap(codexRollout(sessionID:))
        case .grok:
            return locateGrok(target, following: following)
        }
    }

    // MARK: Grok

    /// Every login shares your own sessions folder. A run agterm named follows that conversation
    /// (even a resumed one nothing has written to yet); `GrokSessions.follow` says when it moves on.
    private static func locateGrok(_ target: Target, following: URL?) -> URL? {
        let sessions = AccountStore.nativeGrokHome.appendingPathComponent("sessions")
        let own = target.grokSession.flatMap { GrokSessions.chatHistory(in: sessions, cwd: target.cwd, sessionID: $0) }
        guard let since = target.since?.addingTimeInterval(-5) else { return own }
        let id = GrokSessions.follow(in: sessions, cwd: target.cwd, own: target.grokSession, since: since,
                                     others: otherGrokSessions(than: target.grokSession), inputs: target.typing,
                                     following: following?.deletingLastPathComponent().lastPathComponent)
        return id.flatMap { GrokSessions.chatHistory(in: sessions, cwd: target.cwd, sessionID: $0) }
    }

    // MARK: Launch records

    private static let launchCache = NSCache<NSString, NSString>()
    private static let rolloutCache = NSCache<NSString, NSURL>()

    /// A resumed Codex session's rollout (found once: it doesn't move).
    private static func codexRollout(sessionID: String) -> URL? {
        if let hit = rolloutCache.object(forKey: sessionID as NSString) { return hit as URL }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
        guard let found = CodexSessions.rollout(in: home.appendingPathComponent("sessions"), sessionID: sessionID) else { return nil }
        rolloutCache.setObject(found as NSURL, forKey: sessionID as NSString)
        return found
    }

    /// The conversation agterm's wrapper recorded for this tab's Grok or Codex run (cached per run).
    static func launchSession(tabID: String, agent: TimelineFeed.Agent, since: Date?) -> String? {
        guard let since, let provider = AccountProvider(rawValue: agent.rawValue) else { return nil }
        let key = "\(tabID)-\(agent.rawValue)@\(since.timeIntervalSince1970)" as NSString
        if let hit = launchCache.object(forKey: key) { return hit.length == 0 ? nil : hit as String }
        let launch = AccountStore.launch(tabID: tabID, provider: provider)
        let id = launch.flatMap { abs($0.startedAt.timeIntervalSince(since)) < 20 ? $0.sessionID : nil }
        launchCache.setObject((id ?? "") as NSString, forKey: key)
        return id
    }

    /// Conversations other agterm tabs' Grok runs were started in.
    private static func otherGrokSessions(than own: String?) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: AccountStore.launchesDir, includingPropertiesForKeys: nil)) ?? []
        let ids = files.filter { $0.lastPathComponent.hasSuffix("-grok.json") }.compactMap { url -> String? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode(TabLaunch.self, from: data))?.sessionID
        }
        return Set(ids).subtracting([own].compactMap { $0 })
    }
}
