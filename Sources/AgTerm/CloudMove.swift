import AgTermCore
import AgTermSessionKit
import Foundation

/// Move All to Cloud (docs/cloud-sessions-plan.md). Each local tab's agent is stopped at a turn
/// boundary (as a login switch does), its folder and conversation are copied to the cloud
/// machine at the same paths, and a cloud tab takes its place, resuming the conversation, with
/// "Continue where you left off." if a turn was cut short. Other running commands are left
/// stopped. Main queue, except the copying.
final class CloudMove {
    static let continuePrompt = "Continue where you left off."

    /// One tab and what moving it involves.
    struct Item {
        let session: TerminalSession
        /// The folder to copy, if any.
        let folder: String?
        /// The agent in the tab, or a command that will be stopped.
        let agent: String?
        let stoppedCommand: String?

        /// One line for the preflight list.
        var summary: String {
            let place = session.folder
            if let agent { return "\(agent) in \(place): continues in the cloud" }
            if let stoppedCommand { return "\(stoppedCommand) in \(place): stopped, the shell moves" }
            return "shell in \(place): a new shell in the cloud"
        }
    }

    enum Outcome {
        case moved(Int)
        case failed(String)
    }

    /// A tab once its agent or command has stopped: how to bring the agent back (in the cloud,
    /// or here if the move fails) and which of its files to copy.
    private struct Frozen {
        let item: Item
        let resume: String?
        let state: [String]
    }

    private let cloud: CloudHost
    private let isOpen: (TerminalSession) -> Bool
    private let replace: (TerminalSession, TerminalSession) -> Void

    /// `isOpen` says whether a tab is still there (it may be closed mid-move); `replace` puts the
    /// cloud tab where the local one was and ends the local shell.
    init(cloud: CloudHost, isOpen: @escaping (TerminalSession) -> Bool, replace: @escaping (TerminalSession, TerminalSession) -> Void) {
        self.cloud = cloud
        self.isOpen = isOpen
        self.replace = replace
    }

    /// What moving these tabs would do; cloud tabs and ended shells are skipped.
    static func preflight(_ sessions: [TerminalSession]) -> [Item] {
        let home = NSHomeDirectory()
        return sessions.filter { !$0.isCloud && !$0.signals.exited }.map { session in
            session.pollProcess()
            let agent = session.agentName
            let command = agent == nil && session.isRunningProgram ? session.foregroundName : nil
            let folder = CloudMovePlan.folder(cwd: session.cwd, gitRoot: gitRoot(of: session.cwd), hasAgent: agent != nil,
                                              home: home, resolve: realPath)
            return Item(session: session, folder: folder, agent: agent, stoppedCommand: command)
        }
    }

    func run(_ items: [Item], done: @escaping (Outcome) -> Void) {
        guard !items.isEmpty else { return done(.moved(0)) }
        // Checked before anything stops: agents mustn't be stopped for a move that can't happen.
        if let problem = problem() { return done(.failed(problem)) }
        var frozen: [Frozen] = []
        for item in items {
            freeze(item) { tab in
                frozen.append(tab)
                if frozen.count == items.count { self.copy(frozen, done: done) }
            }
        }
    }

    // MARK: Steps

    private func problem() -> String? {
        guard let binary = Bundle.main.executableURL?.path, !binary.contains(" ") else {
            return "agterm's path has a space, which rsync can't use."
        }
        guard cloud.list() != nil else { return "The cloud machine at \(cloud) didn't answer." }
        return nil
    }

