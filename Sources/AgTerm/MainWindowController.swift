import AgTermCore
import AppKit
import Combine

/// The single window: tabs in the title bar or down the left side, the selected tab's panes beside them.
final class MainWindowController: NSWindowController, NSWindowDelegate, TabBarDelegate {
    let tabBar = TabBarView(frame: .zero)
    let sidebar = TabSidebarView(frame: .zero)
    let titleStrip = TitleStripView()
    /// Constraints for tabs along the top, and for tabs on the left (`applyTabPlacement`).
    var topLayout: [NSLayoutConstraint] = []
    var sideLayout: [NSLayoutConstraint] = []
    let container = PaneHostView()
    /// What a new, empty pane shows until you choose a tab for it (Split Right / Split Down).
    let panePicker = PanePickerView()
    /// Paints the margins around the terminal; the terminal paints its own area, so a
    /// see-through background isn't layered twice.
    private let backdrop = MarginView()
    /// Fallback blur, used only if the window server's blur radius call is unavailable.
    private let blur = NSVisualEffectView()
    /// Every pane's shell, tab by tab in order (each tab's panes in layout order).
    private(set) var sessions: [TerminalSession] = []
    /// The tabs, each one or more of `sessions`.
    private(set) var groups: [PaneGroup] = []
    /// The selected tab, an index into `groups`.
    private(set) var selected = 0
    var focusObservation: NSKeyValueObservation?
    private var appearanceSubscription: AnyCancellable?
    private let git = GitPoller()
    private let transcripts = TranscriptDiff()
    /// When each folder was last asked of git. Idle folders are asked only every `idleGitInterval`.
    private var gitPolledAt: [String: Date] = [:]
    private static let idleGitInterval: TimeInterval = 30
    private let commandBar = CommandBar()
    private let cdSuggestions = CdSuggestions()
    /// The Session Timeline panel (MainWindowController+Timeline).
    let sessionTimeline = SessionTimelineController()
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
        observeFocus()
        applyAppearance()
        restoreTabs()
        startTimers()
        startCloudReturn()
        configureCommandBar()
        NotificationCenter.default.addObserver(forName: .agtermOpenTab, object: nil, queue: .main) { [weak self] note in
            guard let self, let command = note.userInfo?["command"] as? String else { return }
            self.addTab(cwd: NSHomeDirectory(), restoring: nil, command: command)
            self.window?.makeKeyAndOrderFront(nil)
        }
        RemoteClient.shared.tabs = { [weak self] in self?.sessions ?? [] }
        TeamSessions.shared.tabs = { [weak self] in self?.sessions ?? [] }
        RemoteClient.shared.onEnabledChange = { [weak self] in self?.syncPhoneToCloud() }
        RemoteClient.shared.openTab = { [weak self] folder, command in
            self?.addTab(cwd: folder, restoring: nil, command: command).tabID
        }
        Notifier.shared.onOpen = { [weak self] tabID in
            guard let self, self.session(tabID) != nil else { return }
            self.window?.makeKeyAndOrderFront(nil)
            self.focus(tabID)
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
        sidebar.delegate = self
        setUpSessionTimeline()
        container.onResize = { [weak self] path, ratio in self?.resizePanes(path, ratio) }
        panePicker.isHidden = true
        panePicker.onChoose = { [weak self] choice in self?.fillPicker(with: choice.tabID) }
        panePicker.onCancel = { [weak self] in self?.cancelPicker() }
        container.addSubview(panePicker)
        blur.blendingMode = .behindWindow
        blur.material = .underWindowBackground
        blur.state = .active
        backdrop.hole = container
        for view in [blur, backdrop, container, tabBar, sidebar, titleStrip] as [NSView] {
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
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: TabSidebarView.width),
            titleStrip.topAnchor.constraint(equalTo: content.topAnchor),
            titleStrip.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            titleStrip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            titleStrip.heightAnchor.constraint(equalToConstant: TitleStripView.height),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -2),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        topLayout = [
            container.topAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: 8),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
        ]
        sideLayout = [
            container.topAnchor.constraint(equalTo: titleStrip.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 12),
        ]
        applyTabPlacement()
    }

    private func startTimers() {
        let fast = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tickStatus() }
        let medium = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.sessions.forEach { $0.pollProcess() }
            AccountSwitcher.shared.poll(self.sessions)
            ConnectionResume.shared.poll(self.sessions)
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
        sidebar.blinkOn = tabBar.blinkOn
    }

    /// One git call per distinct folder, fanned out to every tab in it. A folder whose tabs printed
    /// nothing since the last call is skipped, apart from a slow check for edits made elsewhere.
    private func pollGit() {
        let now = Date()
        let paths = Set(sessions.map(\.cwd))
        gitPolledAt = gitPolledAt.filter { paths.contains($0.key) }
        for path in paths {
            let last = gitPolledAt[path] ?? .distantPast
            let active = sessions.contains { $0.cwd == path && ($0.signals.lastOutput ?? .distantPast) > last }
            guard active || now.timeIntervalSince(last) >= Self.idleGitInterval else { continue }
            gitPolledAt[path] = now
            git.refresh(path: path) { [weak self] summary in
                self?.sessions.filter { $0.cwd == path }.forEach { $0.updateGit(summary) }
            }
        }
        // Agent tabs: what changed since that agent started. Claude and Codex are counted from
        // their own transcripts (works outside git repos); other agents from a git snapshot.
        for session in sessions where session.agentName != nil {
            if session.agentName == "claude", let id = session.claudeSessionID {
                transcripts.claude(sessionID: id) { [weak session] usage in session?.updateAgentUsage(usage ?? AgentUsage()) }
                if session.needsTranscriptTitle {
                    transcripts.claudeTitle(sessionID: id) { [weak session] title in session?.updateTranscriptTitle(title) }
                }
                continue
            }
            if session.agentName == "codex", let start = session.agentStartedAt {
                transcripts.codex(cwd: session.cwd, since: start) { [weak session] usage in session?.updateAgentUsage(usage ?? AgentUsage()) }
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
        regroup(saved)
    }

    /// Gathers the restored panes back into their saved tabs and selects the saved pane.
    private func regroup(_ saved: SavedWorkspace?) {
        let selectedID = saved.flatMap { $0.tabs.indices.contains($0.selected) ? $0.tabs[$0.selected].tabID : nil }
        groups = SavedPaneGroup.regroup(sessions.map(\.tabID), saved: saved?.groups ?? []).map {
            PaneGroup(layout: $0.layout, focused: $0.focused)
        }
        syncSessionOrder()
        if let selectedID, session(selectedID) != nil { return focus(selectedID) }
        select(min(saved?.selected ?? 0, groups.count - 1))
    }

    /// New tabs open in the selected tab's folder, as in Terminal.app.
    private var currentFolder: String { focusedSession?.cwd ?? NSHomeDirectory() }

    var selectedGroup: PaneGroup? { groups.indices.contains(selected) ? groups[selected] : nil }

    /// The pane you're typing in, in the selected tab.
    var focusedSession: TerminalSession? { selectedGroup.flatMap { session($0.focused) } }

    func session(_ tabID: String) -> TerminalSession? { sessions.first { $0.tabID == tabID } }

    private func groupIndex(of session: TerminalSession) -> Int? {
        groups.firstIndex { $0.layout.contains(session.tabID) }
    }

    /// Keeps `sessions` in tab order, so the first pane of tab n is where tab n's shells start.
    private func syncSessionOrder() {
        let byID = Dictionary(sessions.map { ($0.tabID, $0) }, uniquingKeysWith: { first, _ in first })
        sessions = groups.flatMap { $0.layout.panes.compactMap { byID[$0] } }
    }

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
        let tabs = items.map(\.session)
        showMoving(tabs, items.contains { $0.agent != nil } ? "Waiting to move…" : "Moving to the cloud…")
        let move = CloudMove(cloud: cloud, isOpen: { [weak self] in self?.sessions.contains($0) == true },
                             replace: { [weak self] old, new in self?.replaceTab(old, with: new) })
        move.onProgress = { [weak self] share in
            self?.showMoving(tabs, share < 1 ? "Copying to the cloud · \(Int(share * 100))%" : "Starting in the cloud…", progress: share)
        }
        move.confirmLargeCopy = { [weak self] bytes, answer in self?.confirmLargeCopy(bytes, answer) }
        move.run(items) { [weak self] outcome in
            self?.window?.subtitle = ""
            self?.showMoving(tabs, nil)
            switch outcome {
            case .moved(let count):
                self?.syncPhoneToCloud()
                Notifier.shared.post(title: "Moved \(count) tab\(count == 1 ? "" : "s") to the cloud",
                                     body: CloudReturn.movedAway
                                        ? "You can turn off this Mac; they keep running and come back when you return."
                                        : "It keeps running there. Right-click the tab and choose Bring Back from Cloud to bring it back.",
                                     tabID: "cloud")
            case .failed(let reason):
                Notifier.shared.post(title: "Couldn't move tabs to the cloud", body: reason, tabID: "cloud")
            case .cancelled:
                break
            }
            done(outcome)
            _ = move
        }
    }

    /// A big first copy takes minutes; the user decides before any agent stops.
    private func confirmLargeCopy(_ bytes: Int64, _ answer: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Copy \(CloudCopySize.describe(bytes)) to the cloud?"
        alert.informativeText = "The first move takes about \(CloudCopySize.minutes(bytes)) min; later moves send only what changed. "
            + "Files your .gitignore lists are already left out. To leave out more, add them to .gitignore."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        answer(alert.runModal() == .alertFirstButtonReturn)
    }

    /// Puts `new` in `old`'s pane and ends `old`'s shell.
    func replaceTab(_ old: TerminalSession, with new: TerminalSession) {
        guard let index = groupIndex(of: old) else { return }
        let group = groups[index]
        wire(new)
        sessions.append(new)
        group.layout = group.layout.replacing(old.tabID, with: new.tabID)
        if group.focused == old.tabID { group.focused = new.tabID }
        syncSessionOrder()
        end(old)
        select(selected)
    }

    /// `attaching` shows a shell the machine already runs.
    func openCloudTab(_ cloud: CloudHost, attaching id: String? = nil) {
        do {
            install(try TerminalSession(cloud: cloud, cwd: currentFolder, attaching: id))
            if id == nil { Analytics.record(.featureUsed(.cloudTab)) }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't open a cloud tab"
            alert.informativeText = "The cloud machine at \(cloud) didn't answer: \(error)"
            alert.runModal()
        }
    }

    #if DEBUG
    func tabMenuItemForTest(_ index: Int, _ title: String) -> NSMenuItem? {
        menu(for: sessions[index]).items.first { $0.title == title }
    }

    func restoreTabForTest(_ saved: SavedTab) { addTab(cwd: saved.cwd, restoring: saved) }
    var selectedTabCardForTest: NSView { tabBar.selectedCardForTest }
    var selectedTabIDForTest: String { focusedSession?.tabID ?? "" }
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

    @discardableResult
    private func addTab(cwd: String, restoring saved: SavedTab?, command: String? = nil) -> TerminalSession {
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        let session = TerminalSession(cwd: dir, restoring: saved, command: command)
        install(session)
        return session
    }

    /// A new tab showing `session`.
    private func install(_ session: TerminalSession) {
        wire(session)
        sessions.append(session)
        groups.append(PaneGroup(session))
        select(groups.count - 1)
        pollGit()
    }

    /// An empty pane beside (`.columns`) or below (`.rows`) the one you're typing in, showing
    /// the pane picker: choose another tab to show there, or a new shell.
    func split(_ axis: PaneAxis) {
        guard let group = selectedGroup, let current = focusedSession else { return }
        dropPickers()
        let slot = "picker-" + UUID().uuidString
        group.layout = group.layout.splitting(current.tabID, with: slot, axis: axis)
        group.picker = slot
        group.focused = slot
        select(selected)
        Analytics.record(.featureUsed(.split))
    }

    /// Puts `session` in the selected split's empty pane, or beside the pane you're typing in.
    func show(_ session: TerminalSession, beside axis: PaneAxis) {
        guard let group = selectedGroup, !group.layout.contains(session.tabID) else { return focus(session.tabID) }
        if group.picker == nil {
            guard let current = focusedSession else { return }
            let slot = "picker-" + UUID().uuidString
            group.layout = group.layout.splitting(current.tabID, with: slot, axis: axis)
            group.picker = slot
        }
        fillPicker(with: session.tabID)
    }

    /// Fills the selected split's empty pane with the tab `tabID`, taken out of wherever it was
    /// shown, or with a new shell in the current folder when nil.
    func fillPicker(with tabID: String?) {
        guard let group = selectedGroup, let slot = group.picker else { return }
        let session: TerminalSession
        if let tabID, let existing = self.session(tabID) {
            takeOut(existing)
            session = existing
        } else {
            let folder = group.layout.panes.compactMap(self.session(_:)).first?.cwd ?? NSHomeDirectory()
            session = TerminalSession(cwd: FileManager.default.fileExists(atPath: folder) ? folder : NSHomeDirectory(),
                                      restoring: nil, command: nil)
            wire(session)
            sessions.append(session)
        }
        group.layout = group.layout.replacing(slot, with: session.tabID)
        group.picker = nil
        group.focused = session.tabID
        syncSessionOrder()
        select(groups.firstIndex { $0 === group } ?? 0)
        pollGit()
    }

    /// Closes the empty pane without choosing anything.
    func cancelPicker() {
        guard let group = selectedGroup, let slot = group.picker, let rest = group.layout.removing(slot) else { return }
        group.layout = rest
        group.picker = nil
        if group.focused == slot { group.focused = rest.panes[0] }
        select(selected)
    }

    /// Any tab's empty pane goes away: only the shown split can have one.
    private func dropPickers(except keep: PaneGroup? = nil) {
        for group in groups where group !== keep {
            guard let slot = group.picker, let rest = group.layout.removing(slot) else { continue }
            group.layout = rest
            group.picker = nil
            if group.focused == slot { group.focused = rest.panes[0] }
        }
    }

    /// Takes `session` out of the split (or tab) it's in, leaving it shown nowhere. A tab left
    /// with no shells goes away.
    private func takeOut(_ session: TerminalSession) {
        guard let index = groupIndex(of: session) else { return }
        let group = groups[index]
        if let rest = group.layout.removing(session.tabID), rest.panes.contains(where: { self.session($0) != nil }) {
            group.layout = rest
            if group.focused == session.tabID { group.focused = rest.panes.first { self.session($0) != nil } ?? rest.panes[0] }
        } else {
            groups.remove(at: index)
        }
    }

    /// Puts every pane of `session`'s split back into a tab of its own, in place; nothing closes.
    func unsplit(_ session: TerminalSession? = nil) {
        guard let target = session ?? focusedSession, let index = groupIndex(of: target) else { return }
        let group = groups[index]
        let panes = group.layout.panes.compactMap(self.session(_:))
        guard panes.count > 1 || group.picker != nil else { return }
        let focused = group.focused
        groups.replaceSubrange(index...index, with: panes.map(PaneGroup.init))
        syncSessionOrder()
        focus(self.session(focused) == nil ? target.tabID : focused)
    }

    /// Takes one pane out of its split into a tab of its own, right after the split.
    func moveToOwnTab(_ session: TerminalSession) {
        guard let index = groupIndex(of: session), groups[index].layout.panes.count > 1 else { return }
        let group = groups[index]
        takeOut(session)
        let after = (groups.firstIndex { $0 === group } ?? index) + 1
        groups.insert(PaneGroup(session), at: min(after, groups.count))
        syncSessionOrder()
        focus(session.tabID)
    }

    /// Selects `tabID`'s tab and types in its pane.
    func focus(_ tabID: String) {
        guard let index = groups.firstIndex(where: { $0.layout.contains(tabID) }) else { return }
        groups[index].focused = tabID
        select(index)
    }

    /// The callbacks and view every pane's shell gets.
    private func wire(_ session: TerminalSession) {
        session.onChange = { [weak self] in self?.render() }
        session.onStatusChange = { [weak session] status in
            // No banner for the tab you're already looking at.
            guard let session, !(session.signals.focused && NSApp.isActive) else { return }
            Notifier.shared.post(status: status, tabID: session.tabID, topic: session.topic, folder: session.folder)
        }
        session.onTyped = { [weak self, weak session] in
            guard let self, let session, self.focusedSession === session else { return }
            self.cdSuggestions.typed(in: session)
        }
        session.onCleanExit = { [weak self, weak session] in
            guard let self, let session, self.sessions.contains(session) else { return }
            self.removePane(session)
        }
        // The pane host sizes it to its pane.
        let view = session.view
        view.translatesAutoresizingMaskIntoConstraints = true
        view.isHidden = true
        container.addSubview(view)
        // GPU rendering is opt-in until it has been checked on screen: AGTERM_METAL=1.
        if ProcessInfo.processInfo.environment["AGTERM_METAL"] == "1" { try? view.setUseMetal(true) }
    }

    /// ⌘W: the tab you're typing in; in a split, its neighbor takes the space. In an empty
    /// pane, closes that pane.
    @objc func closeTab() {
        guard let session = focusedSession else { return cancelPicker() }
        confirmClose([session])
    }

    // MARK: Tab menu

    /// What right-clicking a tab offers. Each item carries its tab, so it acts on that tab
    /// even if the tabs move while the menu is open.
    private func menu(for session: TerminalSession) -> NSMenu {
        let menu = NSMenu()
        let shown = selectedGroup?.layout.contains(session.tabID) == true
        let inSplit = (groupIndex(of: session).map { groups[$0].layout.panes.count } ?? 1) > 1
        // A tab on screen splits; one that isn't can be shown beside the one on screen.
        let split: [(String, Selector)?] = !shown ? [
            ("Show to the Right", #selector(showRightFromMenu(_:))),
            ("Show Below", #selector(showBelowFromMenu(_:))),
        ] : [
            ("Split Right", #selector(splitRightFromMenu(_:))),
            ("Split Down", #selector(splitDownFromMenu(_:))),
        ] + (inSplit ? [
            ("Move to Own Tab", #selector(moveToOwnTabFromMenu(_:))),
            ("Unsplit", #selector(unsplitFromMenu(_:))),
        ] : [])
        let entries: [(String, Selector)?] = [
            ("Rename Tab…", #selector(renameTabFromMenu(_:))),
            nil,
            ("New Tab in This Folder", #selector(newTabInFolderFromMenu(_:))),
        ] + split + [
            nil,
            ("Copy Folder Path", #selector(copyFolderPathFromMenu(_:))),
            ("Show in Finder", #selector(showInFinderFromMenu(_:))),
            nil,
        // With agterm Cloud hidden (stable builds), a tab already in the cloud can still come back.
        ] + ((!CloudAccount.isEnabled && !session.isCloud) || session.signals.exited ? [] : [
            session.isCloud ? ("Bring Back from Cloud", #selector(bringBackTabFromMenu(_:))) : ("Move to Cloud", #selector(moveTabToCloudFromMenu(_:))),
            nil,
        ]) + [
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

    @objc func renameTab() { focusedSession.map(rename) }

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
        guard let session = sender.representedObject as? TerminalSession else { return }
        confirmClose([session])
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
            if self.focusedSession === session { window.makeFirstResponder(session.view) }
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
        let focused = focusedSession.flatMap { sessions.firstIndex(of: $0) } ?? 0
        WorkspaceStore.save(SavedWorkspace(selected: focused, tabs: tabs, savedAt: Date(),
                                           groups: groups.compactMap(\.saved)))
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
        groups = []
        closing.forEach { endingSessions ? $0.terminate() : $0.detach() }
    }

    // MARK: Reordering

    /// Moves a tab, keeping the same tab selected.
    func moveTab(from: Int, to: Int) {
        guard groups.indices.contains(from), groups.indices.contains(to), from != to else { return }
        let next = TabOrder.selection(afterMoving: from, to: to, selected: selected)
        groups = TabOrder.moved(groups, from: from, to: to)
        syncSessionOrder()
        select(next)
    }

    @objc func moveTabLeft() { moveTab(from: selected, to: selected - 1) }
    @objc func moveTabRight() { moveTab(from: selected, to: selected + 1) }

    /// The next tab in the list, each pane of a split counting as its own tab.
    @objc func nextTab() { stepTab(by: 1) }

    @objc func previousTab() { stepTab(by: -1) }

    private func stepTab(by step: Int) {
        guard !sessions.isEmpty else { return }
        let current = focusedSession.flatMap { sessions.firstIndex(of: $0) }
            ?? selectedGroup.flatMap { group in sessions.firstIndex { group.layout.contains($0.tabID) } } ?? 0
        selectCard((current + step + sessions.count) % sessions.count)
    }

    @objc func selectTabFromMenu(_ sender: NSMenuItem) {
        // ⌘9 always means the last tab, as in Safari and Terminal.
        selectCard(sender.tag == 9 ? sessions.count - 1 : sender.tag - 1)
    }

    /// The tab at `index` in the tab bar or sidebar (one per shell). With an empty pane open,
    /// a tab not already shown goes into it.
    func selectCard(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        let session = sessions[index]
        if let group = selectedGroup, group.picker != nil, !group.layout.contains(session.tabID) {
            return fillPicker(with: session.tabID)
        }
        focus(session.tabID)
    }

    /// Shows tab `index` and types in its focused pane.
    func select(_ index: Int) {
        guard groups.indices.contains(index) else { return }
        let group = groups[index]
        dropPickers(except: group)
        selected = groups.firstIndex { $0 === group } ?? index
        cdSuggestions.hide()
        if !group.layout.contains(group.focused) { group.focused = group.layout.panes[0] }
        let focused = session(group.focused)
        if commandBar.superview != nil, focused == nil || focused !== commandBarTarget { hideCommandBar(refocus: false) }
        showSelectedPanes()
        if let focused {
            focused.view.needsDisplay = true
            window?.makeFirstResponder(focused.view)
        } else {
            window?.makeFirstResponder(panePicker)
        }
        render()
    }

    /// Lays out the selected tab's panes and hides every other shell.
    func showSelectedPanes() {
        guard let group = selectedGroup else { return }
        let now = Date()
        let key = window?.isKeyWindow ?? true
        var views: [String: NSView] = [:]
        for session in sessions {
            let shown = group.layout.contains(session.tabID)
            session.view.isHidden = !shown
            session.setFocused(shown && session.tabID == group.focused && key, now: now)
            if shown { views[session.tabID] = session.view }
        }
        panePicker.isHidden = group.picker == nil
        if let slot = group.picker {
            views[slot] = panePicker
            panePicker.choices = pickerChoices(for: group)
        }
        container.show(group.layout, views: views, focused: group.focused)
        container.layoutSubtreeIfNeeded()
    }

    /// Closes `panes` (one tab's), asking first about any still running a program.
    private func confirmClose(_ panes: [TerminalSession]) {
        guard !panes.isEmpty, window?.attachedSheet == nil else { return }
        let running = panes.filter(\.isRunningProgram)
        guard !running.isEmpty else { return panes.forEach(removePane) }
        let alert = NSAlert()
        alert.messageText = panes.count == 1 ? "Close this tab?" : "Close these tabs?"
        alert.informativeText = running.map { "\($0.foregroundName ?? "A program") is still running in \($0.folder)." }
            .joined(separator: "\n")
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            panes.filter { self.sessions.contains($0) }.forEach(self.removePane)
        }
    }

    /// Ends a pane's shell; its neighbor takes the space, and a tab with no panes left closes.
    private func removePane(_ session: TerminalSession) {
        guard let index = groupIndex(of: session) else { return }
        let group = groups[index]
        let neighbor = group.layout.neighbor(of: session.tabID, .left, in: container.layoutSpace)
            ?? group.layout.neighbor(of: session.tabID, .up, in: container.layoutSpace)
        end(session)
        if let rest = group.layout.removing(session.tabID), rest.panes.contains(where: { self.session($0) != nil }) {
            group.layout = rest
            if group.focused == session.tabID { group.focused = neighbor.flatMap { rest.contains($0) ? $0 : nil } ?? rest.panes[0] }
            syncSessionOrder()
            return select(index == selected ? index : selected)
        }
        groups.remove(at: index)
        syncSessionOrder()
        guard !groups.isEmpty else {
            window?.close()
            return
        }
        select(index < selected ? selected - 1 : min(selected, groups.count - 1))
    }

    /// Ends `session`'s shell and lets go of it.
    private func end(_ session: TerminalSession) {
        sessions.removeAll { $0 === session }
        cdSuggestions.hide()
        if session === commandBarTarget { hideCommandBar(refocus: false) }
        session.onChange = nil
        session.terminate()
        session.view.removeFromSuperview()
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

    /// Moving to or from the cloud, and bringing tabs home (MainWindowController+Cloud).
    let cloudState = CloudState()

    func render() {
        updateCloudButton()
        let models = sessions.map(tabModel)
        if tabsOnLeft { sidebar.update(models) } else { tabBar.update(models) }
        if let focused = focusedSession {
            window?.title = focused.topic
            titleStrip.title = focused.topic
            titleStrip.logo = focused.agentName.flatMap(AgentLogo.image(for:))
        }
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
        sidebar.refreshAppearance()
        titleStrip.needsDisplay = true
        container.subviews.forEach { $0.needsDisplay = true }
        container.needsDisplay = true
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
        guard let session = focusedSession else { return }
        Analytics.record(.featureUsed(.commandBar))
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
        if refocus, let session = focusedSession { window?.makeFirstResponder(session.view) }
    }

    // ⌘= / ⌘- / ⌘0 change the saved font size, so Settings stays in sync.
    @objc func biggerFont() { Preferences.shared.update { $0.fontSize += 1 } }
    @objc func smallerFont() { Preferences.shared.update { $0.fontSize -= 1 } }
    @objc func resetFont() { Preferences.shared.update { $0.fontSize = AppearanceSettings().fontSize } }

    // MARK: TabBarDelegate

    func tabBar(_ bar: NSView, didSelect index: Int) { selectCard(index) }
    func tabBar(_ bar: NSView, didClose index: Int) {
        if sessions.indices.contains(index) { confirmClose([sessions[index]]) }
    }
    func tabBarDidRequestNewTab(_ bar: NSView) { newTab() }
    func tabBarAgentMenu(_ bar: NSView) -> NSMenu {
        let menu = NSMenu()
        let agents = AgentIntegration.installedAgents() ?? [.claude, .codex, .grok]
        AppDelegate.agentItems(agents, target: self).forEach(menu.addItem)
        return menu
    }
    /// Cards move a whole split at a time: the dragged card's split goes where the target card's is.
    func tabBar(_ bar: NSView, didMove from: Int, to: Int) {
        guard sessions.indices.contains(from), sessions.indices.contains(to),
              let source = groupIndex(of: sessions[from]), let target = groupIndex(of: sessions[to]) else { return }
        if source == target { return render() }
        moveTab(from: source, to: target)
    }
    func tabBar(_ bar: NSView, menuFor index: Int) -> NSMenu { menu(for: sessions[index]) }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { focusedSession?.setFocused(true, now: Date()) }

    func windowDidResignKey(_ notification: Notification) { focusedSession?.setFocused(false, now: Date()) }

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
    /// Repainted whenever the hole moves or resizes (tabs moving to the left move it without
    /// resizing this view), so no strip is left unpainted in a see-through window.
    weak var hole: NSView? {
        didSet {
            if let observer = holeObserver { NotificationCenter.default.removeObserver(observer) }
            hole?.postsFrameChangedNotifications = true
            holeObserver = hole.map {
                NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: $0, queue: .main) { [weak self] _ in
                    self?.needsDisplay = true
                }
            }
        }
    }
    private var holeObserver: NSObjectProtocol?

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
