import AgTermCore
import AgTermSessionKit
import AppKit
import SwiftTerm

/// One tab: a shell in a pty plus what we know about the program running in it.
final class TerminalSession: NSObject, AgentTerminalViewDelegate {
    let view: AgentTerminalView
    private(set) var rawTitle = ""
    private(set) var parsedTitle = ParsedTitle(topic: "", activity: .unknown)
    private(set) var cwd: String {
        didSet { if cwd != oldValue { FolderIndex.shared.visit(cwd) } }
    }
    private(set) var foregroundName: String?
    private var foregroundPid: pid_t?
    /// The latest look at the foreground; for a cloud tab, the cloud machine's last answer.
    private var foreground: ForegroundInfo?
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
    /// Claude's session name from its transcript, shown when its terminal title is generic.
    private var transcriptTitle: String?
    /// The name given with Rename Tab…; when set it replaces the automatic title.
    var name: String? {
        didSet { if name != oldValue { onChange?() } }
    }
    private(set) var signals = StatusSignals()
    private(set) var status: TabStatus = .idle
    let shellName: String
    private let shellPath: String
    /// The shell runs on the cloud machine.
    private(set) var isCloud = false

    /// Called when anything shown on the tab may have changed.
    var onChange: (() -> Void)?
    /// Called when the status changes (for notifications).
    var onStatusChange: ((TabStatus) -> Void)?
    /// Called when the screen changes right after a keystroke (the shell echoing what you type).
    var onTyped: (() -> Void)?
    /// Called when the shell exits on its own with status 0.
    var onCleanExit: (() -> Void)?
    /// Typed into the shell once its first prompt appears (resuming a restored agent).
    private var pendingCommand: String?

    /// `restoring` brings back a tab saved at the last quit: its history, then its agent.
    /// `command` is typed at the first prompt (starting an agent from the Shell menu).
    init(cwd: String, restoring saved: SavedTab? = nil, command: String? = nil) {
        // A tab coming back from the cloud keeps its id, as one reattached here does.
        tabID = saved?.tabID ?? UUID().uuidString
        self.cwd = cwd
        FolderIndex.shared.visit(cwd)
        shellPath = ProcInfo.loginShell()
        shellName = (shellPath as NSString).lastPathComponent
        view = Self.makeView()
        super.init()
        setUpView()
        restore(saved, command: command)
        view.attach(spawnShell())
    }

    /// Reconnects to a shell the helper kept. The helper's replay is the tab's history, so the saved
    /// one isn't shown and nothing is typed. If the shell is gone, opens a new one restoring `saved`.
    /// The tab keeps the id its shell was started with (from the save; a shell nobody saved gets a
    /// new one), since agents launched there report under it.
    init(attaching info: SessionInfo, saved: SavedTab?) {
        tabID = saved?.tabID ?? UUID().uuidString
        name = saved?.name
        // The shell's folder now; the helper's is where it started.
        cwd = ProcInfo.cwd(pid: info.pid) ?? info.cwd
        FolderIndex.shared.visit(cwd)
        shellPath = ProcInfo.loginShell()
        shellName = (shellPath as NSString).lastPathComponent
        view = Self.makeView()
        super.init()
        setUpView()
        if let link = try? SessionHelper.shared()?.attach(id: info.id) {
            view.attach(link)
        } else {
            restore(saved, command: nil)
            // The agent may still be running in the helper's shell; don't start a second one.
            pendingCommand = nil
            view.attach(spawnShell())
        }
    }

