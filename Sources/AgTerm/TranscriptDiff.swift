import AgTermCore
import Foundation

/// What a tab's agent has done so far, read from its transcript.
struct AgentUsage: Equatable {
    var added = 0
    var removed = 0
    /// The model of the latest turn, as the transcript names it.
    var model: String?
    /// Input and output tokens, not counting cache reads and writes.
    var tokens = 0
    var costUSD = 0.0
    /// Some turns couldn't be priced, so `costUSD` is too low.
    var costIncomplete = false

    init(added: Int = 0, removed: Int = 0) {
        self.added = added
        self.removed = removed
    }

    init(_ events: [UsageEvent]) {
        for event in events {
            added += event.tools.linesAdded
            removed += event.tools.linesRemoved
            tokens += event.tokensIn + event.tokensOut
            costUSD += event.costUSD
            costIncomplete = costIncomplete || event.costIncomplete
            if ModelName.short(event.model) != nil { model = event.model }
        }
    }
}

/// Lines an agent changed, counted from its own transcript (the edits its tools made), the way
/// agmux counts them. Unlike a git snapshot this works in any folder, repo or not.
final class TranscriptDiff {
    private let queue = DispatchQueue(label: "agterm.transcript-diff", qos: .utility)
    private var inFlight = Set<String>()
    /// Per transcript: how far it has been read, the parser's state there, and its events.
    /// Agents only append, so each poll reads just the new lines.
    private var tails: [String: (offset: UInt64, parser: any TranscriptLineParser, events: [UsageEvent])] = [:]
    /// Where each Claude session's transcript was found, so polls don't list ~/.claude/projects.
    private var claudePaths: [String: URL] = [:]
    /// Per transcript: how far it has been scanned for a title, and the scan so far.
    private var titles: [String: (offset: UInt64, scanner: ClaudeSessionTitle.Scanner)] = [:]
    private let lock = NSLock()

    /// Claude Code: the session's transcript under ~/.claude/projects, plus its subagents' and
    /// workflow agents' transcripts, whose tokens and edits are the session's too.
    func claude(sessionID: String, completion: @escaping (AgentUsage?) -> Void) {
        run(key: "claude:" + sessionID, completion: completion) {
            guard let file = self.claudeFile(sessionID),
                  let own = self.events(file, parser: { ClaudeTranscript.Parser(sessionID: sessionID, fallbackDir: "", prices: PriceList.current()) }) else { return nil }
            let helpers = ClaudeTranscript.subagentFiles(of: file).flatMap { child in
                self.events(child) { ClaudeTranscript.Parser(sessionID: sessionID, fallbackDir: "subagents", prices: PriceList.current()) } ?? []
            }
            var usage = AgentUsage(helpers.isEmpty ? own : ClaudeTranscript.reconcile(own + helpers))
            // The session's model, not whichever one a subagent ran last.
            usage.model = AgentUsage(own).model
            return usage
        }
    }

    /// Claude Code: the session's name from its transcript, for when the terminal title has none.
    func claudeTitle(sessionID: String, completion: @escaping (String?) -> Void) {
        run(key: "claude-title:" + sessionID, completion: completion) {
            guard let file = self.claudeFile(sessionID),
                  let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? UInt64 else { return nil }
            self.lock.lock()
            var scan = self.titles[file.path]
            self.lock.unlock()
            if let hit = scan, hit.offset == size { return hit.scanner.title }
            // A shorter file was replaced or rewritten: start over.
            if scan == nil || size < scan!.offset { scan = (0, ClaudeSessionTitle.Scanner()) }
            guard var (offset, scanner) = scan,
                  let end = TranscriptFile.read(file.path, from: offset, line: { scanner.feed($0) }) else { return nil }
            offset = end
            self.lock.lock()
            self.titles[file.path] = (offset, scanner)
            self.lock.unlock()
            return scanner.title
        }
    }

    /// Codex: the newest rollout started in agterm, in this folder, since the agent started.
    func codex(cwd: String, since start: Date, completion: @escaping (AgentUsage?) -> Void) {
        run(key: "codex:" + cwd, completion: completion) {
            guard let file = Self.codexRollout(cwd: cwd, since: start) else { return nil }
            return self.events(file) { CodexTranscript.Parser(sessionID: file.deletingPathExtension().lastPathComponent, prices: PriceList.current()) }.map(AgentUsage.init)
        }
    }

    private func run<T>(key: String, completion: @escaping (T) -> Void, work: @escaping () -> T) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        queue.async {
            let result = work()
            DispatchQueue.main.async {
                self.inFlight.remove(key)
                completion(result)
            }
        }
    }

    private func events(_ file: URL, parser makeParser: () -> any TranscriptLineParser) -> [UsageEvent]? {
        // Not URL.resourceValues: it caches on the URL, and cached URLs are reused.
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? UInt64 else { return nil }
        lock.lock()
        var tail = tails[file.path]
        lock.unlock()
        if let hit = tail, hit.offset == size { return hit.events }
        // A shorter file was replaced or rewritten: start over.
        if tail == nil || size < tail!.offset { tail = (0, makeParser(), []) }
        guard var (offset, parser, _) = tail,
              let end = TranscriptFile.read(file.path, from: offset, line: { parser.feed($0) }) else { return nil }
        offset = end
        let events = parser.events
        lock.lock()
        tails[file.path] = (offset, parser, events)
        lock.unlock()
        return events
    }

    private func claudeFile(_ sessionID: String) -> URL? {
        lock.lock()
        let known = claudePaths[sessionID]
        lock.unlock()
        if let known, FileManager.default.fileExists(atPath: known.path) { return known }
        let found = Self.claudeTranscript(sessionID)
        lock.lock()
        claudePaths[sessionID] = found
        lock.unlock()
        return found
    }

    static func claudeTranscript(_ sessionID: String) -> URL? {
        let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appendingPathComponent(sessionID + ".jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func codexRollout(cwd: String, since start: Date) -> URL? {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
        // Rollouts live in sessions/YYYY/MM/DD; only today's and yesterday's folders can be this run's.
        var candidates: [(URL, Date)] = []
        let calendar = Calendar.current
        for day in [start, calendar.date(byAdding: .day, value: 1, to: start) ?? start] {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = home.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
            where file.pathExtension == "jsonl" {
                guard let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate,
                      created >= start.addingTimeInterval(-10), isAgtermRollout(file, cwd: cwd)
                else { continue }
                candidates.append((file, created))
            }
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }

    /// What each rollout's header said, so a folder listed every few seconds is read once.
    nonisolated(unsafe) private static var headerVerdicts: [String: Bool] = [:]
    private static let headerLock = NSLock()

    /// True when the rollout was started by agterm in `cwd` (its header, which never changes).
    private static func isAgtermRollout(_ file: URL, cwd: String) -> Bool {
        let key = file.path + "\0" + cwd
        headerLock.lock()
        let cached = headerVerdicts[key]
        headerLock.unlock()
        if let cached { return cached }
        // A file Codex just made may not have its header yet: look again next time.
        guard let header = firstLine(file) else { return false }
        let verdict = CodexTranscript.originator(header: header) == "agterm"
            && (header.contains("\"cwd\":\"\(cwd.replacingOccurrences(of: "/", with: "\\/"))\"") || header.contains("\"cwd\":\"\(cwd)\""))
        guard verdict || header.hasSuffix("}") || header.utf8.count >= 128 * 1024 else { return false }
        headerLock.lock()
        headerVerdicts[key] = verdict
        headerLock.unlock()
        return verdict
    }

    private static func firstLine(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init)
    }
}
