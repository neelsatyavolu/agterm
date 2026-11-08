import Foundation

extension TeamDashboard {
    /// A row in the overview's member table.
    public struct Member: Codable, Equatable, Sendable, Identifiable {
        public var userId: String
        public var displayName: String
        public var handle: String?
        public var role: Role
        public var lastUploadAt: String?
        /// Never uploaded anything: shown as such, not as a row of zeros.
        public var neverSynced: Bool
        public var totals: Totals
        public var id: String { userId }

        enum CodingKeys: String, CodingKey { case userId, displayName, handle, role, lastUploadAt, neverSynced, totals }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            userId = c.get(.userId, ""); displayName = c.get(.displayName, "Member"); handle = c.opt(.handle)
            role = c.get(.role, .employee); lastUploadAt = c.opt(.lastUploadAt)
            neverSynced = c.get(.neverSynced, lastUploadAt == nil); totals = c.get(.totals, Totals())
        }
    }

    /// What the window shows for an overview.
    public enum State: Equatable, Sendable {
        /// Employees get their own numbers only, never team totals.
        case selfOnly
        /// Nobody has uploaded anything yet.
        case waiting
        case full
    }

    /// `GET /api/teams/:id/overview?range=`.
    public struct Overview: Codable, Equatable, Sendable {
        public var range: Range
        public var from: String?
        public var to: String?
        public var scope: Scope
        public var scopeLabel: String?
        public var role: Role
        public var totals: Totals
        public var deltas: Deltas
        public var daily: [Day]
        public var providerMix: [Mix]
        public var modelMix: [Mix]
        public var projects: [Project]
        public var flags: Flags
        /// Nil when no budget is set or you can't see team spend.
        public var budget: Budget?
        public var members: [Member]
        public var memberCount: Int
        public var teamMemberCount: Int?
        public var lastUploadAt: String?

        enum CodingKeys: String, CodingKey {
            case range, from, to, scope, scopeLabel, role, totals, deltas, daily, providerMix, modelMix, projects, flags, budget,
                 members, memberCount, teamMemberCount, lastUploadAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            range = c.get(.range, .month); from = c.opt(.from); to = c.opt(.to)
            scope = c.get(.scope, .team); scopeLabel = c.opt(.scopeLabel); role = c.get(.role, .employee)
            totals = c.get(.totals, Totals()); deltas = c.get(.deltas, Deltas())
            daily = c.list(.daily); providerMix = c.list(.providerMix); modelMix = c.list(.modelMix); projects = c.list(.projects)
            flags = c.get(.flags, Flags()); budget = c.opt(.budget)
            members = c.list(.members); memberCount = c.get(.memberCount, members.count)
            teamMemberCount = c.opt(.teamMemberCount); lastUploadAt = c.opt(.lastUploadAt)
        }

        public var state: State {
            if scope == .self { return .selfOnly }
            return totals.daysWithData > 0 || members.contains { !$0.neverSynced } ? .full : .waiting
        }

        /// "4 members", or for a manager's own people "3 people of 9 · Platform".
        public var peopleLine: String {
            guard scope == .partial else { return memberCount == 1 ? "1 member" : "\(memberCount) members" }
            var line = "\(memberCount) people"
            if let all = teamMemberCount, all != memberCount { line += " of \(all)" }
            if let label = scopeLabel, !label.isEmpty { line += " · \(label)" }
            return line
        }

        /// Members who have uploaded, busiest first (the server sorts by active hours).
        public var syncedMembers: [Member] { members.filter { !$0.neverSynced } }
    }

    // MARK: One member

    public struct MemberInfo: Codable, Equatable, Sendable {
        public var userId: String
        public var displayName: String
        public var handle: String?
        public var role: Role
        public var lastUploadAt: String?

        enum CodingKeys: String, CodingKey {
            case userId = "user_id", displayName = "display_name", handle, role, lastUploadAt = "last_upload_at"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            userId = c.get(.userId, ""); displayName = c.get(.displayName, "Member"); handle = c.opt(.handle)
            role = c.get(.role, .employee); lastUploadAt = c.opt(.lastUploadAt)
        }
    }

    /// One Claude, Codex or Grok login's part of a member's usage. No `identityHash` is the part no
    /// login could be named for.
    public struct LoginRow: Codable, Equatable, Sendable, Identifiable {
        public var provider: String
        public var identityHash: String?
        public var name: String
        public var tokens: Double
        public var costUsd: Double
        public var costIncomplete: Bool
        public var activeHours: Double
        public var share: Double?
        public var id: String { "\(provider):\(identityHash ?? "none")" }

        enum CodingKeys: String, CodingKey { case provider, identityHash, name, tokens, costUsd, costIncomplete, activeHours, share }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            provider = c.get(.provider, "other"); identityHash = c.opt(.identityHash); name = c.get(.name, "Login")
            tokens = c.get(.tokens, 0); costUsd = c.get(.costUsd, 0); costIncomplete = c.get(.costIncomplete, true)
            activeHours = c.get(.activeHours, 0); share = c.opt(.share)
        }
    }

    public struct Logins: Codable, Equatable, Sendable {
        /// False until one of the member's apps reports which login each session used.
        public var reported: Bool
        public var rows: [LoginRow]

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            reported = c.get(.reported, false); rows = c.list(.rows)
        }

        enum CodingKeys: String, CodingKey { case reported, rows }
    }

    /// `GET /api/teams/:id/members/:user/detail`, and `…/me` for yourself.
    public struct MemberDetail: Codable, Equatable, Sendable {
        public var isSelf: Bool
        public var member: MemberInfo
        public var totals: Totals
        public var daily: [Day]
        public var providerMix: [Mix]
        public var modelMix: [Mix]
        public var projects: [Project]
        public var neverSynced: Bool
        /// Nil from servers older than usage by login.
        public var logins: Logins?

        enum CodingKeys: String, CodingKey { case isSelf, member, totals, daily, providerMix, modelMix, projects, neverSynced, logins }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            isSelf = c.get(.isSelf, false)
            member = try c.decode(MemberInfo.self, forKey: .member)
            totals = c.get(.totals, Totals()); daily = c.list(.daily)
            providerMix = c.list(.providerMix); modelMix = c.list(.modelMix); projects = c.list(.projects)
            neverSynced = c.get(.neverSynced, false); logins = c.opt(.logins)
        }
    }
}