    /// A new shell on a cloud machine (cloud sessions), or the one it already runs as `attaching`
    /// (`saved` is that tab as last saved). The machine picks its own login shell and environment;
    /// this tab sends only its terminal settings and id. `command` is typed at the first prompt.
    /// Throws if the machine can't be reached.
    init(cloud: CloudHost, cwd: String, attaching id: String? = nil, saved: SavedTab? = nil, command: String? = nil) throws {
        let tabID = saved?.tabID ?? UUID().uuidString
        let view = Self.makeView()
        let terminal = view.getTerminal()
        let env = ["TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=agterm", "AGTERM_TAB_ID=\(tabID)",
                   "LANG=\(ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8")"]
        let shellPath = ProcInfo.loginShell()
        let request = SpawnRequest(executable: shellPath, argv: ["-" + (shellPath as NSString).lastPathComponent], env: env,
                                   cwd: cwd, cols: UInt16(terminal.cols), rows: UInt16(terminal.rows))
        let link = try id.map(cloud.attach) ?? cloud.spawn(request)
        self.tabID = tabID
        self.cwd = cwd
        self.shellPath = shellPath
        shellName = (shellPath as NSString).lastPathComponent
        self.view = view
        isCloud = true
        name = saved?.name
        super.init()
        setUpView()
        pendingCommand = command
        // A tab moved here keeps the history it had on the Mac.
        if id == nil, let saved, !saved.scrollback.isEmpty {
            view.feed(text: saved.scrollback + "\r\n\u{1b}[0;2m— moved to the cloud —\u{1b}[0m\r\n")
        }
        view.attach(link)
        link.onForeground = { [weak self] in self?.received($0) }
    }

    private static func makeView() -> AgentTerminalView {
        var options = TerminalOptions.default
        options.scrollback = Scrollback.maxLines
        return AgentTerminalView(frame: .zero, font: nil, options: options)
    }

    private func setUpView() {
        configure()
        applyAppearance()
        view.processDelegate = self
    }

    private func restore(_ saved: SavedTab?, command: String?) {
        if let saved {
            if !saved.scrollback.isEmpty {
                view.feed(text: saved.scrollback + "\r\n\u{1b}[0;2m— restored \(Self.restoredStamp()) —\u{1b}[0m\r\n")
            }
            pendingCommand = saved.resume
            name = saved.name
        }
        if let command { pendingCommand = command }
    }

