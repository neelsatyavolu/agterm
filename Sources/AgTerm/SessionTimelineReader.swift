import AgTermCore
import Foundation

/// Reads Session Timeline turns from Claude Code, Codex and Grok transcripts off the main
/// thread. Agents only append, so each file is read from where the last read stopped; nothing
/// runs unless the timeline asks (it asks while it's open).
final class SessionTimelineReader {
    static let shared = SessionTimelineReader()

    /// Where a tab's agent writes its conversation.
    enum Source: Equatable {
        case claude(sessionID: String)
        case codex(rollout: URL)
        case grok(sessionID: String)
    }

    private let queue = DispatchQueue(label: "agterm.session-timeline", qos: .userInitiated)
    /// Per file, on `queue`: how far it has been read and the parser's state there.
    private var tails: [String: (offset: UInt64, feed: any SessionTimelineFeed)] = [:]
    private var claudeFiles: [String: URL] = [:]
    private var grokDirs: [String: URL] = [:]

    /// The tab's transcript, when its agent is one the timeline reads and agterm knows which
    /// conversation it's in. Main thread: it reads the tab.
    static func source(for session: TerminalSession) -> Source? {
        guard !session.isCloud else { return nil }
        switch session.agentName {
        case "claude":
            return session.claudeSessionID.map { .claude(sessionID: $0) }
        case "codex":
            if let open = session.codexRollout { return .codex(rollout: URL(fileURLWithPath: open)) }
            return session.agentStartedAt.flatMap { TranscriptDiff.codexRollout(cwd: session.cwd, since: $0) }.map { .codex(rollout: $0) }
        case "grok":
            if let id = session.agentConversationID { return .grok(sessionID: id) }
            guard let started = session.agentStartedAt else { return nil }
            let sessions = AccountStore.nativeGrokHome.appendingPathComponent("sessions")
            return GrokSessions.written(in: sessions, cwd: session.cwd, since: started.addingTimeInterval(-5)).map { .grok(sessionID: $0) }
        default:
            return nil
        }
    }

    /// The source's turns, oldest first; nil when its files can't be found (yet).
    func turns(_ source: Source, completion: @escaping ([SessionTimelineTurn]?) -> Void) {
        queue.async {
            let turns = self.read(source)
            DispatchQueue.main.async { completion(turns) }
        }
    }

    private func read(_ source: Source) -> [SessionTimelineTurn]? {
        switch source {
        case .claude(let id):
            guard let file = claudeFile(id) else { return nil }
            return tail(file, SessionTimelineClaude.init)?.turns
        case .codex(let rollout):
            return tail(rollout, SessionTimelineCodex.init)?.turns
        case .grok(let id):
            guard let dir = grokDir(id),
                  let prompts = tail(dir.appendingPathComponent("chat_history.jsonl"), SessionTimelineGrok.Prompts.init) else { return nil }
            let events = tail(dir.appendingPathComponent("events.jsonl"), SessionTimelineGrok.Events.init) ?? .init()
            return SessionTimelineGrok.merge(prompts, events, sessionID: id)
        }
    }

    /// Feeds the bytes added to `file` since the last read; starts over if it got shorter.
    private func tail<P: SessionTimelineFeed>(_ file: URL, _ make: () -> P) -> P? {
        // Not URL.resourceValues: it caches on the URL.
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? UInt64 else { return nil }
        let known = tails[file.path]
        if let known, known.offset == size, let feed = known.feed as? P { return feed }
        var offset: UInt64 = 0
        var feed = make()
        if let known, known.offset < size, let previous = known.feed as? P {
            offset = known.offset
            feed = previous
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let chunk = try? handle.readToEnd() else { return nil }
        offset += UInt64(feed.feed(chunk: chunk))
        tails[file.path] = (offset, feed)
        return feed
    }

    private func claudeFile(_ id: String) -> URL? {
        if let known = claudeFiles[id], FileManager.default.fileExists(atPath: known.path) { return known }
        let found = TranscriptDiff.claudeTranscript(id)
        claudeFiles[id] = found
        return found
    }

    /// Grok keeps each conversation in `sessions/<folder>/<id>/`; every login shares your folder.
    private func grokDir(_ id: String) -> URL? {
        if let known = grokDirs[id] { return known }
        let sessions = AccountStore.nativeGrokHome.appendingPathComponent("sessions")
        let folders = (try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? []
        let found = folders.map { $0.appendingPathComponent(id, isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("chat_history.jsonl").path) }
        if let found { grokDirs[id] = found }
        return found
    }
}
