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
        if let saved = WorkspaceStore.load(), !saved.tabs.isEmpty {
            saved.tabs.forEach { addTab(cwd: $0.cwd, restoring: $0) }
            select(saved.selected)
        } else {
            newTab()
        }
        startTimers()
        RemoteClient.shared.tabs = { [weak self] in self?.sessions ?? [] }
        Notifier.shared.onOpen = { [weak self] tabID in
            guard let self, let index = self.sessions.firstIndex(where: { $0.tabID == tabID }) else { return }
            self.window?.makeKeyAndOrderFront(nil)
            self.select(index)
        }
        appearanceSubscription = Preferences.shared.$appearance.dropFirst().sink { [weak self] settings in
            self?.applyAppearance()
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
        let medium = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.sessions.forEach { $0.pollProcess() } }
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
        // Agent tabs: what changed since that agent started.
        for session in sessions where session.agentName != nil {
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

    @objc func newTab() {
        let cwd = sessions.indices.contains(selected) ? sessions[selected].cwd : NSHomeDirectory()
        addTab(cwd: cwd, restoring: nil)
    }

    private func addTab(cwd: String, restoring saved: SavedTab?) {
        let dir = FileManager.default.fileExists(atPath: cwd) ? cwd : NSHomeDirectory()
        let session = TerminalSession(cwd: dir, restoring: saved)
        session.onChange = { [weak self] in self?.render() }
        session.onStatusChange = { [weak session] status in
            guard let session else { return }
            Notifier.shared.post(status: status, tabID: session.tabID, topic: session.topic, folder: session.folder)
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

    // MARK: Saving tabs

    /// Writes the open tabs (folder, history, resumable agent) for the next launch.
    func saveWorkspace() {
        guard !savedForQuit else { return }
        WorkspaceStore.save(SavedWorkspace(selected: selected, tabs: sessions.map { $0.snapshot() }, savedAt: Date()))
    }

    /// Saves one last time before quitting; later saves are ignored.
    func saveWorkspaceForQuit() {
        saveWorkspace()
        savedForQuit = true
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

    private func render() {
        tabBar.update(sessions.enumerated().map { i, s in
            TabModel(topic: s.topic, folder: s.folder, git: s.git, agentDiff: s.agentDiff.map { DiffCount(added: $0.added, removed: $0.removed) },
                     status: s.status, selected: i == selected)
        })
        if sessions.indices.contains(selected) { window?.title = sessions[selected].topic }
    }

    // MARK: Appearance

    /// Pushes the current `Theme` to the window, tab bar and every terminal.
    /// Full screen forces a solid background (see `WindowBlur.effectiveOpacity`).
    private func applyAppearance() {
        guard let window else { return }
        let settings = Preferences.shared.appearance
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
        sessions.forEach { $0.applyAppearance() }
        window.invalidateShadow()
    }

    // ⌘= / ⌘- / ⌘0 change the saved font size, so Settings stays in sync.
    @objc func biggerFont() { Preferences.shared.update { $0.fontSize += 1 } }
    @objc func smallerFont() { Preferences.shared.update { $0.fontSize -= 1 } }
    @objc func resetFont() { Preferences.shared.update { $0.fontSize = AppearanceSettings().fontSize } }

    // MARK: TabBarDelegate

    func tabBar(_ bar: TabBarView, didSelect index: Int) { select(index) }
    func tabBar(_ bar: TabBarView, didClose index: Int) { confirmClose(at: index) }
    func tabBarDidRequestNewTab(_ bar: TabBarView) { newTab() }
    func tabBar(_ bar: TabBarView, didMove from: Int, to: Int) { moveTab(from: from, to: to) }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        if sessions.indices.contains(selected) { sessions[selected].setFocused(true, now: Date()) }
    }

    func windowDidResignKey(_ notification: Notification) {
        if sessions.indices.contains(selected) { sessions[selected].setFocused(false, now: Date()) }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { applyAppearance() }
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

    func windowWillClose(_ notification: Notification) {
        timers.forEach { $0.invalidate() }
        // Empty the list first so the quit check below doesn't ask a second time.
        saveWorkspaceForQuit()
        let closing = sessions
        sessions = []
        closing.forEach { $0.terminate() }
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
