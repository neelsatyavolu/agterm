import AgTermCore
import Foundation

/// Lines an agent changed, counted from its own transcript (the edits its tools made), the way
/// agmux counts them. Unlike a git snapshot this works in any folder, repo or not.
final class TranscriptDiff {
    private let queue = DispatchQueue(label: "agterm.transcript-diff", qos: .utility)
    private var inFlight = Set<String>()
    /// Parsed totals per transcript, reused while the file is unchanged.
    private var cache: [String: (modified: Date, added: Int, removed: Int)] = [:]
    private let lock = NSLock()

    /// Claude Code: the session's transcript under ~/.claude/projects.
    func claude(sessionID: String, completion: @escaping ((added: Int, removed: Int)?) -> Void) {
        run(key: "claude:" + sessionID, completion: completion) {
            guard let file = Self.claudeTranscript(sessionID) else { return nil }
            return self.total(file) { ClaudeTranscript.parse(lines: $0, sessionID: sessionID, fallbackDir: "") }
        }
    }

    /// Codex: the newest rollout started in agterm, in this folder, since the agent started.
    func codex(cwd: String, since start: Date, completion: @escaping ((added: Int, removed: Int)?) -> Void) {
        run(key: "codex:" + cwd, completion: completion) {
            guard let file = Self.codexRollout(cwd: cwd, since: start) else { return nil }
            return self.total(file) { CodexTranscript.parse(lines: $0, sessionID: file.deletingPathExtension().lastPathComponent) }
        }
    }

    private func run(key: String, completion: @escaping ((added: Int, removed: Int)?) -> Void,
                     work: @escaping () -> (added: Int, removed: Int)?) {
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

    private func total(_ file: URL, parse: (String) -> [UsageEvent]) -> (added: Int, removed: Int)? {
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        lock.lock()
        let hit = cache[file.path]
        lock.unlock()
        if let hit, hit.modified == modified { return (hit.added, hit.removed) }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let events = parse(text)
        let added = events.reduce(0) { $0 + $1.tools.linesAdded }, removed = events.reduce(0) { $0 + $1.tools.linesRemoved }
        lock.lock()
        cache[file.path] = (modified, added, removed)
        lock.unlock()
        return (added, removed)
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
                      created >= start.addingTimeInterval(-10),
                      let header = firstLine(file), CodexTranscript.originator(header: header) == "agterm",
                      header.contains("\"cwd\":\"\(cwd.replacingOccurrences(of: "/", with: "\\/"))\"") || header.contains("\"cwd\":\"\(cwd)\"")
                else { continue }
                candidates.append((file, created))
            }
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }

    private static func firstLine(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init)
    }
}
