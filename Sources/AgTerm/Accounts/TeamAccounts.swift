import AgTermCore
import Foundation

/// Codex logins your team shares through agmux Teams. agterm borrows one only when your own
/// logins are out, for one Codex process at a time: it renews the loan every minute with the
/// login's current tokens (Codex refreshes them in auth.json), and once that process has exited
/// it sends the tokens back, returns the loan and deletes its copy. Main queue only.
///
/// A borrowed login's folder holds `lease.json` (which loan and tab, never tokens), so a loan left
/// by a crash can still be returned, and `owner.pid`, written by the wrapper as the agent starts:
/// the loan lasts exactly as long as that process, in the foreground or not. That includes an
/// agent in a tab the sessions helper kept running across an update's relaunch (or a crash): the
/// next launch takes its loan back up. A plain quit stops such agents and returns their loans.
final class TeamAccounts: ObservableObject {
    static let shared = TeamAccounts()
    static let renewEvery: TimeInterval = {
        #if DEBUG
        if let seconds = ProcessInfo.processInfo.environment["AGTERM_TEAM_RENEW_EVERY"].flatMap(TimeInterval.init) { return seconds }
        #endif
        return 60
    }()
    /// A new loan waits this long for its agent to start before it's given back.
    static let startGrace: TimeInterval = 60

    @Published private(set) var accounts: [TeamPool.Account] = []
    @Published private(set) var error: String?
    @Published private(set) var checking: Set<String> = []
    /// Usage measured here with Check Usage, by team account id, and why a check failed.
    @Published private(set) var readings: [String: UsageReading] = [:]
    @Published private(set) var checkErrors: [String: String] = [:]

    /// A loan this Mac holds, by its folder id.
    private struct Held {
        var lease: TeamPool.Lease
        let tabID: String
        let since: Date
        var renewedAt: Date
        var renewing = false
        /// Its agent has been seen running; once that process is gone, the loan goes back.
        var started = false
        /// Its agent stopped at the limit: measure it once the agent is gone, so the team
        /// learns when it frees up again.
        var exhausted = false
    }

    private var held: [String: Held] = [:]
    /// Loans not (or no longer) in `held` that still have to go back: being set up, checked or
    /// returned. Quitting returns these too.
    private var inFlight: [String: TeamPool.Lease] = [:]
    /// Each loan's server calls run one after another, so an older renewal can never land
    /// after the final one and put stale tokens back.
    private var queues: [String: Task<Void, Never>] = [:]
    /// Loans still being set up or checked (a usage probe may be using them): their own task
    /// returns them, so quitting doesn't pull them out from under the probe.
    private var settingUp: Set<String> = []
    /// Bumped by `giveBackAll`; a loan allocated before that is returned instead of used.
    private var generation = 0
    private var answering: Set<String> = []

    private var token: String? {
        #if DEBUG
        if let token = ProcessInfo.processInfo.environment["AGTERM_TEAMS_TOKEN"] { return token }
        #endif
        return MainActor.assumeIsolated { TeamsAccount.shared.token }
    }
    var isConnected: Bool { token != nil }

    /// Whether a new Codex session could borrow one now.
    var hasBorrowable: Bool { isConnected && accounts.contains { $0.borrowable(Date()) } }

    func label(_ id: String) -> String? { held[id].map { "\($0.lease.label) (team)" } }

    /// The pooled login behind a loan, so a tab that ran it out doesn't get it again.
    func accountID(_ id: String) -> String? { held[id]?.lease.accountID }

    /// Takes back up the loans of agents still running from the last run (their tab outlived the
    /// quit or a crash) and returns the rest, with whatever tokens Codex last wrote.
    func start() {
        let fm = FileManager.default
        try? fm.removeItem(at: AccountStore.requestsDir)
        let token = token
        let leftovers = ((try? fm.contentsOfDirectory(atPath: AccountStore.dir.path)) ?? []).filter(TeamPool.isLocalID).map { id in
            TeamPool.HeldLoan(id: id, owner: Self.liveOwner(AccountStore.home(id))?.pid, tabID: Self.savedTabID(AccountStore.home(id)))
        }
        let running = TeamPool.leftoverLoansToKeep(leftovers, alive: Self.alive)
        for loan in leftovers {
            let home = AccountStore.home(loan.id)
            guard let token, let lease = Self.savedLease(home) else {
                try? fm.removeItem(at: home)
                continue
            }
            if running.contains(loan.id) {
                // Renewed on the next poll, which also returns it once the agent exits.
                held[loan.id] = Held(lease: lease, tabID: loan.tabID ?? "", since: Date(), renewedAt: .distantPast, started: true)
                continue
            }
            enqueue(loan.id) { await Self.returnLease(token, lease, home: home) }
        }
        refresh()
    }

