import AgTermCore
import Combine
import Foundation

/// What the Teams window shows: your teams, the chosen team's overview for a range, members'
/// details and the team's pooled logins. Fetches only when the window opens, when you press
/// Refresh or change team or range; never in the background. The last replies are kept on disk,
/// so the window opens with numbers and still has them offline.
@MainActor
final class TeamDashboardStore: ObservableObject {
    static let shared = TeamDashboardStore()

    @Published private(set) var teams: [TeamDashboard.Team] = []
    @Published private(set) var teamsLoaded = false
    @Published var teamID: String? {
        didSet { UserDefaults.standard.set(teamID, forKey: "teamsDashboardTeam"); if oldValue != teamID, !quietly { reload() } }
    }
    @Published var range: TeamDashboard.Range {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: "teamsDashboardRange"); if oldValue != range { reload() } }
    }
    @Published private(set) var overview: TeamDashboard.Overview?
    /// When `overview` was fetched; older than this session's fetch while offline.
    @Published private(set) var fetchedAt: Date?
    /// Your own numbers, for roles that see only themselves.
    @Published private(set) var me: TeamDashboard.MemberDetail?
    @Published private(set) var loading = false
    @Published private(set) var failure: TeamDashboard.Failure?
    /// The team's shared Codex and Grok logins, kept in step with `TeamAccounts`.
    @Published var pool: [TeamPool.Account] = []

    private var cache: TeamDashboard.Cache
    private var details: [String: TeamDashboard.MemberDetail] = [:]
    private var fetch: Task<Void, Never>?
    private var watchers: Set<AnyCancellable> = []
    /// Self-tests show fixtures and never touch the network.
    var offlineFixtures = false

    private init() {
        range = UserDefaults.standard.string(forKey: "teamsDashboardRange").flatMap(TeamDashboard.Range.init) ?? .month
        teamID = UserDefaults.standard.string(forKey: "teamsDashboardTeam")
        cache = (try? Data(contentsOf: Self.cacheURL)).flatMap { try? JSONDecoder().decode(TeamDashboard.Cache.self, from: $0) } ?? .init()
        if let list = cache.teams?.value { teams = list.teams; teamsLoaded = true }
        showCached()
        TeamAccounts.shared.$accounts.receive(on: DispatchQueue.main).sink { [weak self] in self?.pool = $0 }.store(in: &watchers)
        TeamsAccount.shared.$state.receive(on: DispatchQueue.main).sink { [weak self] state in
            if state == .signedOut { self?.forget() }
        }.store(in: &watchers)
    }

    static var cacheURL: URL { AgentIntegration.supportDir.appendingPathComponent("teams-dashboard.json") }

    var signedIn: Bool { offlineFixtures ? fixtureSignedIn : token != nil }
    private var fixtureSignedIn = true
    var team: TeamDashboard.Team? { teams.first { $0.id == teamID } }
    var teamPool: [TeamPool.Account] { pool.filter { $0.teamID == teamID } }

    private var token: String? {
        #if DEBUG
        if let token = ProcessInfo.processInfo.environment["AGTERM_TEAMS_TOKEN"] { return token }
        #endif
        return TeamsAccount.shared.token
    }

    // MARK: Fetching

    /// Your teams, then the chosen one's overview.
    func refresh() {
        guard !offlineFixtures else { return }
        TeamAccounts.shared.refresh()
        load(teamsFirst: true)
    }

    private func reload() {
        guard !offlineFixtures else { return }
        showCached()
        load(teamsFirst: false)
    }

    private func load(teamsFirst: Bool) {
        fetch?.cancel()
        guard let token else { return forget() }
        loading = true
        let range = range
        fetch = Task {
            do {
                if teamsFirst || !teamsLoaded {
                    let list: TeamDashboard.TeamList = try await Self.get(["api", "teams"], token: token)
                    guard !Task.isCancelled else { return }
                    accept(list)
                }
                guard let id = teamID else { return finish(nil) }
                let overview: TeamDashboard.Overview = try await Self.get(["api", "teams", id, "overview"], query: ["range": range.rawValue], token: token)
                var me: TeamDashboard.MemberDetail?
                if overview.state == .selfOnly {
                    me = try await Self.get(["api", "teams", id, "me"], query: ["range": range.rawValue], token: token)
                }
                guard !Task.isCancelled else { return }
                self.overview = overview
                self.me = me
                self.fetchedAt = Date()
                details = [:]
                cache.store(overview, team: id, range: range, at: Date())
                save()
                finish(nil)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                finish(error as? TeamDashboard.Failure ?? .offline)
            }
        }
    }

    private func accept(_ list: TeamDashboard.TeamList) {
        teams = list.teams
        teamsLoaded = true
        cache.store(list, at: Date())
        if team == nil {
            // Admins first: they're who the dashboard is for.
            let pick = list.teams.first { $0.role.isAdmin } ?? list.teams.first
            if teamID != pick?.id {
                // This fetch goes on to load it.
                setTeamQuietly(pick?.id)
                showCached()
            }
        }
        save()
    }

    private var quietly = false
    /// Picks a team without starting another fetch.
    private func setTeamQuietly(_ id: String?) {
        quietly = true
        teamID = id
        quietly = false
    }

    private func finish(_ failure: TeamDashboard.Failure?) {
        loading = false
        self.failure = failure
        if failure == .signedOut { TeamsAccount.shared.tokenRejected() }
    }

    /// One member's detail for the current range, fetched once per overview.
    func detail(_ userID: String) async -> Result<TeamDashboard.MemberDetail, TeamDashboard.Failure> {
        if let cached = details[userID] { return .success(cached) }
        guard let token, let id = teamID else { return .failure(.signedOut) }
        do {
            let detail: TeamDashboard.MemberDetail = try await Self.get(["api", "teams", id, "members", userID, "detail"],
                                                                        query: ["range": range.rawValue], token: token)
            details[userID] = detail
            return .success(detail)
        } catch {
            return .failure(error as? TeamDashboard.Failure ?? .offline)
        }
    }

    // MARK: Cache

    private func showCached() {
        guard let id = teamID, let entry = cache.overview(team: id, range: range) else {
            overview = nil; fetchedAt = nil; me = nil
            return
        }
        overview = entry.value
        fetchedAt = entry.fetchedAt
        if entry.value.state != .selfOnly { me = nil }
    }

    private func save() {
        guard !offlineFixtures, let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.cacheURL, options: .atomic)
    }

    /// Signed out: nothing of the team's stays on this Mac.
    private func forget() {
        fetch?.cancel()
        cache = .init()
        teams = []
        teamsLoaded = false
        overview = nil
        me = nil
        details = [:]
        fetchedAt = nil
        failure = nil
        loading = false
        try? FileManager.default.removeItem(at: Self.cacheURL)
    }

    // MARK: HTTP

    private static func get<T: Decodable>(_ path: [String], query: [String: String] = [:], token: String) async throws -> T {
        var url = TeamsAccount.baseURL
        for segment in path { url.appendPathComponent(segment) }
        if !query.isEmpty, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            url = parts.url ?? url
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("agterm", forHTTPHeaderField: "X-Client")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TeamDashboard.Failure.offline
        }
        return try TeamDashboard.unwrap(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    #if DEBUG
    /// Fills the window from fixtures for a self-test.
    func show(teams: [TeamDashboard.Team], overview: TeamDashboard.Overview?, me: TeamDashboard.MemberDetail? = nil,
              details: [String: TeamDashboard.MemberDetail] = [:], pool: [TeamPool.Account] = [],
              failure: TeamDashboard.Failure? = nil, fetchedAt: Date? = Date(), signedIn: Bool = true, loaded: Bool = true) {
        offlineFixtures = true
        fixtureSignedIn = signedIn
        watchers.removeAll()
        self.teams = teams
        teamsLoaded = loaded
        setTeamQuietly(teams.first?.id)
        self.overview = overview
        self.me = me
        self.details = details
        self.pool = pool
        self.failure = failure
        self.fetchedAt = fetchedAt
        loading = false
    }
    #endif
}
