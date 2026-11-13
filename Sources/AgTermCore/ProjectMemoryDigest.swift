import Foundation

/// A short digest of a project's memory and latest handoffs, put into each agent's instructions
/// at launch. Agents act on memory they can already see far more reliably than on a request to
/// go and list it; the full store stays reachable through the memory server's `search`.
/// Reads the memory server's memory.json and handoffs.json (agmux's format).
public enum ProjectMemoryDigest {
    /// The longest the digest gets; entries past it are counted, not shown.
    public static let maxCharacters = 4000
    static let maxEntries = 25
    public static let maxHandoffs = 3
    static let entryLength = 240
    static let handoffLength = 360

    /// The digest, or nil when neither store has anything to show.
    public static func render(memory: Data?, handoffs: Data?) -> String? {
        let entries = currentEntries(memory)
        let sessions = recentHandoffs(handoffs)
        guard !entries.isEmpty || !sessions.isEmpty else { return nil }
        var lines: [String] = []
        var used = 0
        if !entries.isEmpty {
            lines.append("Saved for this repo (newest first; may be out of date, so check against the code):")
            var shown = 0
            for entry in entries.prefix(maxEntries) {
                let line = "- [\(entry.kind)] \(entry.title)" + (entry.content.isEmpty ? "" : ": " + clip(entry.content, entryLength))
                guard used + line.count <= maxCharacters * 3 / 4 else { break }
                lines.append(line)
                used += line.count
                shown += 1
            }
            if entries.count > shown { lines.append("- …and \(entries.count - shown) more entries; `search` finds them.") }
        }
        if !sessions.isEmpty {
            lines.append("")
            lines.append("Latest session handoffs:")
            for session in sessions {
                let line = "- \(session.date) \(session.title): " + clip(session.summary, handoffLength)
                guard used + line.count <= maxCharacters else { break }
                lines.append(line)
                used += line.count
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Reading the stores

    /// A saved memory entry, as the store has it.
    public struct Entry: Equatable, Sendable {
        public let kind, title, content, updated: String
        public let binding, important: Bool
    }

    /// A session's handoff summary.
    public struct Handoff: Equatable, Sendable {
        public let title, summary, updated: String
        public var date: String { String(updated.prefix(10)) }
    }

    /// Entries not archived or superseded, in agmux's order: binding, important, pins, then newest.
    public static func currentEntries(_ data: Data?) -> [Entry] {
        guard let rows = object(data)?["entries"] as? [[String: Any]] else { return [] }
        let entries = rows.compactMap { row -> Entry? in
            guard row["archived"] as? Bool != true, (row["status"] as? String ?? "current") == "current",
                  let title = text(row["title"]), !title.isEmpty else { return nil }
            return Entry(kind: row["kind"] as? String ?? "note", title: title, content: text(row["content"]) ?? "",
                         updated: row["updatedAt"] as? String ?? row["createdAt"] as? String ?? "",
                         binding: row["binding"] as? Bool ?? false, important: row["important"] as? Bool ?? false)
        }
        return entries.sorted { a, b in
            if a.binding != b.binding { return a.binding }
            if a.important != b.important { return a.important }
            if (a.kind == "pin") != (b.kind == "pin") { return a.kind == "pin" }
            return a.updated > b.updated
        }
    }

    public static func recentHandoffs(_ data: Data?, limit: Int = maxHandoffs) -> [Handoff] {
        guard let rows = object(data)?["sessions"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> Handoff? in
            guard let summary = text(row["summary"]), !summary.isEmpty else { return nil }
            return Handoff(title: text(row["title"]) ?? "Session", summary: summary, updated: row["updatedAt"] as? String ?? "")
        }
        .sorted { $0.updated > $1.updated }
        .prefix(limit).map { $0 }
    }

    private static func object(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// A stored string on one line, whitespace collapsed.
    private static func text(_ value: Any?) -> String? {
        (value as? String).map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    }

    private static func clip(_ text: String, _ length: Int) -> String {
        text.count <= length ? text : String(text.prefix(length - 1)) + "…"
    }
}
