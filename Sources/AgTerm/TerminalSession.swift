import AgTermCore
import AppKit
import SwiftTerm

/// One tab: a shell in a pty plus what we know about the program running in it.
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let view: AgentTerminalView
    private(set) var rawTitle = ""
    private(set) var parsedTitle = ParsedTitle(topic: "", activity: .unknown)
    private(set) var cwd: String
    private(set) var foregroundName: String?
    private var foregroundPid: pid_t?
    private(set) var git: GitSummary?
    /// The coding agent in the foreground (claude, codex, grok…), if any.
    private(set) var agentName: String?
    /// Working tree when that agent started; its changes are measured from here.
    var agentBaseline: GitPoller.AgentBaseline?
    var agentBaselineRequested = false
    private(set) var agentDiff: (added: Int, removed: Int)?
    /// When the current agent started, and (for Claude) the conversation it's in.
    private(set) var agentStartedAt: Date?
    private(set) var claudeSessionID: String?
    private(set) var signals = StatusSignals()
    private(set) var status: TabStatus = .idle
    let shellName: String

    /// Called when anything shown on the tab may have changed.
    var onChange: (() -> Void)?
    /// Called when the status changes (for notifications).
    var onStatusChange: ((TabStatus) -> Void)?
    /// Called when the shell exits on its own with status 0.
    var onCleanExit: (() -> Void)?
    /// Typed into the shell once its first prompt appears (resuming a restored agent).
    private var pendingCommand: String?

    /// `restoring` brings back a tab saved at the last quit: its history, then its agent.
    /// `command` is typed at the first prompt (starting an agent from the Shell menu).
    init(cwd: String, restoring saved: SavedTab? = nil, command: String? = nil) {
        self.cwd = cwd
        let shell = ProcInfo.loginShell()
        shellName = (shell as NSString).lastPathComponent
        var options = TerminalOptions.default
        options.scrollback = Scrollback.maxLines
        view = AgentTerminalView(frame: .zero, font: nil, options: options)
        super.init()
        configure()
        applyAppearance()
        view.processDelegate = self
        if let saved {
            if !saved.scrollback.isEmpty {
                view.feed(text: saved.scrollback + "\r\n\u{1b}[0;2m— restored \(Self.restoredStamp()) —\u{1b}[0m\r\n")
            }
            pendingCommand = saved.resume
        }
        if let command { pendingCommand = command }
        view.startProcess(executable: shell, args: [], environment: environment(),
                          execName: "-" + shellName, currentDirectory: cwd)
    }

    private static func restoredStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }

    /// The visible screen as plain text, trailing blank rows dropped (for the phone remote).
    func screenText() -> String {
        let terminal = view.getTerminal()
        var rows = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows.joined(separator: "\n")
    }

    /// What to save so this tab can be reopened: folder, history and, for agents that can
    /// resume a conversation, the command that brings them back.
    func snapshot() -> SavedTab {
        pollProcess()
        var resume: String?
        if let fg = foregroundPid, fg != view.process.shellPid, !signals.exited {
            let argv = ProcInfo.arguments(pid: fg)
            resume = AgentResume.commandLine(argv: argv, claudeSessionID: ProcInfo.claudeSessionID(pid: fg))
                ?? codexResume(argv: argv)
                ?? agentName.flatMap { AgentResume.continueCommandLine(agent: $0, argv: argv) }
        }
        return SavedTab(cwd: cwd, scrollback: Scrollback.capture(view.getTerminal()), resume: resume ?? pendingCommand)
    }

    /// `codex resume <id>` for the conversation this tab's Codex has open (it keeps its rollout
    /// file open), with the options it was started with.
    private func codexResume(argv: [String]) -> String? {
        guard agentName == "codex", let group = foregroundGroup,
              let rollout = ProcInfo.openFiles(group: group, matching: { $0.contains("/sessions/") && $0.hasSuffix(".jsonl") && $0.contains("rollout-") }).first,
              let header = Self.firstLine(rollout), let id = AgentResume.codexSessionID(rolloutHeader: header) else { return nil }
        // The wrapper recorded your arguments for this very run; else read them off the process.
        let launch = AccountStore.launch(tabID: tabID, provider: .codex)
        let args = launch.flatMap { launch in agentStartedAt.map { abs(launch.startedAt.timeIntervalSince($0)) < 20 } == true ? launch.args : nil }
            ?? argv.firstIndex { ($0 as NSString).lastPathComponent.hasPrefix("codex") }.map { Array(argv[($0 + 1)...]) } ?? []
        return AgentResume.codexCommandLine(userArgs: args, sessionID: id)
    }

    private static func firstLine(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n", maxSplits: 1).first.map(String.init)
    }

    /// Re-reads font and colors from `Theme`; called when Settings change.
    func applyAppearance() {
        let font = Theme.terminalFont
        if view.font != font { view.font = font }
        view.nativeBackgroundColor = Theme.bg
        view.nativeForegroundColor = Theme.fg
        view.caretColor = Theme.accent
        view.selectedTextBackgroundColor = Theme.accentMuted
        view.installColors(Theme.palette.ansi.map {
            SwiftTerm.Color(red: UInt16($0.r) * 257, green: UInt16($0.g) * 257, blue: UInt16($0.b) * 257)
        })
        view.needsDisplay = true
    }

    private func configure() {
        view.enableDrops()
        view.onOutput = { [weak self] in
            guard let self else { return }
            self.signals.lastOutput = Date()
            self.runPendingCommand()
        }
        view.onInput = { [weak self] bytes in
            guard let self else { return }
            let now = Date()
            self.signals.lastInput = now
            // Esc or Ctrl-C to an agent ends its turn now, not when a spinner happens to go stale.
            if StatusRules.isInterrupt(bytes), self.agentName != nil || self.status == .working {
                self.signals.lastInterrupt = now
                self.tick(now: now)
            }
        }
        view.onBell = { [weak self] in
            self?.signals.lastBell = Date()
            self?.tick(now: Date())
        }
    }

    /// Runs the restored command shortly after the shell's first output (its prompt).
    private func runPendingCommand() {
        guard let command = pendingCommand else { return }
        pendingCommand = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.view.send(txt: command + "\r")
        }
    }

    /// Stable for the tab's life; agmux memory uses it to tell this tab's sessions apart.
    let tabID = UUID().uuidString

    private func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        AgentIntegration.shellEnvironment(&env, tabID: tabID)
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "agterm"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return env.map { "\($0.key)=\($0.value)" }
    }

    // MARK: What the tab shows

    var topic: String {
        if !parsedTitle.topic.isEmpty { return parsedTitle.topic }
        if let name = foregroundName, name != shellName { return name }
        return shellName
    }

    var folder: String { PathDisplay.folder(cwd, home: NSHomeDirectory()) }

    /// The foreground program is something other than the shell, e.g. an agent.
    /// Reads the kernel directly so a program started under a second ago still counts.
    var isRunningProgram: Bool {
        pollProcess()
        guard !signals.exited, let fg = foregroundPid else { return false }
        return fg != view.process.shellPid
    }

    // MARK: Polling

    func setFocused(_ focused: Bool, now: Date) {
        signals.focused = focused
        if focused { signals.lastSeen = now }
    }

    /// Recomputes status from signals. Cheap; runs twice a second.
    func tick(now: Date) {
        if signals.focused { signals.lastSeen = now }
        if StatusRules.isWorking(signals, now: now) { signals.lastWorking = now }
        let next = StatusRules.status(signals, now: now)
        if next != status {
            status = next
            onChange?()
            onStatusChange?(next)
        }
    }

    /// Reads the foreground process and its folder from the kernel.
    func pollProcess() {
        let shellPid = view.process.shellPid
        guard !signals.exited, shellPid > 0 else { return }
        let fg = ProcInfo.foregroundPid(ptyFd: view.process.childfd) ?? shellPid
        foregroundPid = fg
        let name = ProcInfo.name(pid: fg)
        updateAgent(fg == shellPid ? nil : AgentCatalog.agent(argv: ProcInfo.arguments(pid: fg)))
        updatePrompt()
        let claude = agentName == "claude" ? ProcInfo.claudeSession(pid: fg) : nil
        if let claude {
            claudeSessionID = claude.id
            TeamsClaims.shared.recordClaude(claude.id)
        }
        updateBusy(claude?.busy)
        let dir = ProcInfo.cwd(pid: fg) ?? ProcInfo.cwd(pid: shellPid) ?? cwd
        guard name != foregroundName || dir != cwd else { return }
        // Back at the prompt: forget the agent's title so a stale spinner or topic doesn't stick.
        if fg == shellPid, foregroundName != nil, foregroundName != shellName {
            rawTitle = ""
            parsedTitle = ParsedTitle(topic: "", activity: .unknown)
            signals.titleActivity = .unknown
        }
        foregroundName = name
        cwd = dir
        onChange?()
    }

    /// Claude Code's own busy/idle flag. It stays busy while subagents run, when the title
    /// spinner can pause, so a subagent finishing doesn't look like the session finishing.
    private func updateBusy(_ busy: Bool?) {
        guard busy != signals.agentBusy else { return }
        signals.agentBusy = busy
        signals.lastBusyChange = Date()
        tick(now: Date())
    }

    /// An agent waiting on a permission prompt is "needs you", even in the tab you're looking at.
    private func updatePrompt() {
        let visible = agentName != nil && PermissionPrompt.isVisible(screenText().components(separatedBy: "\n"))
        guard visible != signals.promptVisible else { return }
        signals.promptVisible = visible
        tick(now: Date())
    }

    private func updateAgent(_ agent: String?) {
        guard agent != agentName else { return }
        agentName = agent
        agentStartedAt = agent == nil ? nil : Date()
        claudeSessionID = nil
        agentBaseline = nil
        agentBaselineRequested = false
        agentDiff = nil
        onChange?()
    }

    func updateAgentDiff(_ diff: (added: Int, removed: Int)?) {
        guard diff?.added != agentDiff?.added || diff?.removed != agentDiff?.removed else { return }
        agentDiff = diff
        onChange?()
    }

    func updateGit(_ summary: GitSummary?) {
        guard summary != git else { return }
        git = summary
        onChange?()
    }

    /// The process group in the foreground, if it isn't the shell (an agent, say).
    var foregroundGroup: pid_t? {
        guard !signals.exited, let group = ProcInfo.foregroundPid(ptyFd: view.process.childfd),
              group != view.process.shellPid else { return nil }
        return group
    }

    /// Signals the job in the foreground (an agent), leaving the shell running.
    func signalForeground(_ signal: Int32) {
        let shell = view.process.shellPid
        guard let group = ProcInfo.foregroundPid(ptyFd: view.process.childfd), group != shell, group > 0 else { return }
        killpg(group, signal)
    }

    /// Ends the shell the way Terminal.app does: SIGHUP to the shell and to the foreground job
    /// (so an agent running in the tab exits too), SIGKILL if the shell is still there after
    /// 2 s, then reap it. SwiftTerm stops watching the child on terminate, so without the wait
    /// every closed tab would leave a zombie.
    func terminate() {
        guard !signals.exited else { return }
        let pid = view.process.shellPid
        let fg = ProcInfo.foregroundPid(ptyFd: view.process.childfd)
        if pid > 0 { kill(pid, SIGHUP) }
        if let fg, fg != pid { killpg(fg, SIGHUP) }
        view.terminate()
        guard pid > 0 else { return }
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            for _ in 0..<20 {
                if waitpid(pid, &status, WNOHANG) != 0 { return }
                usleep(100_000)
            }
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        signals.lastResize = Date()
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard title != rawTitle else { return }
        rawTitle = title
        signals.lastTitleChange = Date()
        parsedTitle = TitleParser.parse(title)
        signals.titleActivity = parsedTitle.activity
        tick(now: Date())
        onChange?()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL else { return }
        cwd = url.path
        onChange?()
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        signals.exited = true
        tick(now: Date())
        onChange?()
        if exitCode == 0 { onCleanExit?() }
    }
}
