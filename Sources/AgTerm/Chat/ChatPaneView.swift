import AgTermCore
import AppKit

/// A tab's agent shown as a chat: its transcript, a card when it waits on you, and a composer
/// that types into its terminal. The agent keeps running in the terminal, hidden underneath,
/// which takes this view's size. Reads the transcript only while on screen, at most twice a
/// second, and only what the file gained.
final class ChatPaneView: NSView {
    static let pollInterval: TimeInterval = 0.5
    private static let reader = DispatchQueue(label: "agterm.chat-transcripts", qos: .userInitiated)

    let tabID: String
    private(set) weak var session: TerminalSession?
    let transcript = ChatTranscriptView()
    let card = ChatPromptCard()
    let composer = ChatComposer()
    private let follower = TranscriptFollower()
    /// A transcript to show instead of the agent's (self-tests).
    private let fixture: TranscriptFollower.Target?
    private var timer: Timer?
    private var reading = false
    /// What the shown rows were built from: the follower's version and whether the agent worked.
    private var built: (version: Int, working: Bool)?
    private var workingSince: Date?
    private var screenReadAt: Date?
    /// The model the transcript names, for the title strip when the tab's usage has none (Grok).
    private(set) var model: String?
    /// How full the agent's context window is, for the title strip.
    private(set) var context: ContextUse?
    /// The transcript named a different model, or the context window filled further.
    var onModel: () -> Void = {}
    /// When the `/` menu's commands were last read; skills added since show up after this long.
    private var commandsReadAt: Date?
    static let commandsMaxAge: TimeInterval = 10
    /// When the `@` menu's files were last listed.
    private var filesReadAt: Date?

