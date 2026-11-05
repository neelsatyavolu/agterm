import AgTermCore
import AgTermSessionKit
import Foundation

/// Team sessions through agmux Teams. Turned on, this Mac lists its agent tabs to teammates who
/// turned it on too; their agents can ask a read-only copy of one (consult answers here, on this
/// Mac) and, if you allow it, message one. It also serves consult's team tools in this Mac's own
/// tabs over a local socket, so the Teams sign-in never leaves the app.
@MainActor
final class TeamSessions: ObservableObject {
    static let shared = TeamSessions()
    nonisolated static var socketPath: String { AgentIntegration.supportDir.appendingPathComponent("team.sock").path }
    private static let teamKey = "teamSessionsTeam"

    struct Team: Decodable, Identifiable, Hashable { let id: String; let slug: String; let name: String }

    @Published private(set) var teams: [Team] = []
    @Published private(set) var enabled = false
    @Published private(set) var acceptMessages = false
    @Published private(set) var lastError: String?
    @Published private(set) var teamID: String? = UserDefaults.standard.string(forKey: teamKey)

    /// The window's tabs; set by MainWindowController.
    var tabs: () -> [TerminalSession] = { [] }

    private var server: LineRPCServer?
    private var timers: [Timer] = []
    private var checkingInbox = false
    /// Bumped whenever sharing changes, so a reply that arrives after it was turned off is dropped.
    private var generation = 0
    /// When each tab is free for the next teammate message, so two never type over each other.
    private var nextTypingAt: [String: Date] = [:]

    // MARK: Lifecycle

    func start() {
        do {
            server = try LineRPCServer(path: Self.socketPath, queue: .main) { [weak self] method, params, reply in
                MainActor.assumeIsolated { self?.serve(method, params, reply) ?? reply(.failure(Self.failure("agterm is quitting."))) }
            }
        } catch {
            NSLog("agterm: couldn't open the team sessions socket: %@", error.localizedDescription)
        }
        refresh()
    }

