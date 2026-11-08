import Foundation

/// A conversation that matches, with the bit of it around the first match.
public struct ConversationHit: Equatable, Sendable {
    public let record: ConversationRecord
    /// Empty when only the title or folder matched (or there's no query).
    public let snippet: String
}

/// Finds conversations containing every word you typed, in any letter case (ASCII), in their
/// text, title or folder. Plain byte scans over text already in memory: no index to keep current.
public enum ConversationSearch {
    /// The words of a query, lowercased.
    public static func terms(_ query: String) -> [[UInt8]] {
        query.split(whereSeparator: \.isWhitespace).map { Array($0.lowercased().utf8) }
    }

    /// `records` newest first; `emit` gets hits in that order, a batch at a time. Stops at `limit`
    /// hits, or as soon as `isCancelled` says the query is stale.
    public static func run(_ query: String, in records: [ConversationRecord], limit: Int = 200, batch: Int = 30,
                           isCancelled: () -> Bool = { false }, emit: ([ConversationHit]) -> Void) {
        let words = terms(query)
        var pending: [ConversationHit] = [], found = 0
        for (n, record) in records.enumerated() {
            if n % 64 == 0, isCancelled() { return }
            guard let hit = match(record, words) else { continue }
            pending.append(hit)
            found += 1
            if found >= limit { break }
            if pending.count >= batch {
                emit(pending)
                pending.removeAll()
            }
        }
        if !pending.isEmpty, !isCancelled() { emit(pending) }
    }

    public static func match(_ record: ConversationRecord, _ words: [[UInt8]]) -> ConversationHit? {
        guard !record.text.isEmpty || record.title != nil else { return nil }
        if words.isEmpty { return ConversationHit(record: record, snippet: "") }
        let label = Array((record.displayTitle + "\n" + (record.folder ?? "")).utf8)
        var first: Int?
        for word in words {
            let inText = record.text.withUnsafeBytes { find(word, in: $0.bindMemory(to: UInt8.self)) }
            if let at = inText {
                if first == nil { first = at }
                continue
            }
            guard label.withUnsafeBufferPointer({ find(word, in: $0) }) != nil else { return nil }
        }
        return ConversationHit(record: record, snippet: first.map { snippet(record.text, at: $0, length: words[0].count) } ?? "")
    }

    /// The first place `needle` (lowercase) occurs in `hay`, ignoring ASCII letter case.
    static func find(_ needle: [UInt8], in hay: UnsafeBufferPointer<UInt8>) -> Int? {
        guard let head = needle.first, needle.count <= hay.count, let base = hay.baseAddress else { return needle.isEmpty ? 0 : nil }
        let last = hay.count - needle.count
        var i = 0
        while i <= last {
            if fold(base[i]) == head {
                var j = 1
                while j < needle.count, fold(base[i + j]) == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    @inline(__always) private static func fold(_ byte: UInt8) -> UInt8 { byte &- 65 < 26 ? byte | 0x20 : byte }

    /// Up to `before` bytes ahead of the match and `after` past it, within its message, cut on
    /// character boundaries, with "…" where it was cut.
    static func snippet(_ text: Data, at match: Int, length: Int, before: Int = 60, after: Int = 160) -> String {
        text.withUnsafeBytes { raw -> String in
            let bytes = raw.bindMemory(to: UInt8.self)
            var lineStart = match, lineEnd = match
            while lineStart > 0, bytes[lineStart - 1] != 0x0A { lineStart -= 1 }
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            var start = max(lineStart, match - before), end = min(lineEnd, match + length + after)
            // Never start or end inside a multi-byte character.
            while start > lineStart, bytes[start] & 0xC0 == 0x80 { start -= 1 }
            while end < lineEnd, bytes[end] & 0xC0 == 0x80 { end += 1 }
            let body = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
            return (start > lineStart ? "…" : "") + body + (end < lineEnd ? "…" : "")
        }
    }
}