    // MARK: The list

    func refresh(completion: (() -> Void)? = nil) {
        guard let token else {
            accounts = []
            error = nil
            completion?()
            return
        }
        Task {
            let result: Result<[TeamPool.Account], TeamPool.Failure>
            do { result = .success(try await Self.list(token: token)) } catch { result = .failure(Self.failure(error)) }
            await MainActor.run {
                switch result {
                case .success(let accounts): self.accounts = accounts; self.error = nil
                case .failure(let failure): self.error = failure.message
                }
                UsageMonitor.shared.updateRouting(.codex)
                completion?()
            }
        }
    }

    private static func list(token: String) async throws -> [TeamPool.Account] {
        let (status, body) = try await send(token, "GET", ["api", "teams"])
        var all: [TeamPool.Account] = []
        for team in try TeamPool.teams(status: status, body: body) {
            let (status, body) = try await send(token, "GET", ["api", "teams", team.id, "provider-accounts"])
            all += try TeamPool.accounts(status: status, body: body, team: team) ?? []
        }
        return all
    }

    // MARK: Borrowing

    /// Borrows a Codex login for `tabID` and gets its folder ready. Hands back its folder id, or
    /// nil when no team login is free (or the free ones turn out to be used up too).
    func borrow(_ provider: AccountProvider, tabID: String, excluding: Set<String>, completion: @escaping (String?) -> Void) {
        guard provider == .codex, let token else { return completion(nil) }
        let generation = generation
        Task {
            var excluded = excluding
            for _ in 0..<3 {
                guard let lease = try? await Self.allocate(token, provider: provider, session: "agterm:" + tabID, excluding: excluded) else { break }
                let id = TeamPool.localID(leaseID: lease.leaseID)
                guard await self.claim(id, lease, generation) else {
                    await Self.release(token, lease)
                    break
                }
                guard let home = try? Self.install(lease, id: id, tabID: tabID) else {
                    await self.finish(id) { await Self.returnLease(token, lease, home: AccountStore.home(id)) }
                    break
                }
                // Nobody measured it lately: check before an agent runs on it, so a used-up
                // login isn't handed over. Nothing else touches its tokens yet.
                let reading = lease.remainingPercent == nil ? await Task.detached { UsageProbe.read(provider, home: home).reading }.value : nil
                let health = TeamPool.Health(reading, now: Date())
                if reading?.exhaustedUntil(Date()) != nil {
                    excluded.insert(lease.accountID)
                    await self.finish(id) { await Self.returnLease(token, lease, home: home, health: health) }
                    continue
                }
                var loan = lease
                if health != nil {
                    do { loan.expiresAt = try await Self.renew(token, lease, home: home, health: health) } catch {
                        // Disabled or taken away meanwhile: never hand it over.
                        if !Self.failure(error).retryable {
                            await self.finish(id) { await Self.returnLease(token, lease, home: home) }
                            break
                        }
                    }
                }
                let ready = loan
                let handed = await MainActor.run { () -> Bool in
                    self.settingUp.remove(id)
                    // Signed out while it was being set up: it goes back instead.
                    guard self.generation == generation else { return false }
                    self.inFlight[id] = nil
                    self.held[id] = Held(lease: ready, tabID: tabID, since: Date(), renewedAt: Date())
                    if let reading { self.readings[lease.accountID] = reading }
                    self.refresh()
                    return true
                }
                if !handed { await self.finish(id) { await Self.returnLease(token, ready, home: home) } }
                await MainActor.run { completion(handed ? id : nil) }
                return
            }
            await MainActor.run { completion(nil) }
        }
    }

    /// The agent on this loan stopped at its limit: tell the team so nobody else gets it.
    func reportExhausted(_ id: String) {
        guard let token, let loan = held[id] else { return }
        held[id]?.exhausted = true
        let home = AccountStore.home(id)
        enqueue(id) { _ = try? await Self.renew(token, loan.lease, home: home, health: .exhausted(until: nil, now: Date())) }
    }

