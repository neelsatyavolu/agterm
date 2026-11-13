import AgTermCore
import Foundation

/// Reads Claude Code and Codex transcripts from the last 30 days into a `UsageReport`, a file per
/// core, once shortly after launch and whenever the Usage window asks. Each file's parser and read
/// position are kept between scans, so a later scan reads only what was appended since, and each
/// file's events are kept on disk (`UsageCache`), so a relaunch reads only transcripts that
/// changed. Transcript text itself is never kept.
final class UsageScanner {
    static let shared = UsageScanner()

    /// One transcript as far as it has been read.
    private struct Entry {
        var parser: any TranscriptLineParser
        var offset: UInt64
        var modified: Date
    }

    /// A transcript's events as the disk cache had them. Its parser state isn't kept, so if the
    /// file changes it's read again from the start.
    private struct CachedEvents: TranscriptLineParser {
        let events: [UsageEvent]
        mutating func feed(_ line: String) {}
    }

    private static let chunkSize = 1 << 20
    /// Touched only on `queue`.
    private var entries: [String: Entry] = [:]
    private var loadedDiskCache = false
    /// On `queue`: entries changed since the disk cache was last written, and when that was.
    private var unsaved = false
    private var savedAt: Date?
    /// Writing the cache takes seconds, so it's written at most this often; what changed since
    /// is read again from the transcripts at the next launch.
    private static let saveInterval: TimeInterval = 600
    private let queue = DispatchQueue(label: "agterm.usage", qos: .utility)
    /// Main thread: callers waiting on the scan in progress.
    private var waiting: [(UsageReport) -> Void] = []
    /// Main thread: the latest report and when it was made, shown while the next scan runs.
    private(set) var lastReport: (report: UsageReport, at: Date)?

