import Foundation

/// Every past conversation's searchable text, kept current cheaply: a transcript whose size and
/// date haven't changed isn't opened, one that grew is read only from where reading stopped, and
/// the result is cached on disk so the next launch starts from it. Not thread-safe: use one
/// instance from one queue.
public final class ConversationIndex {
    /// Newest first.
    public private(set) var records: [ConversationRecord] = []
    private let cacheURL: URL?
    private var loaded = false

    public init(cacheURL: URL?) {
        self.cacheURL = cacheURL
    }

    private struct Cache: Codable {
        static let version = 1
        let version: Int
        let records: [ConversationRecord]
    }

    /// A transcript file found on disk.
    struct Found {
        let agent: AccountProvider
        let path: String
        let id: String
        let account: String?
        let size: Int64
        let modified: Date
    }

    /// Reads what's on disk under `roots` into `records`. `codexTitles` are session_index.jsonl
    /// files. `progress` gets the records so far, newest first, while a long first read runs.
    public func refresh(roots: [ConversationRoot], codexTitles: [URL] = [], isCancelled: () -> Bool = { false },
                        progress: (_ records: [ConversationRecord], _ done: Int, _ total: Int) -> Void = { _, _, _ in }) {
        loadCache()
        let found = Self.scan(Self.unique(roots)).sorted { $0.modified > $1.modified }
        var known = Dictionary(records.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [ConversationRecord] = []
        next.reserveCapacity(found.count)
        var changed = found.count != records.count, lastReport = Date()
        for (n, file) in found.enumerated() {
            if isCancelled() {
                // Keep what was read so far; the rest is read next time.
                records = (next + known.values).sorted { $0.modified > $1.modified }
                if changed { saveCache() }
                return
            }
            let old = known.removeValue(forKey: file.path)
            let record = Self.updated(old, file)
            if record != old { changed = true }
            next.append(record)
            if changed, Date().timeIntervalSince(lastReport) > 0.5 {
                lastReport = Date()
                progress(next + known.values.sorted { $0.modified > $1.modified }, n + 1, found.count)
            }
        }
        let names = codexTitles.reduce(into: [String: String]()) { names, url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            names.merge(ConversationParser.codexThreadNames(text)) { _, new in new }
        }
        records = next.map { record in
            guard record.agent == .codex, let name = names[record.id] else { return record }
            var named = record
            named.title = name
            return named
        }
        if changed { saveCache() }
    }

    /// Drops the records from memory; the cache on disk stays for next time.
    public func unload() {
        records = []
        loaded = false
    }

    // MARK: Reading transcripts

    static func updated(_ old: ConversationRecord?, _ file: Found) -> ConversationRecord {
        if let old, old.size == file.size, old.modified == file.modified, old.account == file.account { return old }
        var record: ConversationRecord
        if let old, file.size > old.size, old.parsed <= file.size, old.account == file.account {
            // Transcripts only grow: read just the new lines.
            record = old
        } else {
            record = ConversationRecord(agent: file.agent, id: file.id, path: file.path, account: file.account,
                                        modified: file.modified, size: file.size)
        }
        record.size = file.size
        record.modified = file.modified
        record.parsed = readLines(file.path, from: record.parsed) { ConversationParser.absorb($0, into: &record) }
        if file.agent == .grok {
            let dir = (file.path as NSString).deletingLastPathComponent
            if let data = FileManager.default.contents(atPath: dir + "/summary.json") {
                let summary = ConversationParser.grokSummary(data)
                record.folder = summary.folder ?? record.folder
                record.title = summary.title ?? record.title
            }
            if record.folder == nil {
                record.folder = ((dir as NSString).deletingLastPathComponent as NSString).lastPathComponent.removingPercentEncoding
            }
        }
        return record
    }

    /// Calls `body` with each complete line from `offset` on; returns where the last one ends.
    static func readLines(_ path: String, from offset: Int64, _ body: (Data) -> Void) -> Int64 {
        guard let handle = FileHandle(forReadingAtPath: path) else { return offset }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: UInt64(offset)) } catch { return offset }
        var consumed = offset
        var buffer = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            buffer.append(chunk)
            var start = buffer.startIndex
            while let newline = buffer[start...].firstIndex(of: 0x0A) {
                if newline > start { body(buffer[start..<newline]) }
                start = newline + 1
            }
            consumed += Int64(start - buffer.startIndex)
            buffer = Data(buffer[start...])
        }
        return consumed
    }

    // MARK: Finding transcripts

    /// Each folder once, however many logins link to it.
    static func unique(_ roots: [ConversationRoot]) -> [ConversationRoot] {
        var seen = Set<String>()
        return roots.filter { seen.insert($0.url.resolvingSymlinksInPath().path).inserted }
    }

    static func scan(_ roots: [ConversationRoot]) -> [Found] {
        var seen = Set<String>()
        var found: [Found] = []
        for root in roots {
            for (path, id) in transcripts(root) {
                // A Grok folder can be a link to another one.
                let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                guard seen.insert(real).inserted, let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = (attributes[.size] as? NSNumber)?.int64Value, let modified = attributes[.modificationDate] as? Date
                else { continue }
                found.append(Found(agent: root.agent, path: path, id: id, account: root.account, size: size, modified: modified))
            }
        }
        return found
    }

    /// (path, session id) of every transcript under a root.
    private static func transcripts(_ root: ConversationRoot) -> [(String, String)] {
        let fm = FileManager.default
        let base = root.url.resolvingSymlinksInPath().path
        func children(_ dir: String) -> [String] { ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { !$0.hasPrefix(".") } }
        switch root.agent {
        case .claude:
            // projects/<folder>/<id>.jsonl; subagents' transcripts sit a level deeper and are skipped.
            return children(base).flatMap { project in
                children(base + "/" + project).filter { $0.hasSuffix(".jsonl") }
                    .map { (base + "/" + project + "/" + $0, String($0.dropLast(".jsonl".count))) }
            }
        case .codex:
            // sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl; the id is read from its first line too.
            guard let walk = fm.enumerator(atPath: base) else { return [] }
            var files: [(String, String)] = []
            while let item = walk.nextObject() as? String {
                let name = (item as NSString).lastPathComponent
                guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
                let stem = name.dropLast(".jsonl".count)
                files.append((base + "/" + item, String(stem.suffix(36))))
            }
            return files
        case .grok:
            // sessions/<folder, percent-encoded>/<id>/chat_history.jsonl
            return children(base).flatMap { folder in
                children(base + "/" + folder).compactMap { id in
                    let path = base + "/" + folder + "/" + id + "/chat_history.jsonl"
                    return fm.fileExists(atPath: path) ? (path, id) : nil
                }
            }
        }
    }

    // MARK: Cache

    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let cache = try? PropertyListDecoder().decode(Cache.self, from: data), cache.version == Cache.version else { return }
        records = cache.records
    }

    private func saveCache() {
        guard let cacheURL else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(Cache(version: Cache.version, records: records)) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }
}
