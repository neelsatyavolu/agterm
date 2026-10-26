import Foundation

/// agmux Teams' shared account pool: logins a team's owners share, lent to one session at a
/// time for 5 minutes, renewed every minute while used. Claude logins can't be shared (agmux
/// keeps them personal), so this is Codex only in agterm. Credentials never reach an error
/// message, a log line or anything stored besides the borrowed login's own auth.json.
public enum TeamPool {
    public struct Team: Equatable, Sendable {
        public let id: String
        public let name: String
    }

    /// A pooled login as the service describes it. Never holds credentials.
    public struct Account: Equatable, Sendable, Identifiable {
        public let id: String
        public let teamID: String
        public let teamName: String
        public let provider: AccountProvider
        public let label: String
        public let enabled: Bool
        public let plan: String?
        /// Fresh measurement only (the service drops it after 5 minutes).
        public let remainingPercent: Double?
        /// Last measurement of any age, for display.
        public let lastRemainingPercent: Double?
        public let blockedUntil: Date?
        public let checkedAt: Date?
        public let leasedUntil: Date?
        /// Who holds it now, when leased: you (`mine`) or a teammate's name.
        public let inUseMine: Bool
        public let inUseBy: String?

        public func leased(_ now: Date) -> Bool { leasedUntil.map { $0 > now } ?? false }

        /// Known out of usage right now.
        public func exhausted(_ now: Date) -> Bool {
            if let blockedUntil { return blockedUntil > now }
            return remainingPercent == 0
        }

        /// Worth asking the service for: it hands out only enabled, free, unblocked logins.
        public func borrowable(_ now: Date) -> Bool { enabled && !leased(now) && !exhausted(now) }

        /// The percent left to show, if anyone measured it since its last reset.
        public func shownRemaining(_ now: Date) -> Double? {
            if let blockedUntil, blockedUntil <= now { return nil }
            return remainingPercent ?? lastRemainingPercent
        }
    }

    /// A login lent to this Mac. `credentials` is the native auth.json, written only to the
    /// borrowed login's own folder.
    public struct Lease: Sendable {
        public let teamID: String
        public let leaseID: String
        public let accountID: String
        public let provider: AccountProvider
        public let label: String
        public let credentials: Data
        public var expiresAt: Date
        public let remainingPercent: Double?

        public init(teamID: String, leaseID: String, accountID: String, provider: AccountProvider, label: String,
                    credentials: Data, expiresAt: Date, remainingPercent: Double?) {
            self.teamID = teamID
            self.leaseID = leaseID
            self.accountID = accountID
            self.provider = provider
            self.label = label
            self.credentials = credentials
            self.expiresAt = expiresAt
            self.remainingPercent = remainingPercent
        }
    }

    public struct Failure: Error, Equatable, LocalizedError {
        public let message: String
        /// A known passing problem (network, busy, server error): a held lease can ride it out.
        public let retryable: Bool
        public var errorDescription: String? { message }

        public init(message: String, retryable: Bool) {
            self.message = message
            self.retryable = retryable
        }
    }

    public static let invalidResponse = Failure(message: "agmux Teams sent an unexpected reply.", retryable: false)
    public static let networkError = Failure(message: "agmux Teams couldn't be reached.", retryable: true)
    public static let inUse = Failure(message: "A teammate is using this account right now.", retryable: false)

    /// Folder ids for borrowed logins start with this, so the wrapper knows one when it sees it.
    public static let localPrefix = "team-"

