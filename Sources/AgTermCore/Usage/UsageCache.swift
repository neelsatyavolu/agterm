import Foundation

/// The Usage window's events per transcript, kept on disk between launches so a relaunch reads
/// only transcripts that changed instead of every one from the last 30 days. Tab-separated lines,
/// compressed. A cache from another app version reads as empty, as a new build may price
/// differently; files with an unpriced event aren't kept, so a later price can still apply.
public enum UsageCache {
    public struct File: Equatable, Sendable {
        /// The transcript's modification date when it was read, as seconds since 2001 (Date's reference date).
        public var modified: Double
        public var events: [UsageEvent]

        public init(modified: Double, events: [UsageEvent]) {
            self.modified = modified
            self.events = events
        }
    }

    private static let magic = "agterm-usage-cache 1"

    public static func encode(_ files: [String: File], version: String) -> Data? {
        var lines = [magic + "\t" + version]
        for (path, file) in files where storable(path) && !file.events.contains(where: \.costIncomplete) {
            let rows = file.events.map(row)
            guard !rows.contains(nil) else { continue }
            lines.append("F\t\(path)\t\(file.modified)")
            lines += rows.compactMap { $0 }
        }
        return compress(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    public static func decode(_ data: Data, version: String) -> [String: File] {
        guard let plain = decompress(data) else { return [:] }
        let text = String(decoding: plain, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).makeIterator()
        guard lines.next().map(String.init) == magic + "\t" + version else { return [:] }
        var files: [String: File] = [:]
        var path: String?
        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            if fields.first == "F", fields.count == 3, let modified = Double(fields[2]) {
                path = String(fields[1])
                files[String(fields[1])] = File(modified: modified, events: [])
            } else if fields.first == "E", let path, let event = event(fields) {
                files[path]?.events.append(event)
            } else {
                return [:]
            }
        }
        return files
    }

    // LZFSE on macOS; Linux (cloud machines, which have no Usage window) keeps the text as it is.
    private static func compress(_ data: Data) -> Data? {
        #if canImport(Darwin)
        try? (data as NSData).compressed(using: .lzfse) as Data
        #else
        data
        #endif
    }

    private static func decompress(_ data: Data) -> Data? {
        #if canImport(Darwin)
        try? (data as NSData).decompressed(using: .lzfse) as Data
        #else
        data
        #endif
    }

    // MARK: One event per line

    private static func storable(_ text: String) -> Bool {
        !text.contains("\t") && !text.contains("\n")
    }

    /// E, at, provider, model, project, session, row key, in, out, cache read, cache write,
    /// reasoning, tool calls, cost, flags (turn, sidechain, subagent path, subagent).
    private static func row(_ e: UsageEvent) -> String? {
        let strings = [e.provider, e.model, e.projectKey, e.sessionID, e.claudeRowKey ?? ""]
        guard strings.allSatisfy(storable) else { return nil }
        let flags = [e.isTurn, e.isSidechain, e.isSubagentPath, e.subagent].map { $0 ? "1" : "0" }.joined()
        let numbers = [e.tokensIn, e.tokensOut, e.cacheRead, e.cacheWrite, e.reasoning, e.toolCalls].map(String.init)
        return (["E", String(e.at.timeIntervalSince1970)] + strings + numbers + [String(e.costUSD), flags]).joined(separator: "\t")
    }

    private static func event(_ f: [Substring]) -> UsageEvent? {
        guard f.count == 15, let at = Double(f[1]), let cost = Double(f[13]) else { return nil }
        let numbers = f[7...12].compactMap { Int($0) }
        let flags = Array(f[14])
        guard numbers.count == 6, flags.count == 4 else { return nil }
        var e = UsageEvent(at: Date(timeIntervalSince1970: at), provider: String(f[2]), model: String(f[3]),
                           projectKey: String(f[4]), sessionID: String(f[5]))
        e.claudeRowKey = f[6].isEmpty ? nil : String(f[6])
        (e.tokensIn, e.tokensOut, e.cacheRead, e.cacheWrite, e.reasoning, e.toolCalls) =
            (numbers[0], numbers[1], numbers[2], numbers[3], numbers[4], numbers[5])
        e.costUSD = cost
        (e.isTurn, e.isSidechain, e.isSubagentPath, e.subagent) = (flags[0] == "1", flags[1] == "1", flags[2] == "1", flags[3] == "1")
        return e
    }
}