    /// Every second: keeps loans alive while their agent runs, returns the rest, and answers
    /// agents that asked for one as they started.
    func poll(_ sessions: [TerminalSession]) {
        let tabs = Dictionary(sessions.map { ($0.tabID, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Date()
        for (id, loan) in held {
            let owner = Self.owner(AccountStore.home(id))
            let running = Self.liveOwner(AccountStore.home(id)) != nil
            let starting = !loan.started && owner == nil && tabs[loan.tabID] != nil && now.timeIntervalSince(loan.since) < Self.startGrace
            guard running || starting else {
                giveBack(id)
                continue
            }
            if running, !loan.started { held[id]?.started = true }
            if !loan.renewing, now.timeIntervalSince(loan.renewedAt) >= Self.renewEvery { renew(id) }
        }
        answerRequests(tabs)
    }

    private func renew(_ id: String) {
        guard let loan = held[id] else { return }
        held[id]?.renewing = true
        let token = token
        let outcome = Outcome()
        // Only the network call is queued: quitting waits for queued calls on the main thread.
        let call = enqueue(id) {
            if let token {
                do { outcome.result = .success(try await Self.renew(token, loan.lease, home: AccountStore.home(id), health: nil)) }
                catch { outcome.result = .failure(Self.failure(error)) }
            } else {
                outcome.result = .failure(TeamPool.Failure(message: "agterm is signed out of agmux Teams.", retryable: false))
            }
        }
        Task {
            await call.value
            guard let result = outcome.result else { return }
            await MainActor.run {
                guard self.held[id] != nil else { return }
                self.held[id]?.renewing = false
                switch result {
                case .success(let expiry):
                    self.held[id]?.lease.expiresAt = expiry
                    self.held[id]?.renewedAt = Date()
                case .failure(let failure) where failure.retryable && loan.lease.expiresAt > Date().addingTimeInterval(30):
                    // Try again in 10 seconds; the loan has a few minutes left.
                    self.held[id]?.renewedAt = Date().addingTimeInterval(10 - Self.renewEvery)
                case .failure(let failure):
                    self.revoke(id, failure.message)
                }
            }
        }
    }

    private final class Outcome: @unchecked Sendable { var result: Result<Date, TeamPool.Failure>? }

    /// Records a fresh loan as this Mac's, unless quitting or signing out happened meanwhile.
    private func claim(_ id: String, _ lease: TeamPool.Lease, _ generation: Int) async -> Bool {
        await MainActor.run {
            guard self.generation == generation else { return false }
            self.inFlight[id] = lease
            self.settingUp.insert(id)
            return true
        }
    }

    /// The team took it back (or it lapsed): the agent must stop using it, then the loan is
    /// returned as far as the service still allows.
    private func revoke(_ id: String, _ reason: String) {
        guard let loan = held.removeValue(forKey: id) else { return }
        inFlight[id] = loan.lease
        let home = AccountStore.home(id)
        let owner = Self.liveOwner(home)
        let token = token
        Notifier.shared.post(title: "Team account \(loan.lease.label) was taken back",
                             body: reason + " Codex was stopped; resume it with codex resume.", tabID: loan.tabID)
        Task {
            if let owner { await Self.stop([owner]) }
            await self.finish(id) {
                if let token { await Self.returnLease(token, loan.lease, home: home) } else { try? FileManager.default.removeItem(at: home) }
            }
        }
    }

    /// Its agent has exited: sends back the latest tokens, returns the loan, deletes the copy.
    private func giveBack(_ id: String) {
        guard let loan = held.removeValue(forKey: id) else { return }
        inFlight[id] = loan.lease
        let home = AccountStore.home(id)
        guard let token else {
            // Signed out with the loan still out: nothing can be sent back; it lapses in 5 minutes.
            inFlight[id] = nil
            try? FileManager.default.removeItem(at: home)
            return
        }
        Task {
            await self.finish(id) {
                // The agent is gone, so measuring now can't race it over the tokens.
                let reading = loan.exhausted ? await Task.detached { UsageProbe.read(loan.lease.provider, home: home).reading }.value : nil
                await Self.returnLease(token, loan.lease, home: home, health: TeamPool.Health(reading, now: Date()))
            }
            await MainActor.run { self.refresh() }
        }
    }

    /// The agents running on a team login now: their tab's ID and the agent's name.
    var teamAgentsByTab: [String: String] {
        Dictionary(held.compactMap { id, loan in Self.liveOwner(AccountStore.home(id)).map { _ in (loan.tabID, loan.lease.provider.title) } },
                   uniquingKeysWith: { a, _ in a })
    }

    /// Quitting or signing out: stop every agent on a team login, then return all loans now,
    /// so teammates don't wait 5 minutes for them. An update's relaunch, which leaves tabs
    /// running, passes them as `keptTabs`: an agent still running in one keeps its loan (and its
    /// login folder) for the relaunched app to take back up. A plain quit doesn't: nothing
    /// renews a loan while agterm is closed, and a lapsed loan is taken back from the agent.
    func giveBackAll(keepingAgentsIn keptTabs: Set<String>? = nil) {
        generation += 1
        let kept = TeamPool.loansToKeep(held.map { TeamPool.HeldLoan(id: $0.key, owner: Self.liveOwner(AccountStore.home($0.key))?.pid, tabID: $0.value.tabID) },
                                        keptTabs: keptTabs ?? [], detaching: keptTabs != nil, alive: Self.alive)
        let loans = held.filter { !kept.contains($0.key) }.mapValues(\.lease)
            .merging(inFlight.filter { !settingUp.contains($0.key) }) { current, _ in current }
        held = [:]
        guard !loans.isEmpty else { return }
        inFlight = inFlight.filter { settingUp.contains($0.key) }
        let owners = loans.keys.compactMap { Self.liveOwner(AccountStore.home($0)) }
        let pending = Array(queues.values)
        queues = [:]
        guard let token else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await Self.stop(owners)
            // Calls already under way finish first, so the last tokens sent are the newest.
            for task in pending { await task.value }
            await withTaskGroup(of: Void.self) { group in
                for (id, lease) in loans { group.addTask { await Self.returnLease(token, lease, home: AccountStore.home(id), attempts: 1) } }
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 8)
    }

    /// Runs `operation` after this loan's earlier calls, then forgets the loan.
    private func finish(_ id: String, _ operation: @escaping () async -> Void) async {
        let task = await MainActor.run { self.enqueue(id, operation) }
        await task.value
        await MainActor.run {
            self.inFlight[id] = nil
            self.settingUp.remove(id)
            if self.queues[id] == task { self.queues[id] = nil }
        }
    }

    @discardableResult
    private func enqueue(_ id: String, _ operation: @escaping () async -> Void) -> Task<Void, Never> {
        let previous = queues[id]
        let task = Task {
            await previous?.value
            await operation()
        }
        queues[id] = task
        return task
    }

    // MARK: Requests from agents starting

    /// An agent started while every login of yours was out asks for a team login with a file
    /// (it runs in its own process); the reply names the folder to use. Each start has its own
    /// request, so two at once never share a loan.
    private func answerRequests(_ tabs: [String: TerminalSession]) {
        let dir = AccountStore.requestsDir
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".request") {
            let key = String(name.dropLast(".request".count))
            guard !answering.contains(key) else { continue }
            let url = dir.appendingPathComponent(name)
            let parts = key.split(separator: "~").map(String.init)
            guard parts.count == 3, let provider = AccountProvider(rawValue: parts[1]), tabs[parts[0]] != nil else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            answering.insert(key)
            borrow(provider, tabID: parts[0], excluding: AccountSwitcher.shared.teamExcluded(parts[0])) { [weak self] id in
                guard let self else { return }
                self.answering.remove(key)
                // The agent stopped waiting and started on your own login: give it straight back.
                guard FileManager.default.fileExists(atPath: url.path) else {
                    if let id { self.giveBack(id) }
                    return
                }
                try? FileManager.default.removeItem(at: url)
                AccountStore.answerTeamRequest(key, account: id)
            }
        }
    }

    // MARK: Checking usage

    /// Measures an idle team login: borrows it just for the check, sends back the reading and
    /// any refreshed tokens, then returns it. Nothing runs on it.
    func check(_ account: TeamPool.Account) {
        // Never while an agent here runs on it: two Codex processes refreshing one login's
        // tokens can sign it out.
        if held.values.contains(where: { $0.lease.accountID == account.id }) {
            checkErrors[account.id] = "In use in agterm right now"
            return
        }
        guard let token, !checking.contains(account.id) else { return }
        checking.insert(account.id)
        checkErrors[account.id] = nil
        let generation = generation
        Task {
            var reading: UsageReading?
            var failure: String?
            do {
                let (status, body) = try await Self.send(token, "POST", ["api", "teams", account.teamID, "provider-accounts", account.id, "check"])
                guard let lease = try TeamPool.lease(status: status, body: body, team: account.teamID, provider: account.provider,
                                                     account: account.id, now: Date()) else { throw TeamPool.invalidResponse }
                let id = TeamPool.localID(leaseID: lease.leaseID)
                let home = AccountStore.home(id)
                guard await self.claim(id, lease, generation) else {
                    await Self.release(token, lease)
                    throw TeamPool.Failure(message: "agterm signed out of agmux Teams.", retryable: false)
                }
                if (try? Self.install(lease, id: id)) != nil {
                    let result = await Task.detached { UsageProbe.read(account.provider, home: home) }.value
                    reading = result.reading
                    failure = result.reading == nil ? result.error ?? "Couldn't check its usage." : nil
                } else {
                    failure = "Couldn't save the team account's sign-in."
                }
                let health = TeamPool.Health(reading, now: Date())
                await MainActor.run { _ = self.settingUp.remove(id) }
                await self.finish(id) { await Self.returnLease(token, lease, home: home, health: health) }
            } catch {
                failure = Self.failure(error).message
            }
            let measured = reading, problem = failure
            await MainActor.run {
                self.checking.remove(account.id)
                if let measured { self.readings[account.id] = measured }
                self.checkErrors[account.id] = problem
                self.refresh()
            }
        }
    }

    // MARK: Processes

    /// The process the wrapper recorded as running on this login.
    private static func owner(_ home: URL) -> pid_t? {
        (try? String(contentsOf: home.appendingPathComponent("owner.pid"), encoding: .utf8))
            .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.flatMap { $0 > 1 ? $0 : nil }
    }

    private static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// An agent process: its pid, and when it started, which tells it apart from a later
    /// process that got the same pid after it exited.
    struct Owner: Equatable {
        let pid: pid_t
        let startedAt: Date

        var isRunning: Bool { ProcInfo.startTime(pid: pid) == startedAt }
    }

    /// The process recorded in owner.pid, if it is still the one that wrote the file.
    static func liveOwner(_ home: URL) -> Owner? {
        guard let pid = owner(home), let started = ProcInfo.startTime(pid: pid) else { return nil }
        let written = (try? FileManager.default.attributesOfItem(atPath: home.appendingPathComponent("owner.pid").path))?[.modificationDate] as? Date
        return TeamPool.isOwner(processStartedAt: started, pidFileWrittenAt: written) ? Owner(pid: pid, startedAt: started) : nil
    }

    /// SIGTERM, then SIGKILL for whatever is still there after 3 seconds. Each signal goes only
    /// to the same process, never to a later one that got its pid.
    private static func stop(_ owners: [Owner]) async {
        let running = owners.filter(\.isRunning)
        guard !running.isEmpty else { return }
        running.forEach { kill($0.pid, SIGTERM) }
        for _ in 0..<30 where running.contains(where: \.isRunning) { try? await Task.sleep(nanoseconds: 100_000_000) }
        running.filter(\.isRunning).forEach { kill($0.pid, SIGKILL) }
    }

    // MARK: HTTP

    private static func allocate(_ token: String, provider: AccountProvider, session: String, excluding: Set<String>) async throws -> TeamPool.Lease? {
        let (status, body) = try await send(token, "GET", ["api", "teams"])
        var transient: Error?
        for team in try TeamPool.teams(status: status, body: body) {
            do {
                let (status, body) = try await send(token, "GET", ["api", "teams", team.id, "provider-accounts"])
                guard let pool = try TeamPool.accounts(status: status, body: body, team: team), pool.contains(where: { $0.provider == provider }) else { continue }
                let request: [String: Any] = ["provider": provider.rawValue, "sessionId": String(session.prefix(200)),
                                              "excludeIds": Array(excluding.prefix(50))]
                let (allocated, reply) = try await send(token, "POST", ["api", "teams", team.id, "provider-accounts", "allocate"], body: request)
                if let lease = try TeamPool.lease(status: allocated, body: reply, team: team.id, provider: provider, now: Date()) { return lease }
            } catch let failure as TeamPool.Failure where failure.retryable {
                transient = failure
            }
        }
        if let transient { throw transient }
        return nil
    }

    /// Creates the login's folder (shared conversations and settings, like your own accounts)
    /// with the borrowed auth.json and which loan (and tab) it is, readable by you only.
    private static func install(_ lease: TeamPool.Lease, id: String, tabID: String? = nil) throws -> URL {
        let home = try AccountStore.prepareHome(id, provider: lease.provider)
        var saved: [String: Any] = ["teamID": lease.teamID, "leaseID": lease.leaseID, "accountID": lease.accountID, "label": lease.label]
        if let tabID { saved["tabID"] = tabID }
        guard let record = try? JSONSerialization.data(withJSONObject: saved),
              FileManager.default.createFile(atPath: home.appendingPathComponent("lease.json").path, contents: record, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: home.appendingPathComponent("auth.json").path, contents: lease.credentials, attributes: [.posixPermissions: 0o600]) else {
            throw TeamPool.Failure(message: "Couldn't save the team account's sign-in.", retryable: false)
        }
        return home
    }

    /// The loan a folder belongs to, from its lease.json.
    private static func savedLease(_ home: URL) -> TeamPool.Lease? {
        guard let data = FileManager.default.contents(atPath: home.appendingPathComponent("lease.json").path),
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
              let team = saved["teamID"], let leaseID = saved["leaseID"], let account = saved["accountID"] else { return nil }
        return TeamPool.Lease(teamID: team, leaseID: leaseID, accountID: account, provider: .codex, label: saved["label"] ?? "Team account",
                              credentials: Data(), expiresAt: .distantFuture, remainingPercent: nil)
    }

    /// The tab that borrowed a folder's loan, from its lease.json.
    private static func savedTabID(_ home: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: home.appendingPathComponent("lease.json").path),
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return nil }
        return saved["tabID"]
    }

