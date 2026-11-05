import AgTermCore
import AgTermSessionKit
import Foundation

/// The channels consult offers agents in this Mac's tabs, served from the app: the agent tabs on
/// this Mac (the same `sessions.list` / `sessions.send` calls agmux's room socket answers, so they
/// work without agmux), and the board, on agmux Teams with team sessions on, else on this Mac.
extension TeamSessions {
    /// Team sessions are on and signed in: the board and team tools go to agmux Teams.
    var liveTeam: (token: String, team: String)? {
        guard enabled, let token = TeamsAccount.shared.token, let team = teamID else { return nil }
        return (token, team)
    }

    /// Answers the local and board calls; false for anything else (the team.* tools).
    func serveLocal(_ method: String, _ params: [String: Any], _ reply: @escaping LineRPCServer.Reply) -> Bool {
        switch method {
        case "team.status":
            reply(.success(["teamSessions": liveTeam != nil]))
        case "sessions.list":
            reply(.success(["sessions": localSessions(callerPid: (params["callerPid"] as? NSNumber)?.int32Value)]))
        case "sessions.send":
            sendLocal(to: params["to"] as? String ?? "", text: params["text"] as? String ?? "",
                      callerPid: (params["callerPid"] as? NSNumber)?.int32Value, reply: reply)
        case "board.read", "board.post", "board.update":
            if let live = liveTeam { serveTeamBoard(method, params, live, reply) } else { serveLocalBoard(method, params, reply) }
        default:
            return false
        }
        return true
    }

    // MARK: Agents on this Mac

    private func callerTab(_ pid: pid_t?) -> TerminalSession? {
        guard let pid else { return nil }
        return tabs().first { $0.foregroundJob == pid }
    }

    /// Every agent tab but the caller's, in the shape consult's list_sessions shows.
    private func localSessions(callerPid: pid_t?) -> [[String: Any]] {
        let caller = callerTab(callerPid)
        let iso = ISO8601DateFormatter()
        return tabs().compactMap { tab in
            tab.pollProcess()
            guard tab !== caller, !tab.isCloud, let agent = tab.agentName else { return nil }
            var row: [String: Any] = ["session_id": tab.tabID, "agent": agent, "title": tab.topic, "cwd": tab.cwd,
                                      "status": TeamSessionsWire.reportedStatus(tab.status)]
            row["branch"] = tab.git?.branch
            row["last_active"] = tab.signals.lastOutput.map(iso.string)
            if let conversation = tab.agentConversationID {
                row["fork"] = ["agent": agent, "session_id": conversation, "cwd": tab.cwd]
            }
            return row
        }
    }

    private func sendLocal(to tabID: String, text: String, callerPid: pid_t?, reply: @escaping LineRPCServer.Reply) {
        guard let tab = tabs().first(where: { $0.tabID == tabID && !$0.isCloud }), let agent = tab.agentName else {
            return reply(.failure(LineRPCServer.Failure("No agent tab \(tabID) on this Mac; call list_sessions again.")))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_000 else {
            return reply(.failure(LineRPCServer.Failure("Send between 1 and 4000 characters.")))
        }
        let sender = callerTab(callerPid)
        let typed = TeamSessionsWire.localMessage(fromAgent: sender?.agentName, tab: sender?.topic, body: trimmed)
        let status = TeamSessionsWire.reportedStatus(tab.status)
        deliver(typed, to: tab, allowed: { true }) { result in
            switch result {
            case .success: reply(.success(["agent": agent, "status": status]))
            case .failure(let error): reply(.failure(error))
            }
        }
    }

    // MARK: The board

    private func serveTeamBoard(_ method: String, _ params: [String: Any], _ live: (token: String, team: String),
                                _ reply: @escaping LineRPCServer.Reply) {
        Task {
            do {
                let base = "/api/teams/\(live.team)/board"
                switch method {
                case "board.read":
                    var query = [URLQueryItem(name: "project", value: params["project"] as? String ?? "")]
                    if let since = params["since"] as? String { query.append(URLQueryItem(name: "since", value: since)) }
                    reply(.success(try await TeamsAccount.sendRaw("GET", base, query: query, token: live.token)))
                case "board.post":
                    reply(.success(try await TeamsAccount.sendRaw("POST", base, body: params, token: live.token)))
                default:
                    var body = params
                    let id = body.removeValue(forKey: "id") as? String ?? ""
                    reply(.success(try await TeamsAccount.sendRaw("PATCH", "\(base)/\(id)", body: body, token: live.token)))
                }
            } catch {
                reply(.failure(error))
            }
        }
    }

    private func serveLocalBoard(_ method: String, _ params: [String: Any], _ reply: @escaping LineRPCServer.Reply) {
        let now = Date()
        let iso = ISO8601DateFormatter()
        do {
            let result: Any = try LocalBoardFile.shared.change { board in
                switch method {
                case "board.read":
                    let project = params["project"] as? String ?? ""
                    let since = (params["since"] as? String).flatMap(iso.date(from:))
                    return ["project": project, "now": iso.string(from: now),
                            "items": board.read(project: project, since: since, now: now, member: "You")]
                case "board.post":
                    let item = try board.post(project: params["project"] as? String ?? "", kind: params["kind"] as? String ?? "",
                                              text: params["text"] as? String ?? "", replyTo: params["replyTo"] as? String,
                                              hours: (params["hours"] as? NSNumber)?.doubleValue, agent: params["agent"] as? String, now: now)
                    var posted: [String: Any] = ["id": item.id]
                    posted["expires"] = item.expires.map(iso.string)
                    return posted
                default:
                    try board.update(id: params["id"] as? String ?? "", status: params["status"] as? String,
                                     renew: params["renew"] as? Bool ?? false, hours: (params["hours"] as? NSNumber)?.doubleValue,
                                     text: params["text"] as? String, now: now)
                    return ["ok": true]
                }
            }
            reply(.success(result))
        } catch {
            reply(.failure(error))
        }
    }
}

/// This Mac's board, in a file next to agterm's other state, swept on every change.
final class LocalBoardFile {
    static let shared = LocalBoardFile()
    private let url = AgentIntegration.supportDir.appendingPathComponent("board.json")
    private let lock = NSLock()

    /// Runs `body` on the saved board and saves it; a save that fails fails the call, so an agent
    /// is never told it holds a claim nobody else can see.
    func change<T>(_ body: (inout LocalBoard) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var board = try load()
        board.sweep(now: Date())
        let result = try body(&board)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.iso.encode(board).write(to: url, options: .atomic)
        } catch {
            throw LineRPCServer.Failure("agterm couldn't save the board: \(error.localizedDescription)")
        }
        return result
    }

    /// The saved board; none yet is empty. An unreadable file is set aside (board-unreadable-<date>.json)
    /// and a new board starts, rather than failing every call.
    private func load() throws -> LocalBoard {
        guard let data = try? Data(contentsOf: url) else { return LocalBoard() }
        if let board = try? JSONDecoder.iso.decode(LocalBoard.self, from: data) { return board }
        let aside = url.deletingLastPathComponent().appendingPathComponent("board-unreadable-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: aside)
        NSLog("agterm: the board file was unreadable; moved it to %@", aside.path)
        return LocalBoard()
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