    /// A login shell in the sessions helper, or in-process if the helper can't be used.
    private func spawnShell() -> PtyLink {
        let terminal = view.getTerminal()
        let request = SpawnRequest(executable: shellPath, argv: ["-" + shellName], env: environment(), cwd: cwd,
                                   cols: UInt16(terminal.cols), rows: UInt16(terminal.rows))
        if let helper = SessionHelper.shared() {
            do {
                return try helper.spawn(request)
            } catch {
                NSLog("agterm: the sessions helper couldn't start a shell (%@); running it in-process", String(describing: error))
            }
        }
        return LocalLink(request, size: view.windowSize())
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
        var rows = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.plainText() }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows.joined(separator: "\n")
    }

    /// The last `rows` lines of the tab as plain text, scrollback included, so ⌘K sees earlier
    /// commands and their output. A full-screen program (alternate screen) has only its screen.
    func recentText(rows: Int) -> String {
        let terminal = view.getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return screenText() }
        let top = terminal.buffer.totalLinesTrimmed
        let end = Self.endRow(terminal, top: top)
        var lines = (max(top, end - rows)..<end).compactMap { terminal.getScrollInvariantLine(row: $0)?.plainText() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// What to save so this tab can be reopened: folder, history and, for agents that can
    /// resume a conversation, the command that brings them back.
    func snapshot() -> SavedTab {
        pollProcess()
        return SavedTab(cwd: cwd, scrollback: Scrollback.capture(view.getTerminal()), resume: resumeCommand() ?? pendingCommand,
                        sessionID: signals.exited ? nil : view.link.sessionID, tabID: tabID, name: name,
                        inCloud: isCloud ? true : nil)
    }

    /// The command that brings back the agent in the foreground, with `prompt` as its first
    /// message where the agent takes one; nil if nothing resumable runs. Call `pollProcess` first.
    func resumeCommand(prompt: String? = nil) -> String? {
        guard let info = foreground, !info.isShell, !signals.exited else { return nil }
        let codexID = isCloud ? info.codexSessionID : codexRollout.flatMap(Self.firstLine).flatMap(AgentResume.codexSessionID)
        return AgentResume.commandLine(argv: info.argv, claudeSessionID: info.claudeSessionID, prompt: prompt)
            ?? codexResume(argv: info.argv, sessionID: codexID, prompt: prompt)
            ?? agentName.flatMap { AgentResume.continueCommandLine(agent: $0, argv: info.argv) }
    }

    /// `codex resume <id>` for the conversation this tab's Codex has open (it keeps its rollout
    /// file open), with the options it was started with.
    private func codexResume(argv: [String], sessionID: String?, prompt: String?) -> String? {
        guard agentName == "codex", let id = sessionID else { return nil }
        // The wrapper recorded your arguments for this very run; else read them off the process.
        let launch = AccountStore.launch(tabID: tabID, provider: .codex)
        let args = launch.flatMap { launch in agentStartedAt.map { abs(launch.startedAt.timeIntervalSince($0)) < 20 } == true ? launch.args : nil }
            ?? argv.firstIndex { ($0 as NSString).lastPathComponent.hasPrefix("codex") }.map { Array(argv[($0 + 1)...]) } ?? []
        return AgentResume.codexCommandLine(userArgs: args, sessionID: id, prompt: prompt)
    }

    /// The rollout file this tab's Codex holds open (a local tab only).
    var codexRollout: String? {
        guard !isCloud, agentName == "codex", let group = foregroundGroup else { return nil }
        return ProcInfo.openFiles(group: group, matching: { $0.contains("/sessions/") && $0.hasSuffix(".jsonl") && $0.contains("rollout-") }).first
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
        view.minimumContrast = Theme.minimumContrast
        view.installColors(Theme.palette.ansi.map {
            SwiftTerm.Color(red: UInt16($0.r) * 257, green: UInt16($0.g) * 257, blue: UInt16($0.b) * 257)
        })
        // Programs that asked (mode 2031), like Claude Code with its theme on "auto", follow light and dark.
        view.getTerminal().colorSchemeChanged()
        view.needsDisplay = true
    }

    private func configure() {
        view.enableDrops()
        view.onOutput = { [weak self] in
            guard let self else { return }
            self.signals.lastOutput = Date()
            self.runPendingCommand()
            if let input = self.signals.lastInput, Date().timeIntervalSince(input) < 1 { self.onTyped?() }
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

    /// Stable for the tab's life (and across a reattach); agmux memory uses it to tell this tab's
    /// sessions apart.
    let tabID: String

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
        if let name { return name }
        if needsTranscriptTitle, let transcriptTitle { return transcriptTitle }
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
        return fg != view.link.shellPid
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

    /// Reads the foreground process and its folder from the kernel. A cloud tab asks the cloud
    /// machine and uses its latest answer, a poll behind.
    func pollProcess() {
        guard !signals.exited else { return }
        if isCloud {
            (view.link as? HelperLink)?.requestForeground()
            if let foreground { apply(foreground) }
            return
        }
        let shellPid = view.link.shellPid
        guard shellPid > 0 else { return }
        let fg = ProcInfo.foregroundPid(ptyFd: view.link.ptyFd) ?? shellPid
        let isShell = fg == shellPid
        let argv = isShell ? [] : ProcInfo.arguments(pid: fg)
        let claude = !isShell && AgentCatalog.agent(argv: argv) == "claude" ? ProcInfo.claudeSession(pid: fg) : nil
        let info = ForegroundInfo(pid: fg, isShell: isShell, name: ProcInfo.name(pid: fg) ?? "", argv: argv,
                                  cwd: ProcInfo.cwd(pid: fg) ?? ProcInfo.cwd(pid: shellPid),
                                  claudeSessionID: claude?.id, claudeBusy: claude?.busy)
        foreground = info
        apply(info)
    }

    /// A cloud machine's answer to `inspect`.
    private func received(_ info: ForegroundInfo) {
        guard isCloud else { return }
        foreground = info
        apply(info)
    }

    private func apply(_ info: ForegroundInfo) {
        let shellPid = view.link.shellPid
        let fg = info.isShell ? shellPid : info.pid
        foregroundPid = fg
        let name = info.name.isEmpty ? nil : info.name
        updateAgent(info.isShell ? nil : AgentCatalog.agent(argv: info.argv))
        updateCommandRunning(!info.isShell && agentName == nil)
        updatePrompt()
        let claudeID = agentName == "claude" ? info.claudeSessionID : nil
        if let claudeID {
            claudeSessionID = claudeID
            TeamsClaims.shared.recordClaude(claudeID)
        }
        updateBusy(claudeID == nil ? nil : info.claudeBusy)
        let dir = info.cwd ?? cwd
        guard name != foregroundName || dir != cwd else { return }
        // Back at the prompt: forget the agent's title so a stale spinner or topic doesn't stick.
        if info.isShell, foregroundName != nil, foregroundName != shellName {
            rawTitle = ""
            parsedTitle = ParsedTitle(topic: "", activity: .unknown)
            signals.titleActivity = .unknown
            signals.titleReportsWaiting = false
        }
        foregroundName = name
        cwd = dir
        onChange?()
    }

    private func updateCommandRunning(_ running: Bool) {
        guard running != signals.commandRunning else { return }
        signals.commandRunning = running
        tick(now: Date())
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
        transcriptTitle = nil
        agentBaseline = nil
        agentBaselineRequested = false
        agentDiff = nil
        onChange?()
    }

    var needsTranscriptTitle: Bool {
        agentName == "claude" && ClaudeSessionTitle.isGeneric(parsedTitle.topic)
    }

    func updateTranscriptTitle(_ title: String?) {
        guard title != transcriptTitle else { return }
        transcriptTitle = title
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

    /// The program in the foreground, if it isn't the shell: its process group here, or on the cloud machine.
    var foregroundJob: pid_t? {
        guard !signals.exited, let foreground, !foreground.isShell else { return nil }
        return foreground.pid
    }

    /// The process group in the foreground, if it isn't the shell (an agent, say).
    var foregroundGroup: pid_t? {
        guard !signals.exited, let group = ProcInfo.foregroundPid(ptyFd: view.link.ptyFd),
              group != view.link.shellPid else { return nil }
        return group
    }

    /// Signals the job in the foreground (an agent), leaving the shell running.
    func signalForeground(_ signal: Int32) {
        if isCloud { return (view.link as? HelperLink)?.signalForeground(signal) ?? () }
        let shell = view.link.shellPid
        guard let group = ProcInfo.foregroundPid(ptyFd: view.link.ptyFd), group != shell, group > 0 else { return }
        killpg(group, signal)
    }

    /// Ends the shell the way Terminal.app does: SIGHUP to the shell and to the foreground job
    /// (so an agent running in the tab exits too), SIGKILL if the shell is still there after 2 s.
    func terminate() {
        guard !signals.exited else { return }
        view.link.end()
    }

    /// The shell lives in the helper, so quitting agterm leaves it running.
    var isKeptByHelper: Bool { view.link.sessionID != nil }

    /// Leaves the shell running in the helper for the next launch (a local shell ends).
    func detach() {
        view.link.detach()
    }

    /// Tells the shell the screen's size, e.g. once a reattached tab is laid out, so a full-screen
    /// program redraws to fit.
    func pushSize() {
        view.link.resize(view.windowSize())
    }

    // MARK: AgentTerminalViewDelegate

    func sizeChanged(source: AgentTerminalView, newCols: Int, newRows: Int) {
        signals.lastResize = Date()
    }

    func setTerminalTitle(source: AgentTerminalView, title: String) {
        guard TitleParser.isNews(title, previous: rawTitle) else { return }
        rawTitle = title
        signals.lastTitleChange = Date()
        parsedTitle = TitleParser.parse(title)
        signals.titleActivity = parsedTitle.activity
        signals.titleReportsWaiting = TitleParser.reportsWaiting(title)
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
