import AgTermCore
import AppKit
import Combine

/// The single window: tab bar in the title bar, the selected terminal below.
final class MainWindowController: NSWindowController, NSWindowDelegate, TabBarDelegate {
    private let tabBar = TabBarView(frame: .zero)
    private let container = NSView()
    /// Paints the margins around the terminal; the terminal paints its own area, so a
    /// see-through background isn't layered twice.
    private let backdrop = MarginView()
    /// Fallback blur, used only if the window server's blur radius call is unavailable.
    private let blur = NSVisualEffectView()
    private(set) var sessions: [TerminalSession] = []
    private var selected = 0
    private var appearanceSubscription: AnyCancellable?
    private let git = GitPoller()
    private let transcripts = TranscriptDiff()
    private let commandBar = CommandBar()
    private let cdSuggestions = CdSuggestions()
    /// The tab the open command bar answers for; its command only ever goes there.
    private weak var commandBarTarget: TerminalSession?
    private var timers: [Timer] = []
    /// Set once the tabs are saved for this quit, so a second save can't overwrite them.
    private var savedForQuit = false

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        configure(window)
        applyAppearance()
        restoreTabs()
        startTimers()
        configureCommandBar()
        NotificationCenter.default.addObserver(forName: .agtermOpenTab, object: nil, queue: .main) { [weak self] note in
            guard let self, let command = note.userInfo?["command"] as? String else { return }
            self.addTab(cwd: NSHomeDirectory(), restoring: nil, command: command)
            self.window?.makeKeyAndOrderFront(nil)
        }
        RemoteClient.shared.tabs = { [weak self] in self?.sessions ?? [] }
        RemoteClient.shared.openTab = { [weak self] folder, command in
            guard let self else { return nil }
            self.addTab(cwd: folder, restoring: nil, command: command)
            return self.sessions.last?.tabID
        }
        Notifier.shared.onOpen = { [weak self] tabID in
            guard let self, let index = self.sessions.firstIndex(where: { $0.tabID == tabID }) else { return }
            self.window?.makeKeyAndOrderFront(nil)
            self.select(index)
        }
        // `$appearance` fires before the new value is stored, so pass it along rather than re-reading it.
        appearanceSubscription = Preferences.shared.$appearance.dropFirst().sink { [weak self] settings in
            self?.applyAppearance(settings)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// macOS 26 made window corners larger; match whichever system is running.
    private static var windowCornerRadius: CGFloat {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) ? 16 : 10
    }

