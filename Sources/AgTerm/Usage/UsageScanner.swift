import AgTermCore
import Foundation

/// Reads Claude Code and Codex transcripts from the last 30 days into a `UsageReport`, only when
/// the Usage window asks. Each file's parser and read position are kept between scans, so a
/// later scan reads only what was appended since; transcript text itself is never kept.
final class UsageScanner {
    static let shared = UsageScanner()

    /// One transcript as far as it has been read.
    private struct Entry {
        var parser: any TranscriptLineParser
        var offset: UInt64
        var modified: Date
    }

    private static let chunkSize = 1 << 20
    /// Touched only on `queue`.
    private var entries: [String: Entry] = [:]
    private let queue = DispatchQueue(label: "agterm.usage", qos: .utility)
    /// Main thread: callers waiting on the scan in progress.
    private var waiting: [(UsageReport) -> Void] = []

    #if DEBUG
    /// Self-test only: these events stand in for the transcripts.
    var stubEvents: [UsageEvent]?
    #endif

    /// Scans, then calls `completion` on the main queue. A call during a scan waits for that scan.
    func scan(completion: @escaping (UsageReport) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        waiting.append(completion)
        guard waiting.count == 1 else { return }
        #if DEBUG
        let stub = stubEvents
        #else
        let stub: [UsageEvent]? = nil
        #endif
        queue.async {
            let now = Date()
            let events = stub ?? self.readAll(now: now)
            let report = UsageReport.build(events: events, now: now, calendar: .current)
            DispatchQueue.main.async {
                let callers = self.waiting
                self.waiting = []
                callers.forEach { $0(report) }
            }
        }
    }

    // MARK: Reading (on `queue`)

    private func readAll(now: Date) -> [UsageEvent] {
        let cutoff = now.addingTimeInterval(-Double(UsageReport.dayCount + 1) * 86400)
        let prices = PriceList.current()
        var seen = Set<String>()
        var events: [UsageEvent] = []
        for file in Self.claudeFiles(cutoff: cutoff) {
            seen.insert(file.url.path)
            events += read(file.url, modified: file.modified) {
                ClaudeTranscript.Parser(sessionID: ClaudeTranscript.sessionID(fromPath: file.url.path),
                                        fallbackDir: file.projectDir, prices: prices)
            }
        }
        for file in Self.codexFiles(cutoff: cutoff) {
            seen.insert(file.url.path)
            events += read(file.url, modified: file.modified) {
                CodexTranscript.Parser(sessionID: file.url.deletingPathExtension().lastPathComponent, prices: prices)
            }
        }
        // Files that aged out or were deleted give their memory back.
        entries = entries.filter { seen.contains($0.key) }
        return events
    }

    /// The file's events, reading only the bytes added since the last scan. A file that shrank
    /// was rewritten, so it's read again from the start.
    private func read(_ url: URL, modified: Date, makeParser: () -> any TranscriptLineParser) -> [UsageEvent] {
        var entry = entries[url.path] ?? Entry(parser: makeParser(), offset: 0, modified: .distantPast)
        guard entry.modified != modified else { return entry.parser.events }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return entry.parser.events }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < entry.offset { entry = Entry(parser: makeParser(), offset: 0, modified: .distantPast) }
        var complete = true
        do {
            try handle.seek(toOffset: entry.offset)
            var pending = Data()
            while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                pending.append(chunk)
                let used = entry.parser.feed(chunk: pending)
                entry.offset += UInt64(used)
                pending = used == pending.count ? Data() : pending.subdata(in: used..<pending.count)
            }
        } catch {
            NSLog("agterm: couldn't read %@ for Usage: %@", url.path, String(describing: error))
            complete = false
        }
        // A failed read keeps the old date, so the next scan tries the rest of the file again.
        if complete { entry.modified = modified }
        entries[url.path] = entry
        return entry.parser.events
    }

    private struct Found {
        let url: URL
        let modified: Date
        /// Claude: the project folder, or `<project>/<session>/subagents` for a subagent's transcript.
        var projectDir = ""
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// `~/.claude/projects/<project>/<session>.jsonl` and `<project>/<session>/subagents/*.jsonl`.
    private static func claudeFiles(cutoff: Date) -> [Found] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        var found: [Found] = []
        for project in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: keys)) ?? [] {
            for item in (try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: keys)) ?? [] {
                if item.pathExtension == "jsonl" {
                    guard let date = modified(item), date >= cutoff else { continue }
                    found.append(Found(url: item, modified: date, projectDir: project.lastPathComponent))
                    continue
                }
                // A new subagent transcript touches subagents/, not the session folder above it.
                let subagents = item.appendingPathComponent("subagents")
                guard let listed = modified(subagents), listed >= cutoff else { continue }
                for file in (try? fm.contentsOfDirectory(at: subagents, includingPropertiesForKeys: keys)) ?? []
                where file.pathExtension == "jsonl" {
                    guard let date = modified(file), date >= cutoff else { continue }
                    let dir = project.lastPathComponent + "/" + item.lastPathComponent + "/subagents"
                    found.append(Found(url: file, modified: date, projectDir: dir))
                }
            }
        }
        return found
    }

    /// Every rollout under `$CODEX_HOME/sessions` (or `~/.codex/sessions`).
    private static func codexFiles(cutoff: Date) -> [Found] {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex")
        let sessions = home.appendingPathComponent("sessions")
        guard let walker = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var found: [Found] = []
        for case let file as URL in walker where file.pathExtension == "jsonl" {
            guard let date = modified(file), date >= cutoff else { continue }
            found.append(Found(url: file, modified: date))
        }
        return found
    }
}