    /// Re-reads your teams and this team's sharing setting; call after signing in.
    func refresh() {
        guard let token = TeamsAccount.shared.token else { return reset() }
        Task {
            do {
                let list: TeamList = try await TeamsAccount.send("GET", "/api/teams", token: token)
                teams = list.teams
                let saved = teamID.flatMap { id in list.teams.first { $0.id == id } }
                teamID = (saved ?? list.teams.first)?.id
                guard let team = teamID else { return apply(Sharing(enabled: false, acceptMessages: false)) }
                apply(try await TeamsAccount.send("GET", "/api/teams/\(team)/session-sharing", token: token))
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// Signed out: stop reporting. The server forgets this Mac's sessions within two minutes.
    func reset() {
        teams = []
        apply(Sharing(enabled: false, acceptMessages: false))
    }

    func choose(team: String) {
        teamID = team
        UserDefaults.standard.set(team, forKey: Self.teamKey)
        refresh()
    }

    func setSharing(enabled: Bool, acceptMessages: Bool) {
        guard let token = TeamsAccount.shared.token, let team = teamID else { return }
        Task {
            do {
                let body: [String: Any] = ["enabled": enabled, "acceptMessages": enabled && acceptMessages]
                apply(try await TeamsAccount.send("PUT", "/api/teams/\(team)/session-sharing", body: body, token: token))
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func apply(_ sharing: Sharing) {
        generation += 1
        enabled = sharing.enabled
        acceptMessages = sharing.acceptMessages
        timers.forEach { $0.invalidate() }
        timers = []
        guard enabled else { return }
        timers = [repeatEvery(TeamSessionsWire.reportInterval) { [weak self] in self?.report() },
                  repeatEvery(TeamSessionsWire.inboxInterval) { [weak self] in self?.checkInbox() }]
        report()
    }

    private func repeatEvery(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: seconds, repeats: true) { _ in MainActor.assumeIsolated { work() } }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: Sharing this Mac's tabs

    private func report() {
        guard enabled, let token = TeamsAccount.shared.token, let team = teamID else { return }
        // Cloud tabs stay out: agterm only learns their foreground a moment late, so it can't
        // promise a message lands in the agent rather than at a shell prompt.
        let sessions = tabs().filter { !$0.isCloud }.compactMap { tab -> TeamSessionsWire.Session? in
            tab.pollProcess()
            return TeamSessionsWire.session(tabID: tab.tabID, agent: tab.agentName, topic: tab.topic, cwd: tab.cwd,
                                            branch: tab.git?.branch, status: tab.status, conversation: tab.agentConversationID)
        }
        Task {
            do {
                let body = ["sessions": try sessions.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }]
                let _: Ignored = try await TeamsAccount.send("PUT", "/api/teams/\(team)/live-sessions", body: body, token: token)
            } catch {
                handle(error)
            }
        }
    }

    private func checkInbox() {
        guard enabled, !checkingInbox, let token = TeamsAccount.shared.token, let team = teamID else { return }
        checkingInbox = true
        let started = generation
        Task {
            defer { checkingInbox = false }
            do {
                let inbox: Inbox = try await TeamsAccount.send("POST", "/api/teams/\(team)/session-inbox", body: [:], token: token)
                // Turned off, signed out or switched team meanwhile: run nothing (the server fails them).
                guard started == generation, enabled, teamID == team else { return }
                for request in inbox.requests { take(request, team: team, token: token) }
            } catch {
                handle(error)
            }
        }
    }

    private func take(_ request: TeamSessionsWire.InboxRequest, team: String, token: String) {
        let finish: (Result<String, Error>) -> Void = { result in
            Task {
                var body: [String: Any] = [:]
                switch result {
                case .success(let answer): body["answer"] = answer
                case .failure(let error): body["error"] = error.localizedDescription
                }
                let _: Ignored? = try? await TeamsAccount.send("POST", "/api/teams/\(team)/session-requests/\(request.id)/answer",
                                                              body: body, token: token)
            }
        }
        guard let tab = tabs().first(where: { $0.tabID == request.sessionKey && !$0.isCloud }) else {
            return finish(.failure(Self.failure("That tab was closed.")))
        }
        switch request.kind {
        case "message":
            guard acceptMessages else { return finish(.failure(Self.failure("They don't accept messages any more."))) }
            deliver(TeamSessionsWire.typedMessage(from: request.from, body: request.body), to: tab,
                    allowed: { [weak self] in self?.acceptMessages == true }, finish: finish)
        case "ask":
            tab.pollProcess()
            guard let agent = tab.agentName, TeamSessionsWire.askableAgents.contains(agent),
                  let conversation = tab.agentConversationID else {
                return finish(.failure(Self.failure("That tab's agent can't be copied right now.")))
            }
            let input = TeamSessionsWire.answerRequest(agent: agent, conversation: conversation, cwd: tab.cwd,
                                                       question: request.body, effort: request.effort)
            let login = loginEnvironment(tab, agent: agent)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.answer(input, environment: login)
                DispatchQueue.main.async { finish(result) }
            }
        default:
            finish(.failure(Self.failure("This version of agterm doesn't know that request.")))
        }
    }

    /// Types a message into the tab's agent: one at a time per tab, and only while the same agent
    /// is still in the foreground and `allowed` holds, so it can never land at a shell prompt.
    func deliver(_ text: String, to tab: TerminalSession, allowed: @escaping () -> Bool,
                 finish: @escaping (Result<String, Error>) -> Void) {
        tab.pollProcess()
        guard !tab.isCloud, let agent = tab.agentName else { return finish(.failure(Self.failure("That tab's agent has exited."))) }
        let start = max(Date(), nextTypingAt[tab.tabID] ?? .distantPast)
        nextTypingAt[tab.tabID] = start.addingTimeInterval(1)
        let stillThere = { [weak self] () -> Bool in
            tab.pollProcess()
            return self != nil && tab.agentName == agent && allowed()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, start.timeIntervalSinceNow)) {
            MainActor.assumeIsolated {
                guard stillThere() else { return finish(.failure(Self.failure("That tab's agent has exited."))) }
                tab.view.send(txt: "\u{15}" + text)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    MainActor.assumeIsolated {
                        guard stillThere() else {
                            tab.view.send(txt: "\u{15}")
                            return finish(.failure(Self.failure("That tab's agent has exited.")))
                        }
                        tab.view.send(txt: "\r")
                        finish(.success("Delivered."))
                    }
                }
            }
        }
    }

    /// The login folder of the account this tab's agent runs on, when it isn't yours, so the copy
    /// signs in the same way the tab does (CLAUDE_CONFIG_DIR, CODEX_HOME or GROK_HOME).
    private func loginEnvironment(_ tab: TerminalSession, agent: String) -> [String: String] {
        guard let provider = AccountProvider(rawValue: agent), let launch = tab.launchRecord(provider) else { return [:] }
        let home = AccountStore.home(launch.account).path
        return FileManager.default.fileExists(atPath: home) ? [provider.homeVariable: home] : [:]
    }

    /// Runs consult's `--answer-team-ask` mode: one read-only copy of the conversation, with your
    /// login shell's PATH (a Dock-launched app's own PATH lacks Homebrew, nvm and ~/.local/bin).
    private nonisolated static func answer(_ input: Data, environment login: [String: String]) -> Result<String, Error> {
        let path = QuickCommandRunner.shared.searchPath
        let node = path.split(separator: ":").map { $0 + "/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let bundle = AgentIntegration.shippedConsultBundle(), let node else {
            return .failure(failure("consult can't run on their Mac (it needs Node.js 22 or later)."))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [bundle, "--answer-team-ask"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        environment.merge(login) { _, tab in tab }
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            stdin.fileHandleForWriting.write(input)
            try stdin.fileHandleForWriting.close()
            // Drain both pipes at once so a chatty stderr can't stall the copy.
            nonisolated(unsafe) var err = Data()
            let drained = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                err = stderr.fileHandleForReading.readDataToEndOfFile()
                drained.signal()
            }
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            drained.wait()
            process.waitUntilExit()
            if process.terminationStatus == 0,
               let object = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any],
               let answer = object["answer"] as? String {
                return .success(answer)
            }
            let reason = String(decoding: err, as: UTF8.self).split(separator: "\n").last.map(String.init)
            return .failure(failure(reason ?? "The copy of the session failed."))
        } catch {
            return .failure(error)
        }
    }

    private func handle(_ error: Error) {
        if case TeamsAccount.TeamsError.unauthorized = error { return TeamsAccount.shared.tokenRejected() }
        NSLog("agterm: team sessions: %@", error.localizedDescription)
    }

    // MARK: consult's team tools in this Mac's tabs

    private func serve(_ method: String, _ params: [String: Any], _ reply: @escaping LineRPCServer.Reply) {
        if serveLocal(method, params, reply) { return }
        guard let token = TeamsAccount.shared.token else {
            return reply(.failure(Self.failure("Sign in to agmux Teams in agterm Settings → Teams & Phone first.")))
        }
        guard enabled, let team = teamID else {
            return reply(.failure(Self.failure("Turn on team sessions in agterm Settings → Teams & Phone first.")))
        }
        let session = params["session_id"] as? String ?? ""
        Task {
            do {
                switch method {
                case "team.list":
                    let list: LiveList = try await TeamsAccount.send("GET", "/api/teams/\(team)/live-sessions", token: token)
                    reply(.success(["sessions": try list.sessions.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) }]))
                case "team.ask":
                    var body: [String: Any] = ["kind": "ask", "body": params["question"] as? String ?? ""]
                    body["effort"] = params["effort"] as? String
                    let started = Date()
                    let created: Created = try await TeamsAccount.send("POST", "/api/teams/\(team)/live-sessions/\(session)/requests",
                                                                       body: body, token: token)
                    let answer = try await waitForAnswer(created.id, team: team, token: token)
                    reply(.success(["answer": answer, "member": created.member, "agent": created.agent,
                                    "durationMs": Int(Date().timeIntervalSince(started) * 1000)]))
                case "team.send":
                    let body: [String: Any] = ["kind": "message", "body": params["message"] as? String ?? ""]
                    let created: Created = try await TeamsAccount.send("POST", "/api/teams/\(team)/live-sessions/\(session)/requests",
                                                                       body: body, token: token)
                    reply(.success(["member": created.member, "agent": created.agent]))
                default:
                    reply(.failure(Self.failure("agterm doesn't know \(method).")))
                }
            } catch {
                reply(.failure(error))
            }
        }
    }

    private func waitForAnswer(_ id: String, team: String, token: String) async throws -> String {
        let deadline = Date().addingTimeInterval(TeamSessionsWire.askTimeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(TeamSessionsWire.answerPollInterval * 1_000_000_000))
            let state: RequestState = try await TeamsAccount.send("GET", "/api/teams/\(team)/session-requests/\(id)", token: token)
            switch state.status {
            case "answered": return state.answer ?? ""
            case "failed": throw Self.failure(state.error ?? "Their Mac couldn't answer.")
            default: continue
            }
        }
        throw Self.failure("No answer came back in time.")
    }

    private nonisolated static func failure(_ message: String) -> LineRPCServer.Failure { LineRPCServer.Failure(message) }

    // MARK: Wire

    private struct TeamList: Decodable { let teams: [Team] }
    private struct Sharing: Decodable { let enabled: Bool; let acceptMessages: Bool }
    private struct Inbox: Decodable { let requests: [TeamSessionsWire.InboxRequest] }
    private struct Created: Decodable { let id: String; let member: String; let agent: String }
    private struct RequestState: Decodable { let status: String; let answer: String?; let error: String? }
    private struct Ignored: Decodable {}
    private struct LiveList: Decodable { let sessions: [LiveSession] }
    /// A teammate's session as list_team_sessions shows it.
    private struct LiveSession: Codable {
        let session_id: String
        let member: String
        let mine: Bool
        let agent: String
        let title: String?
        let project: String?
        let branch: String?
        let status: String
        let can_ask: Bool
        let accepts_messages: Bool
        let last_reported: String
    }
}
