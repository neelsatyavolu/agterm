import AgTermCore
import Foundation

/// The conversations of a cloud machine's agents, for the phone's chat view: Claude Code's and
/// Codex's transcripts on this machine, read and rebuilt off the server's queue only when the
/// file changed. Called on the server's queue.
final class CloudPhoneTranscripts {
    private struct Transcript {
        var path: String
        var modified: Date
        /// Encoded entries, newest kept within the relay's frame limit.
        var entries: [Any]
        var model: String?
    }

    private let queue: DispatchQueue
    private let reader = DispatchQueue(label: "agterm.phone-transcripts", qos: .utility)
    private var cache: [String: Transcript] = [:]
    private var refreshing = Set<String>()

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func model(_ tabID: String) -> String? { cache[tabID]?.model }

    /// The entries and a digest that changes with them; nil when there is no transcript.
    func entries(_ tabID: String) -> ([Any], String)? {
        guard let transcript = cache[tabID], !transcript.entries.isEmpty else { return nil }
        return (transcript.entries, "t:\(transcript.path):\(transcript.modified.timeIntervalSince1970)")
    }

    /// Re-reads the session's transcript if its file changed; `changed` gets the tab id after.
    func refresh(_ session: HostedSession, changed: @escaping (String) -> Void) {
        let id = session.tabID, agent = session.status.agent, info = session.status.foreground
        guard agent == "claude" || agent == "codex" else {
            cache[id] = nil
            return
        }
        guard !refreshing.contains(id) else { return }
        let known = cache[id]
        refreshing.insert(id)
        reader.async { [weak self] in
            let conversation = agent == "claude" ? info?.claudeSessionID : info?.codexSessionID
            // Looking a file up walks folders; the one found last time is still it while the conversation is.
            let path = conversation.flatMap { conversation in
                if let known, known.path.hasSuffix(conversation + ".jsonl") { return known.path }
                return agent == "claude" ? Self.claudeTranscript(conversation) : Self.codexRollout(conversation)
            }
            let result: Transcript? = {
                guard let path, let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
                if let known, known.path == path, known.modified == modified { return known }
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
                let entries = agent == "claude" ? RemoteTimeline.claude(transcript: text) : RemoteTimeline.codex(rollout: text)
                let model = agent == "claude" ? RemoteTimeline.modelLabel(claude: text) : RemoteTimeline.modelLabel(codex: text)
                return Transcript(path: path, modified: modified, entries: Self.encode(entries), model: model)
            }()
            guard let self else { return }
            queue.async {
                self.refreshing.remove(id)
                let different = result?.modified != self.cache[id]?.modified || result?.model != self.cache[id]?.model
                self.cache[id] = result
                if different { changed(id) }
            }
        }
    }

    /// The relay drops frames over 1 MiB; keep the newest entries that fit.
    private static func encode(_ entries: [MobileTimelineEntry]) -> [Any] {
        let encoder = JSONEncoder()
        var objects = entries.compactMap { try? JSONSerialization.jsonObject(with: encoder.encode($0)) }
        while objects.count > 1, ((try? JSONSerialization.data(withJSONObject: objects))?.count ?? 0) > AgTermWire.frameBudget {
            objects.removeFirst(max(1, objects.count / 10))
        }
        return objects
    }

    private static func claudeTranscript(_ sessionID: String) -> String? {
        let projects = NSHomeDirectory() + "/.claude/projects"
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? []
        return dirs.map { "\(projects)/\($0)/\(sessionID).jsonl" }.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Codex names each rollout after its conversation: `sessions/YYYY/MM/DD/rollout-…-<id>.jsonl`.
    private static func codexRollout(_ sessionID: String) -> String? {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        let sessions = home + "/sessions"
        guard let files = FileManager.default.enumerator(atPath: sessions) else { return nil }
        let suffix = sessionID + ".jsonl"
        for case let file as String in files where file.hasSuffix(suffix) { return sessions + "/" + file }
        return nil
    }
}