    /// Stops the agent once its turn ends (or after 20 s), or a command at once, so nothing
    /// changes files while they are copied.
    private func freeze(_ item: Item, then next: @escaping (Frozen) -> Void) {
        let session = item.session
        guard item.agent != nil || item.stoppedCommand != nil else { return next(Frozen(item: item, resume: nil, state: [])) }
        // Read while the agent runs: its process is the only record of its conversation.
        let plain = session.resumeCommand()
        let state = Self.agentState(session)
        let group = session.foregroundGroup
        let stillThere = { session.foregroundGroup == group }
        let busy = { session.signals.agentBusy == true || session.status == .working }
        Self.wait(upTo: item.agent == nil ? 0 : 20, until: { !stillThere() || !busy() }) { _ in
            guard stillThere() else { return next(Frozen(item: item, resume: plain, state: state)) }
            // Only an agent cut off mid-turn is told to continue.
            let resume = item.agent == nil ? nil : (busy() ? session.resumeCommand(prompt: Self.continuePrompt) : nil) ?? plain
            session.signalForeground(SIGTERM)
            Self.wait(upTo: 6, until: { !session.isRunningProgram }) { stopped in
                if !stopped, stillThere() { session.signalForeground(SIGKILL) }
                Self.wait(upTo: 3, until: { !session.isRunningProgram }) { _ in next(Frozen(item: item, resume: resume, state: state)) }
            }
        }
    }

    private func copy(_ frozen: [Frozen], done: @escaping (Outcome) -> Void) {
        let home = NSHomeDirectory()
        let folders = CloudMovePlan.roots(frozen.compactMap(\.item.folder))
        let state = frozen.flatMap(\.state) + (frozen.contains { $0.item.agent != nil } ? CloudMovePlan.userConfig(home: home) : [])
        let cloud = cloud
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try CloudSync.push(folders: folders, files: state, to: cloud)
            } catch {
                return DispatchQueue.main.async {
                    self.restartHere(frozen)
                    done(.failed("\(error)"))
                }
            }
            DispatchQueue.main.async { self.reopen(frozen, done: done) }
        }
    }

    /// Opens the cloud tabs, then reports once their agents run there, so quitting right after
    /// can't catch an agent before it has started.
    private func reopen(_ frozen: [Frozen], done: @escaping (Outcome) -> Void) {
        var opened: [(tab: TerminalSession, resumes: Bool)] = []
        var failures: [String] = []
        for tab in frozen {
            let old = tab.item.session
            // Closed while its files were copied: nothing to move.
            guard isOpen(old) else { continue }
            var saved = old.snapshot()
            saved.resume = nil
            do {
                let moved = try TerminalSession(cloud: cloud, cwd: old.cwd, saved: saved, command: tab.resume)
                replace(old, moved)
                opened.append((moved, tab.resume != nil))
            } catch {
                failures.append("\(old.folder): \(error)")
                restartHere([tab])
            }
        }
        let agents = opened.filter(\.resumes).map(\.tab)
        Self.wait(upTo: 30, until: { agents.allSatisfy { $0.pollProcess(); return $0.agentName != nil } }) { started in
            if !started { failures.append("An agent didn't start again in the cloud; check its tab.") }
            done(failures.isEmpty ? .moved(opened.count) : .failed(failures.joined(separator: "\n")))
        }
    }

    /// The move failed: agents start again here, in their own tabs, at the shell prompt.
    private func restartHere(_ frozen: [Frozen]) {
        for tab in frozen {
            let session = tab.item.session
            guard let resume = tab.resume, isOpen(session), !session.isRunningProgram else { continue }
            session.view.send(txt: "\u{15}" + resume + "\r")
        }
    }

    // MARK: Helpers

    /// The agent's conversation files: Claude's project folder, Codex's rollout.
    private static func agentState(_ session: TerminalSession) -> [String] {
        let home = NSHomeDirectory()
        var paths: [String] = []
        if let id = session.claudeSessionID {
            let projects = (try? FileManager.default.contentsOfDirectory(atPath: home + "/.claude/projects")) ?? []
            if let project = CloudMovePlan.claudeProject(sessionID: id, home: home, projects: projects,
                                                         exists: { FileManager.default.fileExists(atPath: $0) }) {
                paths.append(project)
            }
        }
        if let rollout = session.codexRollout { paths.append(rollout) }
        return paths
    }

    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func gitRoot(of folder: String) -> String? {
        var url = URL(fileURLWithPath: folder)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// Checks `condition` every 0.25 s; `done(true)` once it holds, `done(false)` at the deadline.
    static func wait(upTo seconds: TimeInterval, until condition: @escaping () -> Bool, then done: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(seconds)
        func check() {
            if condition() { return done(true) }
            if Date() >= deadline { return done(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: check)
        }
        check()
    }
}
