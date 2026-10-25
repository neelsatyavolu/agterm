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
    private(set) var signals = StatusSignals()
    private(set) var status: TabStatus = .idle
    private let shellName: String

    /// Called when anything shown on the tab may have changed.
    var onChange: (() -> Void)?
    /// Called when the shell exits on its own with status 0.
    var onCleanExit: (() -> Void)?

    init(cwd: String) {
        self.cwd = cwd
        let shell = ProcInfo.loginShell()
        shellName = (shell as NSString).lastPathComponent
        view = AgentTerminalView(frame: .zero)
        super.init()
        configure()
        applyAppearance()
        view.processDelegate = self
        view.startProcess(executable: shell, args: [], environment: Self.environment(),
                          execName: "-" + shellName, currentDirectory: cwd)
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
        view.onOutput = { [weak self] in self?.signals.lastOutput = Date() }
        view.onInput = { [weak self] in self?.signals.lastInput = Date() }
        view.onBell = { [weak self] in
            self?.signals.lastBell = Date()
            self?.tick(now: Date())
        }
    }

    private static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
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
        }
    }

    /// Reads the foreground process and its folder from the kernel.
    func pollProcess() {
        let shellPid = view.process.shellPid
        guard !signals.exited, shellPid > 0 else { return }
        let fg = ProcInfo.foregroundPid(ptyFd: view.process.childfd) ?? shellPid
        foregroundPid = fg
        let name = ProcInfo.name(pid: fg)
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

    func updateGit(_ summary: GitSummary?) {
        guard summary != git else { return }
        git = summary
        onChange?()
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