    init(session: TerminalSession, fixture: TranscriptFollower.Target? = nil) {
        tabID = session.tabID
        self.session = session
        self.fixture = fixture
        super.init(frame: session.view.frame)
        let agent = fixture?.agent.rawValue ?? session.agentName ?? "agent"
        composer.agentTitle = agent
        transcript.placeholder = "waiting for \(agent)'s first reply"
        composer.onSend = { [weak self] text, images in self?.type(text, images: images) }
        composer.onKey = { [weak self] key in self?.press(key) }
        card.onKey = { [weak self] key in self?.press(key) }
        composer.onWantsCommands = { [weak self] in self?.loadCommands() }
        composer.onWantsFiles = { [weak self] in self?.loadFiles() }
        composer.onArrow = { [weak self] arrow in
            guard let self, let terminal = self.session?.view.getTerminal() else { return }
            self.press(ChatInput.arrow(arrow, applicationCursor: terminal.applicationCursor))
        }
        card.isHidden = true
        layoutParts()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func layoutParts() {
        let bottom = NSStackView(views: [card, composer])
        bottom.orientation = .vertical
        bottom.alignment = .centerX
        bottom.spacing = 8
        bottom.detachesHiddenViews = true
        for view in [transcript, bottom] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: topAnchor),
            transcript.leadingAnchor.constraint(equalTo: leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.widthAnchor.constraint(equalTo: bottom.widthAnchor, constant: -32),
            composer.widthAnchor.constraint(equalTo: bottom.widthAnchor),
        ])
    }

    var isFixture: Bool { fixture != nil }
    var agentName: String { fixture?.agent.rawValue ?? session?.agentName ?? "agent" }

    /// The composer, for the window's first responder.
    var responder: NSView { composer.input }

    func applyAppearance() {
        transcript.rebuild()
        card.applyAppearance()
        composer.applyAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg.setFill()
        dirtyRect.fill()
    }

    /// The terminal underneath keeps this pane's size, so the agent lays out for it.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        session?.view.frame = NSRect(origin: frame.origin, size: newSize)
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        session?.view.frame = frame
    }

    // MARK: Polling, only while on screen

    override func viewDidMoveToWindow() { updateTimer() }
    override func viewDidHide() { updateTimer() }
    override func viewDidUnhide() { updateTimer() }

    private func updateTimer() {
        let visible = window != nil && !isHiddenOrHasHiddenAncestor
        if visible, timer == nil {
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                self?.tick()
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            tick()
        } else if !visible {
            timer?.invalidate()
            timer = nil
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        guard let session else { return stop() }
        let working = session.status == .working
        if working, workingSince == nil { workingSince = Date() } else if !working { workingSince = nil }
        readScreen(session)
        var status = composer.status
        status.state = switch session.status {
        case .working: .working(seconds: Int(Date().timeIntervalSince(workingSince ?? Date())))
        case .exited: .exited
        case .waiting: card.isApproval ? .approval : .waiting
        default: .idle
        }
        composer.status = status
        composer.answersPrompt = card.isApproval
        composer.drivesScreen = !card.isHidden && !card.isApproval
        let readsFiles = [.claude, .codex, .grok].contains(fixture?.agent ?? session.agentName.flatMap(TimelineFeed.Agent.init(rawValue:)))
        if composer.mentionsFiles != readsFiles { composer.mentionsFiles = readsFiles }
        // A cloud tab's agent can't read a file saved on this Mac.
        composer.attachesImages = readsFiles && !session.isCloud
        readTranscript(working: working)
    }

    /// The prompt card and the input-mode hint come from the screen; read it only when it changed.
    private func readScreen(_ session: TerminalSession) {
        let output = session.signals.lastOutput ?? .distantPast
        guard screenReadAt.map({ output > $0 }) ?? true else { return }
        screenReadAt = Date()
        let lines = session.screenText().components(separatedBy: "\n")
        if let prompt = PermissionPrompt.read(lines) {
            card.show(.approval(prompt, context: ChatPrompt.context(screen: lines, question: prompt.question)))
        } else if session.status == .waiting {
            card.show(.screen(ChatRows.screenExcerpt(lines)))
        } else {
            card.show(nil)
        }
        composer.status.mode = ChatModeHint.read(lines)
    }

    private func readTranscript(working: Bool) {
        guard !reading, let target = fixture ?? session.flatMap(TranscriptFollower.Target.init) else { return }
        reading = true
        let follower = follower, built = built
        Self.reader.async { [weak self] in
            follower.refresh(target)
            let version = follower.version
            let model = follower.model
            let context = follower.context
            let rows = built.map { $0.version == version && $0.working == working } == true
                ? nil : ChatRows.build(follower.entries, working: working)
            DispatchQueue.main.async {
                guard let self else { return }
                self.reading = false
                if (model != nil && model != self.model) || context != self.context {
                    self.model = model ?? self.model
                    self.context = context
                    self.onModel()
                }
                guard let rows else { return }
                self.built = (version, working)
                self.transcript.update(rows)
            }
        }
    }

    // MARK: The / menu

    /// Reads the agent's commands for this folder off the main thread, at most every few seconds.
    private func loadCommands() {
        guard commandsReadAt.map({ Date().timeIntervalSince($0) > Self.commandsMaxAge }) ?? true,
              let agent = fixture?.agent ?? session?.agentName.flatMap(TimelineFeed.Agent.init(rawValue:)) else { return }
        commandsReadAt = Date()
        let cwd = fixture?.cwd ?? session?.cwd ?? ""
        let homes = SlashCatalog.Homes(user: FileManager.default.homeDirectoryForCurrentUser, claude: AccountStore.nativeClaudeHome,
                                       codex: AccountStore.nativeCodexHome, grok: AccountStore.nativeGrokHome)
        Self.reader.async { [weak self] in
            let commands = SlashCatalog.commands(for: agent, cwd: cwd, homes: homes)
            DispatchQueue.main.async { self?.composer.commands = commands }
        }
    }

    /// Lists the tab folder's files off the main thread, at most every few seconds.
    private func loadFiles() {
        guard filesReadAt.map({ Date().timeIntervalSince($0) > Self.commandsMaxAge }) ?? true else { return }
        filesReadAt = Date()
        let cwd = fixture?.cwd ?? session?.cwd ?? ""
        Self.reader.async { [weak self] in
            let files = FileMention.files(in: cwd)
            DispatchQueue.main.async { self?.composer.files = files }
        }
    }

    // MARK: Typing into the agent

    private func type(_ text: String, images: [String] = []) {
        guard let view = session?.view,
              let keys = ChatInput.typing(text, images: images, bracketedPaste: view.getTerminal().bracketedPasteMode) else { return }
        view.send(txt: keys)
        let delay = images.isEmpty ? ChatInput.submitDelay : ChatInput.imageSubmitDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in view?.send(txt: ChatInput.enter) }
        transcript.scrollToBottom()
    }

    /// Esc interrupts a working agent the way it expects (Grok takes ⌃C); other keys go as they are.
    private func press(_ key: String) {
        guard let session else { return }
        let interrupt = key == ChatInput.escape && session.status == .working
        session.view.send(txt: interrupt ? ChatInput.interrupt(agent: session.agentName) : key)
        screenReadAt = nil
    }
}