    public static func localID(leaseID: String) -> String {
        localPrefix + String(leaseID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }.prefix(80))
    }

    public static func isLocalID(_ id: String) -> Bool { id.hasPrefix(localPrefix) && id.count > localPrefix.count }

    /// A loan this Mac holds: its folder id, the agent process running on it (from owner.pid)
    /// and the tab that borrowed it, if known.
    public struct HeldLoan: Equatable, Sendable {
        public let id: String
        public let owner: Int32?
        public let tabID: String?

        public init(id: String, owner: Int32?, tabID: String?) {
            self.id = id
            self.owner = owner
            self.tabID = tabID
        }
    }

    /// Allowed between a process's start time and a file's modification time, which come from
    /// different clocks and resolutions.
    public static let ownerClockSlack: TimeInterval = 2

    /// Whether the process now holding owner.pid's pid is the agent that wrote the file: it must
    /// have started before the file was written. One that started later got the pid after the
    /// agent exited, and must be neither kept for nor signalled.
    public static func isOwner(processStartedAt: Date?, pidFileWrittenAt: Date?) -> Bool {
        guard let processStartedAt, let pidFileWrittenAt else { return false }
        return processStartedAt <= pidFileWrittenAt.addingTimeInterval(ownerClockSlack)
    }

    /// At quit: the loans to keep out. A quit that leaves tabs running (`detaching`) keeps a loan
    /// whose agent is alive in a tab the sessions helper keeps; it would die with any other tab.
    /// Ending every session keeps none.
    public static func loansToKeep(_ loans: [HeldLoan], keptTabs: Set<String>, detaching: Bool,
                                   alive: (Int32) -> Bool) -> Set<String> {
        guard detaching else { return [] }
        return Set(loans.filter { loan in
            guard let owner = loan.owner, let tab = loan.tabID else { return false }
            return keptTabs.contains(tab) && alive(owner)
        }.map(\.id))
    }

    /// At launch: loans the last run left out whose agent is still running (in a tab that
    /// outlived the quit or a crash); the rest go back.
    public static func leftoverLoansToKeep(_ loans: [HeldLoan], alive: (Int32) -> Bool) -> Set<String> {
        Set(loans.filter { $0.owner.map(alive) ?? false }.map(\.id))
    }

    public static func failure(status: Int) -> Failure {
        switch status {
        case 401: Failure(message: "agmux Teams no longer accepts this Mac's sign-in.", retryable: false)
        case 403: Failure(message: "You don't have permission to use these team accounts.", retryable: false)
        case 404, 405, 501: Failure(message: "This agmux Teams server doesn't share accounts.", retryable: false)
        case 409: Failure(message: "The team account changed. Try again.", retryable: false)
        case 429: Failure(message: "agmux Teams is busy. Try again shortly.", retryable: true)
        case 500...599: Failure(message: "agmux Teams is unavailable. Try again later.", retryable: true)
        default: Failure(message: "agmux Teams refused the request.", retryable: false)
        }
    }

    // MARK: Replies

    /// The `data` of an `{ok: true, data}` reply. Never echoes the body: it may hold a token.
    static func data(_ body: Data) throws -> [String: Any] {
        guard let envelope = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              envelope["ok"] as? Bool == true, let data = envelope["data"] as? [String: Any] else { throw invalidResponse }
        return data
    }

    static func code(_ body: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]).flatMap { $0["ok"] as? Bool == false ? $0["code"] as? String : nil }
    }

    /// `GET /api/teams`. Staff previews can't borrow anything, so they're left out.
    public static func teams(status: Int, body: Data) throws -> [Team] {
        guard (200..<300).contains(status) else { throw failure(status: status) }
        guard let rows = try data(body)["teams"] as? [[String: Any]] else { throw invalidResponse }
        return try rows.filter { $0["staffPreview"] as? Bool != true }.map { row in
            guard let id = row["id"] as? String, !id.isEmpty else { throw invalidResponse }
            return Team(id: id, name: text(row["name"], max: 120) ?? "Team")
        }
    }

    /// `GET /api/teams/:id/provider-accounts`, nil when this server or team has no pool.
    public static func accounts(status: Int, body: Data, team: Team) throws -> [Account]? {
        if [404, 405, 501].contains(status) { return nil }
        if status == 503, code(body) == "provider_accounts_not_configured" { return nil }
        guard (200..<300).contains(status) else { throw failure(status: status) }
        guard let rows = try data(body)["accounts"] as? [[String: Any]] else { throw invalidResponse }
        return rows.compactMap { account($0, team: team) }
    }

    static func account(_ row: [String: Any], team: Team) -> Account? {
        guard let id = row["id"] as? String, !id.isEmpty,
              let provider = (row["provider"] as? String).flatMap(AccountProvider.init(rawValue:)), provider == .codex else { return nil }
        let inUse = row["inUse"] as? [String: Any]
        return Account(id: id, teamID: team.id, teamName: team.name, provider: provider,
                       label: text(row["label"], max: 120) ?? "Team account", enabled: row["enabled"] as? Bool == true,
                       plan: text(row["plan"], max: 40), remainingPercent: percent(row["remainingPercent"]),
                       lastRemainingPercent: percent(row["lastRemainingPercent"]), blockedUntil: date(row["blockedUntil"]),
                       checkedAt: date(row["healthReportedAt"]), leasedUntil: date(row["leasedUntil"]),
                       inUseMine: inUse?["self"] as? Bool == true, inUseBy: text(inUse?["by"], max: 120))
    }

    /// `POST …/allocate` or `…/:id/check`. Nil only when the service says no account is free.
    public static func lease(status: Int, body: Data, team: String, provider: AccountProvider, account: String? = nil, now: Date) throws -> Lease? {
        if status == 409 {
            if code(body) == "no_provider_account_available" { return nil }
            if account != nil { throw inUse }
        }
        guard (200..<300).contains(status) else { throw failure(status: status) }
        let data = try data(body)
        guard let leaseID = data["leaseId"] as? String, !leaseID.isEmpty, let expires = date(data["expiresAt"]), expires > now,
              let row = data["account"] as? [String: Any], let id = row["id"] as? String, !id.isEmpty,
              row["provider"] as? String == provider.rawValue, row["enabled"] as? Bool == true, account == nil || account == id,
              let credentials = data["credentials"] as? [String: Any], validCredentials(credentials, provider: provider),
              let json = try? JSONSerialization.data(withJSONObject: credentials) else { throw invalidResponse }
        let blocked = date(row["blockedUntil"])
        let remaining = blocked.map { $0 <= now } == true ? nil : percent(row["remainingPercent"])
        return Lease(teamID: team, leaseID: leaseID, accountID: id, provider: provider, label: text(row["label"], max: 120) ?? "Team account",
                     credentials: json, expiresAt: expires, remainingPercent: remaining)
    }

    /// `POST …/leases/:id/renew` → the new expiry.
    public static func renewed(status: Int, body: Data, leaseID: String, now: Date) throws -> Date {
        guard (200..<300).contains(status) else { throw failure(status: status) }
        let data = try data(body)
        guard data["leaseId"] as? String == leaseID, let expires = date(data["expiresAt"]), expires > now else { throw invalidResponse }
        return expires
    }

    /// What the service needs before it hands a Codex login over: a ChatGPT sign-in with tokens.
    public static func validCredentials(_ json: [String: Any], provider: AccountProvider) -> Bool {
        guard provider == .codex, let tokens = json["tokens"] as? [String: Any] else { return false }
        if let mode = json["auth_mode"] as? String, mode != "chatgpt" { return false }
        return ["access_token", "refresh_token", "id_token", "account_id"].allSatisfy { (tokens[$0] as? String)?.isEmpty == false }
    }

    // MARK: Requests

    /// The renew body: the login's current auth.json (Codex refreshes its tokens there) and,
    /// when measured, how much is left. Nil if the file isn't a valid login anymore.
    public static func renewBody(credentials: Data, health: Health?) -> [String: Any]? {
        guard let json = (try? JSONSerialization.jsonObject(with: credentials)) as? [String: Any],
              validCredentials(json, provider: .codex) else { return nil }
        var body: [String: Any] = ["credentials": json]
        if let remaining = health?.remainingPercent { body["remainingPercent"] = remaining }
        if let blocked = health?.blockedUntil { body["blockedUntil"] = blocked }
        return body
    }

    /// What to tell the service about a login's usage. `blockedUntil` 0 clears an old block.
    public struct Health: Equatable, Sendable {
        public let remainingPercent: Double?
        public let blockedUntil: Int?

        public init(remainingPercent: Double?, blockedUntil: Int?) {
            self.remainingPercent = remainingPercent
            self.blockedUntil = blockedUntil
        }

        /// From a usage check. Paid credits keep it usable with no percentage to report; a
        /// window that resets later isn't a block unless it's used up.
        public init?(_ reading: UsageReading?, now: Date) {
            guard let reading else { return nil }
            if reading.hasCredits { self.init(remainingPercent: nil, blockedUntil: 0); return }
            guard let remaining = reading.remainingPercent else { return nil }
            let until = reading.exhaustedUntil(now)
            self.init(remainingPercent: until == nil ? remaining : 0, blockedUntil: until.map { Int($0.timeIntervalSince1970) } ?? 0)
        }

        /// The agent just stopped at its limit. Without a known reset it's blocked for an hour,
        /// never open-ended: the service would keep a bare zero out of the pool for good.
        public static func exhausted(until: Date?, now: Date) -> Health {
            Health(remainingPercent: 0, blockedUntil: Int((until ?? now.addingTimeInterval(3600)).timeIntervalSince1970))
        }
    }

    // MARK: Values

    static func text(_ value: Any?, max: Int) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.count <= max,
              !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return s
    }

    static func percent(_ value: Any?) -> Double? {
        guard let n = (value as? NSNumber)?.doubleValue, n.isFinite, (0...100).contains(n) else { return nil }
        return n
    }

    /// Unix seconds.
    static func date(_ value: Any?) -> Date? {
        guard let n = (value as? NSNumber)?.doubleValue, n.isFinite, n > 0 else { return nil }
        return Date(timeIntervalSince1970: n)
    }
}
