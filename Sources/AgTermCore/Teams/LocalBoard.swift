import Foundation

/// The board on this Mac, for agents in its tabs when team sessions are off: the same posts,
/// fields and rules as the agmux Teams board (team-board.ts), kept in a file by the app.
public struct LocalBoard: Codable, Equatable, Sendable {
    public static let kinds: Set<String> = ["claim", "question", "decision", "note", "reply"]
    static let maxText = 2_000
    static let defaultClaimHours = 4.0
    /// How long each kind is kept after its last change; open claims stay until they expire.
    static let keep: [String: TimeInterval] = ["claim": 7 * 86_400, "question": 7 * 86_400, "reply": 7 * 86_400,
                                               "note": 14 * 86_400, "decision": 180 * 86_400]

    public struct Item: Codable, Equatable, Sendable {
        public let id: String
        public let project: String
        public let kind: String
        public let replyTo: String?
        public var text: String
        public var status: String
        public let agent: String?
        public let posted: Date
        public var updated: Date
        public var expires: Date?
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case invalid(String)
        case notFound
        public var errorDescription: String? {
            switch self {
            case .invalid(let message): message
            case .notFound: "That board item is gone."
            }
        }
    }

    public private(set) var items: [Item] = []

    public init(items: [Item] = []) { self.items = items }

    /// The board for one repo as list rows (newest change first), as the server shows it.
    public func read(project: String, since: Date?, now: Date, member: String) -> [[String: Any]] {
        items.filter { item in
            guard item.project == project else { return false }
            guard let since else { return true }
            // A claim that ran out since the last read changed too, though nobody touched it.
            let expiredSince = item.kind == "claim" && item.status == "open" && (item.expires.map { $0 >= since && $0 <= now } ?? false)
            return item.updated >= since || expiredSince
        }
            .sorted { $0.updated > $1.updated }
            .map { item in
                let expired = item.kind == "claim" && item.status == "open" && (item.expires.map { $0 < now } ?? false)
                var row: [String: Any] = ["id": item.id, "kind": item.kind, "text": item.text, "status": expired ? "expired" : item.status,
                                          "member": member, "mine": true, "posted": Self.iso(item.posted), "updated": Self.iso(item.updated)]
                row["agent"] = item.agent
                row["reply_to"] = item.replyTo
                if item.kind == "claim", let expires = item.expires { row["expires"] = Self.iso(expires) }
                return row
            }
    }

    public mutating func post(project: String, kind: String, text: String, replyTo: String?, hours: Double?,
                              agent: String?, now: Date, id: String = "tb_" + UUID().uuidString.lowercased()) throws -> Item {
        guard Self.kinds.contains(kind) else { throw Failure.invalid("kind must be one of claim, question, decision, note, reply.") }
        let project = try Self.clean(project, max: 200, what: "Project")
        let text = try Self.clean(text, max: Self.maxText, what: "Text")
        if kind == "reply" {
            guard let replyTo, items.contains(where: { $0.id == replyTo && $0.project == project }) else {
                throw replyTo == nil ? Failure.invalid("A reply needs reply_to: the item it answers.") : Failure.notFound
            }
        }
        let expires = kind == "claim" ? now.addingTimeInterval(Self.claimSeconds(hours)) : nil
        let item = Item(id: id, project: project, kind: kind, replyTo: kind == "reply" ? replyTo : nil, text: text, status: "open",
                        agent: agent.map { String(Self.printable($0).prefix(40)) }, posted: now, updated: now, expires: expires)
        items.append(item)
        return item
    }

    public mutating func update(id: String, status: String?, renew: Bool, hours: Double?, text: String?, now: Date) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw Failure.notFound }
        if let status {
            guard ["open", "done", "released"].contains(status) else { throw Failure.invalid("status must be open, done or released.") }
            items[index].status = status
        }
        if let text { items[index].text = try Self.clean(text, max: Self.maxText, what: "Text") }
        if renew || status == "open" {
            guard items[index].kind == "claim" else { throw Failure.invalid("Only a claim can be renewed.") }
            items[index].expires = now.addingTimeInterval(Self.claimSeconds(hours))
        }
        items[index].updated = now
    }

    /// Drops what each kind no longer needs.
    public mutating func sweep(now: Date) {
        items.removeAll { item in
            let heldClaim = item.kind == "claim" && item.status == "open" && (item.expires.map { $0 >= now } ?? false)
            return !heldClaim && now.timeIntervalSince(item.updated) > (Self.keep[item.kind] ?? 7 * 86_400)
        }
    }

    static func claimSeconds(_ hours: Double?) -> TimeInterval {
        min(24, max(0.25, hours ?? defaultClaimHours)) * 3600
    }

    static func clean(_ text: String, max: Int, what: String) throws -> String {
        let cleaned = printable(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw Failure.invalid("\(what) is empty.") }
        guard cleaned.count <= max else { throw Failure.invalid("Keep \(what.lowercased()) under \(max) characters.") }
        return cleaned
    }

    /// Control characters other than tab and newline become spaces, as on the server.
    static func printable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            scalar.properties.generalCategory == .control && scalar != "\n" && scalar != "\t" ? " " : scalar
        }))
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }
}