    private func configure(_ window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar makes the title bar as tall as the tab bar and centers the traffic lights in it.
        window.toolbar = NSToolbar(identifier: "agterm")
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = false
        // The tab bar moves the window itself; left to the system, dragging a tab moved the window.
        window.isMovable = false
        window.minSize = NSSize(width: 480, height: 240)
        if !window.setFrameUsingName("agterm.main") { window.center() }
        window.setFrameAutosaveName("agterm.main")
        window.delegate = self

        let content = NSView()
        // A see-through window draws no frame of its own, so round the content to match
        // macOS's window corners; an opaque window keeps the system rounding.
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.windowCornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        window.contentView = content
        tabBar.delegate = self
        blur.blendingMode = .behindWindow
        blur.material = .underWindowBackground
        blur.state = .active
        backdrop.hole = container
        for view in [blur, backdrop, container, tabBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        for view in [blur, backdrop] as [NSView] {
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: content.topAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -2),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
    }

    private func startTimers() {
        let fast = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tickStatus() }
        let medium = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.sessions.forEach { $0.pollProcess() }
            AccountSwitcher.shared.poll(self.sessions)
            TeamAccounts.shared.poll(self.sessions)
        }
        let slow = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in self?.pollGit() }
        // Also save now and then, so a crash or forced restart loses at most a minute.
        let autosave = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.saveWorkspace() }
        for timer in [fast, medium, slow, autosave] {
            timer.tolerance = timer.timeInterval * 0.2
            RunLoop.main.add(timer, forMode: .common)
        }
        timers = [fast, medium, slow, autosave]
    }

    private func tickStatus() {
        let now = Date()
        sessions.forEach { $0.tick(now: now) }
        tabBar.blinkOn.toggle()
    }

    /// One git call per distinct folder, fanned out to every tab in it.
    private func pollGit() {
        for path in Set(sessions.map(\.cwd)) {
            git.refresh(path: path) { [weak self] summary in
                self?.sessions.filter { $0.cwd == path }.forEach { $0.updateGit(summary) }
            }
        }
        // Agent tabs: what changed since that agent started. Claude and Codex are counted from
        // their own transcripts (works outside git repos); other agents from a git snapshot.
        for session in sessions where session.agentName != nil {
            if session.agentName == "claude", let id = session.claudeSessionID {
                transcripts.claude(sessionID: id) { [weak session] diff in session?.updateAgentDiff(diff ?? (0, 0)) }
                if session.needsTranscriptTitle {
                    transcripts.claudeTitle(sessionID: id) { [weak session] title in session?.updateTranscriptTitle(title) }
                }
                continue
            }
            if session.agentName == "codex", let start = session.agentStartedAt {
                transcripts.codex(cwd: session.cwd, since: start) { [weak session] diff in session?.updateAgentDiff(diff ?? (0, 0)) }
                continue
            }
            if let baseline = session.agentBaseline {
                git.agentDiff(baseline) { [weak session] diff in session?.updateAgentDiff(diff) }
            } else if !session.agentBaselineRequested {
                session.agentBaselineRequested = true
                let agent = session.agentName
                git.baseline(path: session.cwd) { [weak session] baseline in
                    guard let session, session.agentName == agent else { return }
                    session.agentBaseline = baseline
                    if baseline != nil { session.updateAgentDiff((0, 0)) }
                }
            }
        }
    }

    // MARK: Tabs

    /// Brings back the last session's tabs, in order: shells the helper kept are shown again live,
    /// the rest reopen from their saved history. Shells the helper has that weren't saved (agterm
    /// crashed before saving them) are added at the end. Shells another agterm shows are left to it.
    private func restoreTabs() {
        let saved = WorkspaceStore.load()
        // Nil when the helper can't be asked: tabs that were in it come back without their agent.
        let live = SessionHelper.shared()?.list()
        // Asking wakes a stopped cloud machine, so only when there are cloud tabs to bring back.
        let cloud = saved?.tabs.contains { $0.inCloud == true } == true ? CloudHost.configured : nil
        let plan = LaunchTab.plan(saved: saved?.tabs ?? [], live: live, cloud: cloud?.list())
        guard !plan.isEmpty else { return newTab() }
        for tab in plan {
            switch tab {
            case .restore(let saved):
                addTab(cwd: saved.cwd, restoring: saved)
            case .reattach(let info, let saved):
                install(TerminalSession(attaching: info, saved: saved))
                // The tab now has its real size; a full-screen program redraws to fit it.
                window?.layoutIfNeeded()
                sessions.last?.pushSize()
            case .reattachCloud(let info, let saved):
                if let cloud, let session = try? TerminalSession(cloud: cloud, cwd: saved?.cwd ?? info.cwd, attaching: info.id, saved: saved) {
                    install(session)
                    window?.layoutIfNeeded()
                    session.pushSize()
                } else if var saved {
                    saved.resume = nil
                    addTab(cwd: saved.cwd, restoring: saved)
                }
            }
        }
        select(saved?.selected ?? 0)
    }

    /// New tabs open in the selected tab's folder, as in Terminal.app.
    private var currentFolder: String { sessions.indices.contains(selected) ? sessions[selected].cwd : NSHomeDirectory() }

    @objc func newTab() { addTab(cwd: currentFolder, restoring: nil) }

    /// A tab whose shell runs on the cloud machine (`CloudHost.configured`), in the same folder
    /// if the machine has it.
    @objc func newCloudTab() {
        guard let cloud = CloudHost.configured else { return SettingsWindowController.shared.show(pane: "Cloud") }
        openCloudTab(cloud)
    }

    /// Shell → Move All Tabs to Cloud…: lists what will happen to each tab, then moves them.
    @objc func moveAllToCloud() {
        guard let cloud = CloudHost.configured else { return SettingsWindowController.shared.show(pane: "Cloud") }
        let items = CloudMove.preflight(sessions)
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Move \(items.count) tab\(items.count == 1 ? "" : "s") to the cloud?"
        alert.informativeText = items.map(\.summary).joined(separator: "\n")
            + "\n\nEach tab's folder and conversation are copied first. Agents finish their turn, or stop after 20 seconds and continue in the cloud."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        moveToCloud(items, cloud: cloud) { _ in }
    }

    /// Moves `items` and reports how it went (a notification, and `done`).
    func moveToCloud(_ items: [CloudMove.Item], cloud: CloudHost, done: @escaping (CloudMove.Outcome) -> Void) {
        window?.subtitle = "Moving to the cloud…"
        let move = CloudMove(cloud: cloud, isOpen: { [weak self] in self?.sessions.contains($0) == true },
                             replace: { [weak self] old, new in self?.replaceTab(old, with: new) })
        move.run(items) { [weak self] outcome in
            self?.window?.subtitle = ""
            switch outcome {
            case .moved(let count):
                Notifier.shared.post(title: "Moved \(count) tab\(count == 1 ? "" : "s") to the cloud",
                                     body: "They keep running when this Mac is off.", tabID: "cloud")
            case .failed(let reason):
                Notifier.shared.post(title: "Couldn't move tabs to the cloud", body: reason, tabID: "cloud")
            }
            done(outcome)
            _ = move
        }
    }

    /// Puts `new` where `old` is and ends `old`'s shell.
    private func replaceTab(_ old: TerminalSession, with new: TerminalSession) {
        guard let index = sessions.firstIndex(of: old) else { return }
        let wasSelected = index == selected
        let current = selected
        install(new)
        sessions.swapAt(index, sessions.count - 1)
        removeTab(at: sessions.count - 1)
        select(wasSelected ? index : current)
    }

    /// `attaching` shows a shell the machine already runs.
    func openCloudTab(_ cloud: CloudHost, attaching id: String? = nil) {
        do {
            install(try TerminalSession(cloud: cloud, cwd: currentFolder, attaching: id))
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't open a cloud tab"
            alert.informativeText = "The cloud machine at \(cloud) didn't answer: \(error)"
            alert.runModal()
        }
    }

    #if DEBUG
    func restoreTabForTest(_ saved: SavedTab) { addTab(cwd: saved.cwd, restoring: saved) }
    var selectedTabCardForTest: NSView { tabBar.selectedCardForTest }
    var selectedTabIDForTest: String { sessions[selected].tabID }
    #endif

    /// ⌥⌘T: a new tab running the agent chosen in Settings → Agents.
    @objc func newDefaultAgentTab() { newAgentTab(AgentIntegration.launchAgent) }

    @objc func newAgentTabFromMenu(_ sender: NSMenuItem) {
        guard let agent = (sender.representedObject as? String).flatMap(AgentKind.named) else { return }
        newAgentTab(agent)
    }

    /// Types the agent at the new shell's first prompt, so the shell is still there when it exits
    /// and the tab saves and restores like any other.
    func newAgentTab(_ agent: AgentKind) { addTab(cwd: currentFolder, restoring: nil, command: agent.command) }

    /// Opens a tab at home that plays the What's New lines (built for its width) above the prompt.
    func showWhatsNew(_ lines: (_ columns: Int) -> [String]) {
        addTab(cwd: NSHomeDirectory(), restoring: nil)
        guard let session = sessions.last else { return }
        window?.layoutIfNeeded()
        WhatsNewReveal.play(lines(session.view.getTerminal().cols), in: session.view)
    }

    private func addTab(cwd: String, restoring saved: SavedTab?, command: String? = nil) {
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        install(TerminalSession(cwd: dir, restoring: saved, command: command))
    }

    private func install(_ session: TerminalSession) {
        session.onChange = { [weak self] in self?.render() }
        session.onStatusChange = { [weak session] status in
            // No banner for the tab you're already looking at.
            guard let session, !(session.signals.focused && NSApp.isActive) else { return }
            Notifier.shared.post(status: status, tabID: session.tabID, topic: session.topic, folder: session.folder)
        }
        session.onTyped = { [weak self, weak session] in
            guard let self, let session, self.sessions.indices.contains(self.selected),
                  self.sessions[self.selected] === session else { return }
            self.cdSuggestions.typed(in: session)
        }
        session.onCleanExit = { [weak self, weak session] in
            guard let self, let session, let index = self.sessions.firstIndex(of: session) else { return }
            self.removeTab(at: index)
        }
        let view = session.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        // GPU rendering is opt-in until it has been checked on screen: AGTERM_METAL=1.
        if ProcessInfo.processInfo.environment["AGTERM_METAL"] == "1" { try? view.setUseMetal(true) }
        sessions.append(session)
        select(sessions.count - 1)
        pollGit()
    }

    @objc func closeTab() { confirmClose(at: selected) }

    // MARK: Tab menu

    /// What right-clicking a tab offers. Each item carries its tab, so it acts on that tab
    /// even if the tabs move while the menu is open.
    private func menu(for session: TerminalSession) -> NSMenu {
        let menu = NSMenu()
        let entries: [(String, Selector)?] = [
            ("Rename Tab…", #selector(renameTabFromMenu(_:))),
            nil,
            ("New Tab in This Folder", #selector(newTabInFolderFromMenu(_:))),
            ("Copy Folder Path", #selector(copyFolderPathFromMenu(_:))),
            ("Show in Finder", #selector(showInFinderFromMenu(_:))),
            nil,
            ("Close Tab", #selector(closeTabFromMenu(_:))),
        ]
        for entry in entries {
            guard let (title, action) = entry else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = session
            menu.addItem(item)
        }
        return menu
    }

    @objc func renameTab() {
        if sessions.indices.contains(selected) { rename(sessions[selected]) }
    }

    @objc private func renameTabFromMenu(_ sender: NSMenuItem) {
        (sender.representedObject as? TerminalSession).map(rename)
    }

    @objc private func newTabInFolderFromMenu(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? TerminalSession else { return }
        addTab(cwd: session.cwd, restoring: nil)
    }

    @objc private func copyFolderPathFromMenu(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? TerminalSession else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.cwd, forType: .string)
    }

    @objc private func showInFinderFromMenu(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? TerminalSession else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)])
    }

    @objc private func closeTabFromMenu(_ sender: NSMenuItem) {
        guard let session = sender.representedObject as? TerminalSession,
              let index = sessions.firstIndex(of: session) else { return }
        confirmClose(at: index)
    }

    /// Asks for a name in a sheet; an empty name goes back to the program's own title.
    private func rename(_ session: TerminalSession) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave it empty to show the program's title again."
        let field = NSTextField(string: session.name ?? session.topic)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self, weak session] response in
            guard let self, let session else { return }
            if response == .alertFirstButtonReturn { session.name = TabName.cleaned(field.stringValue) }
            if let index = self.sessions.firstIndex(of: session), index == self.selected {
                window.makeFirstResponder(session.view)
            }
        }
    }

    // MARK: Saving tabs

    /// Writes the open tabs (folder, history, resumable agent, helper session) for the next launch.
    /// `endingSessions` leaves the session out, so a quick relaunch can't attach to a dying shell.
    func saveWorkspace(endingSessions: Bool = false) {
        guard !savedForQuit else { return }
        let tabs = sessions.map { session in
            let tab = session.snapshot()
            return endingSessions ? SavedTab(cwd: tab.cwd, scrollback: tab.scrollback, resume: tab.resume, tabID: tab.tabID, name: tab.name) : tab
        }
        WorkspaceStore.save(SavedWorkspace(selected: selected, tabs: tabs, savedAt: Date()))
    }

    /// Saves the tabs one last time (later saves are ignored), then lets go of their shells:
    /// detached, so the helper keeps them for the next launch, or ended. Runs once.
    func quit(endingSessions: Bool) {
        guard !savedForQuit else { return }
        timers.forEach { $0.invalidate() }
        saveWorkspace(endingSessions: endingSessions)
        savedForQuit = true
        // Empty the list first so the quit check doesn't ask about these tabs again.
        let closing = sessions
        sessions = []
        closing.forEach { endingSessions ? $0.terminate() : $0.detach() }
    }

    // MARK: Reordering

    /// Moves a tab, keeping the same tab selected.
    func moveTab(from: Int, to: Int) {
        guard sessions.indices.contains(from), sessions.indices.contains(to), from != to else { return }
        let next = TabOrder.selection(afterMoving: from, to: to, selected: selected)
        sessions = TabOrder.moved(sessions, from: from, to: to)
        select(next)
    }

    @objc func moveTabLeft() { moveTab(from: selected, to: selected - 1) }
    @objc func moveTabRight() { moveTab(from: selected, to: selected + 1) }

    @objc func nextTab() { select((selected + 1) % max(sessions.count, 1)) }

    @objc func previousTab() { select((selected - 1 + sessions.count) % max(sessions.count, 1)) }

    @objc func selectTabFromMenu(_ sender: NSMenuItem) {
        // ⌘9 always means the last tab, as in Safari and Terminal.
        let index = sender.tag == 9 ? sessions.count - 1 : sender.tag - 1
        if sessions.indices.contains(index) { select(index) }
    }

    func select(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        selected = index
        cdSuggestions.hide()
        if commandBar.superview != nil, sessions[index] !== commandBarTarget { hideCommandBar(refocus: false) }
        let now = Date()
        for (i, session) in sessions.enumerated() {
            session.view.isHidden = i != index
            session.setFocused(i == index && (window?.isKeyWindow ?? true), now: now)
        }
        sessions[index].view.needsDisplay = true
        window?.makeFirstResponder(sessions[index].view)
        render()
    }

    private func confirmClose(at index: Int) {
        guard sessions.indices.contains(index), window?.attachedSheet == nil else { return }
        let session = sessions[index]
        guard session.isRunningProgram else { return removeTab(at: index) }
        let alert = NSAlert()
        alert.messageText = "Close this tab?"
        alert.informativeText = "\(session.foregroundName ?? "A program") is still running in \(session.folder)."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let current = self.sessions.firstIndex(of: session) else { return }
            self.removeTab(at: current)
        }
    }

    private func removeTab(at index: Int) {
        let session = sessions.remove(at: index)
        cdSuggestions.hide()
        if session === commandBarTarget { hideCommandBar(refocus: false) }
        session.onChange = nil
        session.terminate()
        session.view.removeFromSuperview()
        guard !sessions.isEmpty else {
            window?.close()
            return
        }
        select(min(index, sessions.count - 1))
    }

    var runningPrograms: [String] {
        sessions.filter(\.isRunningProgram).map { "\($0.foregroundName ?? "?") in \($0.folder)" }
    }

    /// Tabs whose shells a quit leaves running in the helper.
    var keptTabIDs: Set<String> {
        Set(sessions.filter(\.isKeptByHelper).map(\.tabID))
    }

    /// For each tab a quit keeps running whose agent is on a team login (`agents`: tab ID to
    /// agent name), the line saying a plain quit stops that agent.
    func teamAgentsStopping(_ agents: [String: String]) -> [String] {
        sessions.filter(\.isKeptByHelper).compactMap { session in
            agents[session.tabID].map { "\($0) on a team login in \(session.folder) will stop." }
        }
    }

    /// The running programs quitting would stop: all of them when ending sessions, else only
    /// those in in-process shells, which die with the app.
    func runningPrograms(endingSessions: Bool) -> [String] {
        sessions.filter { $0.isRunningProgram && (endingSessions || !$0.isKeptByHelper) }
            .map { "\($0.foregroundName ?? "?") in \($0.folder)" }
    }

    private func render() {
        tabBar.update(sessions.enumerated().map { i, s in
            TabModel(topic: s.topic, folder: s.isCloud ? "cloud · " + s.folder : s.folder, git: s.git, agentDiff: s.agentDiff.map { DiffCount(added: $0.added, removed: $0.removed) },
                     status: s.status, selected: i == selected)
        })
        if sessions.indices.contains(selected) { window?.title = sessions[selected].topic }
    }

    // MARK: Appearance

    /// Pushes the current `Theme` to the window, tab bar and every terminal.
    /// Full screen forces a solid background (see `WindowBlur.effectiveOpacity`).
    private func applyAppearance(_ settings: AppearanceSettings = Preferences.shared.appearance) {
        guard let window else { return }
        Theme.apply(settings, fullScreen: window.styleMask.contains(.fullScreen))
        let seeThrough = Theme.opacity < 1
        window.appearance = Theme.appearance
        window.isOpaque = !seeThrough
        window.backgroundColor = seeThrough ? .clear : Theme.bg
        let radius = WindowBlur.radius(opacity: Double(Theme.opacity), blur: settings.blur)
        let blurred = BackgroundBlur.set(window, radius: radius)
        blur.isHidden = blurred || radius == 0
        backdrop.color = Theme.bg
        tabBar.refreshAppearance()
        commandBar.refreshAppearance()
        sessions.forEach { $0.applyAppearance() }
        window.invalidateShadow()
    }

    // MARK: Command bar

    private func configureCommandBar() {
        commandBar.translatesAutoresizingMaskIntoConstraints = false
        commandBar.context = { [weak self] in
            guard let session = self?.commandBarTarget else { return (NSHomeDirectory(), "zsh", "") }
            session.pollProcess()
            return (session.cwd, session.shellName, session.recentText(rows: QuickCommand.outputLines * 2))
        }
        commandBar.onInsert = { [weak self] command, run in
            guard let view = self?.commandBarTarget?.view else { return }
            view.send(txt: DropText.wrap(command, bracketed: view.getTerminal().bracketedPasteMode))
            if run { view.send(txt: "\r") }
        }
        commandBar.onClose = { [weak self] in self?.hideCommandBar() }
    }

    /// ⌘K opens the bar over the selected tab; pressing it again closes it.
    @objc func toggleCommandBar() {
        guard commandBar.superview == nil else { return hideCommandBar() }
        guard sessions.indices.contains(selected) else { return }
        let session = sessions[selected]
        commandBarTarget = session
        // Added last so it sits above the terminals, including tabs opened since.
        container.addSubview(commandBar)
        // Below the window's own size priority, so a narrow window narrows the bar, never the reverse.
        let fill = commandBar.widthAnchor.constraint(equalToConstant: CommandBar.width)
        fill.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 10)
        NSLayoutConstraint.activate([
            fill,
            commandBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            commandBar.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            commandBarVerticalPlacement(for: session),
        ])
        commandBar.begin()
    }

    #if DEBUG
    var commandBarForTest: CommandBar { commandBar }
    var cdSuggestionsForTest: CdSuggestions { cdSuggestions }
    func renderForTest() { render() }
    func tabMenuForTest(_ index: Int) -> NSMenu { menu(for: sessions[index]) }
    #endif

    /// Just under the line you're typing on, or just above it when the bottom of the window is too close.
    private func commandBarVerticalPlacement(for session: TerminalSession) -> NSLayoutConstraint {
        let caret = session.view.convert(session.view.caretFrame, to: container)
        let lineTop = container.isFlipped ? caret.minY : container.bounds.height - caret.maxY
        let lineBottom = container.isFlipped ? caret.maxY : container.bounds.height - caret.minY
        // Room for a wrapped command under the request.
        let roomNeeded: CGFloat = 170
        if lineBottom + roomNeeded <= container.bounds.height {
            return commandBar.topAnchor.constraint(equalTo: container.topAnchor, constant: lineBottom + 6)
        }
        return commandBar.bottomAnchor.constraint(equalTo: container.topAnchor, constant: max(lineTop - 6, 0))
    }

    private func hideCommandBar(refocus: Bool = true) {
        commandBar.cancelRun()
        commandBar.removeFromSuperview()
        commandBarTarget = nil
        if refocus, sessions.indices.contains(selected) { window?.makeFirstResponder(sessions[selected].view) }
    }

    // ⌘= / ⌘- / ⌘0 change the saved font size, so Settings stays in sync.
    @objc func biggerFont() { Preferences.shared.update { $0.fontSize += 1 } }
    @objc func smallerFont() { Preferences.shared.update { $0.fontSize -= 1 } }
    @objc func resetFont() { Preferences.shared.update { $0.fontSize = AppearanceSettings().fontSize } }

    // MARK: TabBarDelegate

    func tabBar(_ bar: TabBarView, didSelect index: Int) { select(index) }
    func tabBar(_ bar: TabBarView, didClose index: Int) { confirmClose(at: index) }
    func tabBarDidRequestNewTab(_ bar: TabBarView) { newTab() }
    func tabBarAgentMenu(_ bar: TabBarView) -> NSMenu {
        let menu = NSMenu()
        let agents = AgentIntegration.installedAgents() ?? [.claude, .codex, .grok]
        AppDelegate.agentItems(agents, target: self).forEach(menu.addItem)
        return menu
    }
    func tabBar(_ bar: TabBarView, didMove from: Int, to: Int) { moveTab(from: from, to: to) }
    func tabBar(_ bar: TabBarView, menuFor index: Int) -> NSMenu { menu(for: sessions[index]) }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        if sessions.indices.contains(selected) { sessions[selected].setFocused(true, now: Date()) }
    }

    func windowDidResignKey(_ notification: Notification) {
        if sessions.indices.contains(selected) { sessions[selected].setFocused(false, now: Date()) }
    }

    /// Full screen moves the toolbar into a bar of its own that covers the tab bar; it's only
    /// there to size the title bar, so hide it until the window leaves full screen.
    func windowWillEnterFullScreen(_ notification: Notification) { window?.toolbar?.isVisible = false }
    func windowDidEnterFullScreen(_ notification: Notification) { applyAppearance() }
    func windowWillExitFullScreen(_ notification: Notification) { window?.toolbar?.isVisible = true }
    func windowDidExitFullScreen(_ notification: Notification) { applyAppearance() }

    /// The window server window exists only once shown, so apply the blur radius again then.
    func windowDidChangeOcclusionState(_ notification: Notification) { applyAppearance() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.attachedSheet == nil else { return false }
        let running = runningPrograms
        guard !running.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Close the window?"
        alert.informativeText = "Still running:\n" + running.joined(separator: "\n")
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { response in
            if response == .alertFirstButtonReturn { sender.close() }
        }
        return false
    }

    /// Closing the window ends its tabs' shells, as closing a tab does, then quits.
    func windowWillClose(_ notification: Notification) {
        quit(endingSessions: true)
        NSApp.terminate(nil)
    }
}

/// Fills its bounds with a color, except where `hole` sits.
final class MarginView: NSView {
    var color = NSColor.clear { didSet { needsDisplay = true } }
    weak var hole: NSView?

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        if let hole, hole.superview != nil {
            path.append(NSBezierPath(rect: convert(hole.bounds, from: hole)))
            path.windingRule = .evenOdd
        }
        color.setFill()
        path.fill()
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}