    private static var cacheURL: URL { AgentIntegration.supportDir.appendingPathComponent("usage-cache.lzfse") }
    private static var cacheVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "dev") \(info?["CFBundleVersion"] as? String ?? "")"
    }

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
                self.lastReport = (report, Date())
                let callers = self.waiting
                self.waiting = []
                callers.forEach { $0(report) }
            }
            if stub == nil { self.saveDiskCacheIfDue() }
        }
    }

    // MARK: Reading (on `queue`)

    /// One transcript to bring up to date.
    private struct Job {
        let found: Found
        /// Feed only lines containing `"usage"`: Claude puts tokens on no other line, and the
        /// rest, mostly multi-megabyte tool output, would take most of the time.
        let usageLinesOnly: Bool
        let makeParser: () -> any TranscriptLineParser
    }

    private static let usageNeedle = Array("\"usage\"".utf8)

    private func readAll(now: Date) -> [UsageEvent] {
        let cutoff = now.addingTimeInterval(-Double(UsageReport.dayCount + 1) * 86400)
        let prices = PriceList.current()
        let claude = Self.claudeFiles(cutoff: cutoff).map { file in
            Job(found: file, usageLinesOnly: true) {
                ClaudeTranscript.Parser(sessionID: ClaudeTranscript.sessionID(fromPath: file.url.path),
                                        fallbackDir: file.projectDir, prices: prices)
            }
        }
        let codex = Self.codexFiles(cutoff: cutoff).map { file in
            Job(found: file, usageLinesOnly: false) {
                CodexTranscript.Parser(sessionID: file.url.deletingPathExtension().lastPathComponent, prices: prices)
            }
        }
        let jobs = claude + codex
        if !loadedDiskCache {
            loadedDiskCache = true
            entries.merge(Self.loadDiskCache()) { current, _ in current }
        }
        let previous = entries
        // Files are independent, so they're read on every core; each slot is written by one iteration.
        var read = [Entry?](repeating: nil, count: jobs.count)
        read.withUnsafeMutableBufferPointer { slots in
            DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
                slots[i] = Self.read(jobs[i], previous: previous[jobs[i].found.url.path])
            }
        }
        // Files that aged out or were deleted give their memory back.
        var kept: [String: Entry] = [:]
        var events: [UsageEvent] = []
        var changed = previous.count != jobs.count
        for (job, entry) in zip(jobs, read) {
            guard let entry else { continue }
            kept[job.found.url.path] = entry
            events += entry.parser.events
            if previous[job.found.url.path]?.modified != entry.modified { changed = true }
        }
        entries = kept
        if changed { unsaved = true }
        return events
    }

    // MARK: Disk cache

    private static func loadDiskCache() -> [String: Entry] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [:] }
        return UsageCache.decode(data, version: cacheVersion).mapValues {
            Entry(parser: CachedEvents(events: $0.events), offset: 0, modified: Date(timeIntervalSinceReferenceDate: $0.modified))
        }
    }

    /// On `queue`, after a scan has handed back its report.
    private func saveDiskCacheIfDue() {
        guard unsaved, savedAt.map({ Date().timeIntervalSince($0) >= Self.saveInterval }) ?? true else { return }
        unsaved = false
        savedAt = Date()
        // Off this queue, so a scan never waits behind the write; entries are values, so this is a snapshot.
        let snapshot = entries
        DispatchQueue.global(qos: .background).async { Self.saveDiskCache(snapshot) }
    }

    private static func saveDiskCache(_ entries: [String: Entry]) {
        // Seconds since 2001, Date's own reference: they come back as the same Date, so an
        // unchanged transcript compares equal. (Via 1970 about half of them don't.)
        let files = entries.mapValues { UsageCache.File(modified: $0.modified.timeIntervalSinceReferenceDate, events: $0.parser.events) }
        guard let data = UsageCache.encode(files, version: cacheVersion) else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            NSLog("agterm: couldn't save the Usage cache: %@", String(describing: error))
        }
    }

    /// The file brought up to date, reading only the bytes added since the last scan. A file
    /// that shrank was rewritten, so it's read again from the start.
    private static func read(_ job: Job, previous: Entry?) -> Entry? {
        let url = job.found.url
        var entry = previous ?? Entry(parser: job.makeParser(), offset: 0, modified: .distantPast)
        guard entry.modified != job.found.modified else { return entry }
        if entry.parser is CachedEvents { entry = Entry(parser: job.makeParser(), offset: 0, modified: .distantPast) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return previous }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < entry.offset { entry = Entry(parser: job.makeParser(), offset: 0, modified: .distantPast) }
        var complete = true
        do {
            try handle.seek(toOffset: entry.offset)
            var pending = Data()
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                pending.append(chunk)
                let used = feedLines(pending, to: &entry.parser, onlyWith: job.usageLinesOnly ? usageNeedle : nil)
                entry.offset += UInt64(used)
                pending = used == pending.count ? Data() : pending.subdata(in: used..<pending.count)
            }
        } catch {
            NSLog("agterm: couldn't read %@ for Usage: %@", url.path, String(describing: error))
            complete = false
        }
        // A failed read keeps the old date, so the next scan tries the rest of the file again.
        if complete { entry.modified = job.found.modified }
        return entry
    }

    /// Feeds `parser` each complete line in `data` (only those containing `needle`, when given)
    /// and returns the bytes used: up to and including the last newline.
    private static func feedLines(_ data: Data, to parser: inout any TranscriptLineParser, onlyWith needle: [UInt8]?) -> Int {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var start = 0
            while start < raw.count, let newline = memchr(base + start, 0x0A, raw.count - start) {
                let end = base.distance(to: UnsafeRawPointer(newline))
                let length = end - start
                if needle.map({ memmem(base + start, length, $0, $0.count) != nil }) ?? true {
                    parser.feed(String(decoding: UnsafeRawBufferPointer(start: base + start, count: length), as: UTF8.self))
                }
                start = end + 1
            }
            return start
        }
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

    /// `~/.claude/projects/<project>/<session>.jsonl` and every `.jsonl` under `<project>/<session>/subagents`
    /// (workflow agents sit in `subagents/workflows/<run>/`).
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
                // A new subagent transcript touches subagents/, not the session folder above it; a
                // workflow's agents touch subagents/workflows/<run>/, and finishing writes the session's file.
                let subagents = item.appendingPathComponent("subagents")
                let touched = [modified(subagents), modified(item.appendingPathExtension("jsonl"))].compactMap { $0 }.max()
                guard let touched, touched >= cutoff else { continue }
                for file in ClaudeTranscript.subagentFiles(of: item.appendingPathExtension("jsonl")) {
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