    private static func renew(_ token: String, _ lease: TeamPool.Lease, home: URL, health: TeamPool.Health?) async throws -> Date {
        // Codex may be replacing the file this instant: a failed read is worth another try.
        guard let credentials = FileManager.default.contents(atPath: home.appendingPathComponent("auth.json").path),
              let body = TeamPool.renewBody(credentials: credentials, health: health) else {
            throw TeamPool.Failure(message: "The team account's sign-in couldn't be read.", retryable: true)
        }
        let (status, reply) = try await send(token, "POST", ["api", "teams", lease.teamID, "provider-accounts", "leases", lease.leaseID, "renew"], body: body)
        return try TeamPool.renewed(status: status, body: reply, leaseID: lease.leaseID, now: Date())
    }

    /// Sends back the latest tokens (and usage, if measured), then returns the loan and deletes
    /// the copy. If the tokens can't be sent, the loan isn't returned early: it lapses on its own,
    /// as the service asks, rather than handing out tokens Codex may have replaced.
    private static func returnLease(_ token: String, _ lease: TeamPool.Lease, home: URL, health: TeamPool.Health? = nil, attempts: Int = 3) async {
        var unsent = false
        for attempt in 1...attempts {
            do {
                _ = try await renew(token, lease, home: home, health: health)
                unsent = false
                break
            } catch {
                // Refused outright (taken back, or already lapsed): returning it is all that's left.
                unsent = failure(error).retryable
                guard unsent, attempt < attempts else { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        if !unsent { await release(token, lease) }
        try? FileManager.default.removeItem(at: home)
    }

    /// Returns a loan with nothing to send back (never installed here).
    private static func release(_ token: String, _ lease: TeamPool.Lease) async {
        _ = try? await send(token, "DELETE", ["api", "teams", lease.teamID, "provider-accounts", "leases", lease.leaseID])
    }

    /// One request to the Teams service. Throws only for network trouble; statuses are the caller's.
    private static func send(_ token: String, _ method: String, _ path: [String], body: [String: Any]? = nil) async throws -> (Int, Data) {
        var url = TeamsAccount.baseURL
        for segment in path { url.appendPathComponent(segment) }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("agterm", forHTTPHeaderField: "X-Client")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard data.count <= 2 * 1024 * 1024 else { throw TeamPool.invalidResponse }
            return (status, data)
        } catch let failure as TeamPool.Failure {
            throw failure
        } catch {
            throw TeamPool.networkError
        }
    }

    private static func failure(_ error: Error) -> TeamPool.Failure {
        error as? TeamPool.Failure ?? TeamPool.networkError
    }
}
