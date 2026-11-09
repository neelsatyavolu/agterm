import AgTermCore
import AppKit

/// The bottom of the Chat view: a status line (working / idle / needs approval, the agent's
/// input mode), then the message box. What you type goes to the agent's terminal.
final class ChatComposer: NSView, NSTextViewDelegate {
    struct Status: Equatable {
        enum State: Equatable { case idle, working(seconds: Int), approval, waiting, exited }
        var state: State = .idle
        var mode: String?
    }

    /// A message to type into the agent, with the paths of images to attach; a raw key (Esc,
    /// ⇧⇥, an approval answer) to send.
    var onSend: (String, [String]) -> Void = { _, _ in }
    var onKey: (String) -> Void = { _ in }
    var onArrow: (ChatInput.Arrow) -> Void = { _ in }
    /// While the agent shows a picker or menu: from an empty box, the arrows, ⏎ and ⇥ go to it.
    var drivesScreen = false
    /// When true, y / n / a and digits from an empty box answer the prompt on screen.
    var answersPrompt = false
    var agentTitle = "agent" { didSet { updatePlaceholder() } }
    /// The agent reads `@path` as a file (Claude Code, Codex, Grok): `@` opens a list of the folder's files.
    var mentionsFiles = false { didSet { updatePlaceholder() } }
    /// Pasted or dropped images go to the agent as attachments (not for agl, or a cloud tab's agent).
    var attachesImages = false
    var status = Status() { didSet { if status != oldValue { statusLine.needsDisplay = true } } }
    /// The agent's slash commands for the `/` menu; asked for with `onWantsCommands` when you type `/`.
    var commands: [SlashCommand] = [] { didSet { updateMenu() } }
    var onWantsCommands: () -> Void = {}
    /// The tab folder's files for the `@` menu, relative to it; asked for with `onWantsFiles`.
    var files: [String] = [] { didSet { updateMenu() } }
    var onWantsFiles: () -> Void = {}

    let input = ComposerTextView()
    private let statusLine = StatusLineView()
    private let box = NSView()
    let slashMenu = ChatSlashMenu()
    private var menuHeight: NSLayoutConstraint!
    private var menuGap: NSLayoutConstraint!
    /// What the menu shows: a `/` command or an `@` path being typed, and where its word starts.
    private enum Query: Equatable {
        case command(String)
        case file(String, start: Int)
        var key: String { switch self { case .command(let q): "/" + q; case .file(let q, let start): "@\(start):" + q } }
    }
    private var shownQuery: Query?
    /// Esc closed the menu for the query you were typing.
    private var dismissedQuery: String?
    /// Images pasted into the box; `[Image #N]` stands for the Nth.
    private var images: [String] = []
    /// Messages you sent, oldest first, for ↑ and ↓; `recalled` is the one in the box.
    private var history: [String] = []
    private var recalled: Int?
    /// The accent `›` before the text; a subview, since the box's layer covers what this view draws.
    private let prompt = NSTextField(labelWithString: "›")
    private var boxHeight: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        statusLine.composer = self
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        input.composer = self
        input.isRichText = false
        input.allowsUndo = true
        input.drawsBackground = false
        input.textContainerInset = NSSize(width: 0, height: 0)
        input.textContainer?.lineFragmentPadding = 0
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticTextReplacementEnabled = false
        input.isAutomaticSpellingCorrectionEnabled = false
        input.delegate = self
        slashMenu.onChoose = { [weak self] item in self?.complete(item) }
        slashMenu.isHidden = true
        for view in [statusLine, slashMenu, box, input, prompt] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(statusLine)
        addSubview(slashMenu)
        addSubview(box)
        box.addSubview(input)
        box.addSubview(prompt)
        boxHeight = box.heightAnchor.constraint(equalToConstant: 40)
        menuHeight = slashMenu.heightAnchor.constraint(equalToConstant: 0)
        menuGap = box.topAnchor.constraint(equalTo: slashMenu.bottomAnchor, constant: 0)
        NSLayoutConstraint.activate([
            statusLine.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            statusLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            statusLine.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            statusLine.heightAnchor.constraint(equalToConstant: 16),
            slashMenu.topAnchor.constraint(equalTo: statusLine.bottomAnchor, constant: 8),
            slashMenu.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            slashMenu.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            menuHeight,
            menuGap,
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            boxHeight,
            prompt.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            prompt.firstBaselineAnchor.constraint(equalTo: input.topAnchor, constant: ChatStyle.font.ascender),
            input.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 34),
            input.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            input.topAnchor.constraint(equalTo: box.topAnchor, constant: 11),
            input.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -11),
        ])
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyAppearance() {
        box.layer?.backgroundColor = Theme.color(Theme.palette.bg.mixed(with: Theme.palette.fg, 0.05)).cgColor
        box.layer?.borderColor = Theme.color(Theme.palette.fg, alpha: 0.14).cgColor
        input.font = ChatStyle.font
        prompt.font = ChatStyle.boldFont
        prompt.textColor = Theme.accent
        input.textColor = Theme.fg
        input.insertionPointColor = Theme.accent
        input.typingAttributes = [.font: ChatStyle.font, .foregroundColor: Theme.fg]
        slashMenu.applyAppearance()
        textDidChange(Notification(name: NSText.didChangeNotification))
        needsDisplay = true
        statusLine.needsDisplay = true
        input.needsDisplay = true
    }

    /// The box grows with what you type, up to six lines.
    func textDidChange(_ notification: Notification) {
        guard let manager = input.layoutManager, let container = input.textContainer else { return }
        manager.ensureLayout(for: container)
        let lineHeight = manager.defaultLineHeight(for: ChatStyle.font)
        let used = max(lineHeight, manager.usedRect(for: container).height)
        boxHeight.constant = min(used, lineHeight * 6) + 22
        if let index = recalled, history[index] != input.string { recalled = nil }
        updateMenu()
    }

    private func updatePlaceholder() {
        input.placeholder = "Message \(agentTitle)   ⏎ send · ⇧⏎ newline · / commands" + (mentionsFiles ? " · @ files" : "")
    }

    // MARK: The / and @ menus

    var menuShown: Bool { !slashMenu.isHidden }

    private func currentQuery() -> Query? {
        if let command = SlashMenu.query(input.string) { return .command(command) }
        guard mentionsFiles, input.selectedRange().length == 0,
              let mention = FileMention.query(input.string, caret: input.selectedRange().location) else { return nil }
        return .file(mention.query, start: mention.start)
    }

    /// Shows the commands matching a `/name`, or the files matching an `@path` at the caret;
    /// hides the menu otherwise.
    func updateMenu() {
        let query = currentQuery()
        if query?.key != dismissedQuery { dismissedQuery = nil }
        shownQuery = query
        var items: [SlashCommand] = []
        // A message brought back with ↑ stays as it was; ↓ keeps moving through history.
        if recalled == nil, let query, query.key != dismissedQuery {
            switch query {
            case .command(let text): items = SlashMenu.matches(text, in: commands)
            case .file(let text, _): items = FileMention.matches(text, in: files).map { SlashCommand($0, "") }
            }
        }
        switch query {
        case .command: onWantsCommands()
        case .file: onWantsFiles()
        case nil: break
        }
        switch query {
        case .command(let text): slashMenu.show(items, query: text, prefix: "/")
        case .file(let text, _): slashMenu.show(items, query: text, prefix: "@")
        case nil: slashMenu.show([], query: "", prefix: "/")
        }
        slashMenu.isHidden = items.isEmpty
        menuHeight.constant = slashMenu.fittingHeight
        menuGap.constant = items.isEmpty ? 0 : 6
    }

    func closeMenu() {
        dismissedQuery = currentQuery()?.key
        updateMenu()
    }

    /// ⇥ or a click: the command's name in the box, ready for arguments, or the file's path in
    /// place of the `@` word.
    func complete(_ item: SlashCommand) {
        switch shownQuery {
        case .file(_, let start):
            let text = input.string as NSString
            var end = input.selectedRange().location
            while end < text.length, let scalar = Unicode.Scalar(text.character(at: end)),
                  !CharacterSet.whitespacesAndNewlines.contains(scalar) { end += 1 }
            let completion = FileMention.completion(item.name)
            input.string = text.replacingCharacters(in: NSRange(location: start, length: end - start), with: completion)
            input.setSelectedRange(NSRange(location: start + (completion as NSString).length, length: 0))
        default:
            input.string = SlashMenu.completion(item)
            input.setSelectedRange(NSRange(location: (input.string as NSString).length, length: 0))
        }
        textDidChange(Notification(name: NSText.didChangeNotification))
        window?.makeFirstResponder(input)
    }

    /// ⏎ with the menu open runs the highlighted command, as the agents' menus do; on a file it
    /// fills the path in.
    func runSelected() {
        guard let item = slashMenu.current else { return send() }
        if case .file = shownQuery { return complete(item) }
        input.string = "/" + item.name
        send()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if mentionsFiles, shownQuery != currentQuery() { updateMenu() }
    }

    // MARK: Images

    static func imageLabel(_ number: Int) -> String { "[Image #\(number)]" }

    /// Images on a pasteboard (pasted, or dropped on the box) go in as `[Image #N]`; returns
    /// false when there are none, so the text view pastes as usual.
    func attachImages(from pasteboard: NSPasteboard) -> Bool {
        guard attachesImages, let paths = ChatImages.paths(from: pasteboard), !paths.isEmpty else { return false }
        var text = ""
        for path in paths {
            images.append(path)
            text += Self.imageLabel(images.count) + " "
        }
        input.insertText(text, replacementRange: input.selectedRange())
        return true
    }

    // MARK: History

    /// ↑ from an empty box (or one showing an earlier message) brings back what you sent before.
    func recall(_ step: Int) -> Bool {
        guard !history.isEmpty, input.string.isEmpty || recalled != nil else { return false }
        let index = (recalled ?? history.count) + step
        guard index >= 0 else { return true }
        guard index < history.count else {
            recalled = nil
            input.string = ""
            textDidChange(Notification(name: NSText.didChangeNotification))
            return true
        }
        recalled = index
        input.string = history[index]
        textDidChange(Notification(name: NSText.didChangeNotification))
        input.setSelectedRange(NSRange(location: (input.string as NSString).length, length: 0))
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.color(Theme.palette.fg, alpha: 0.08).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    func send() {
        let text = input.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        input.string = ""
        if history.last != text { history.append(text) }
        recalled = nil
        textDidChange(Notification(name: NSText.didChangeNotification))
        // Each `[Image #N]` goes as its image; the agent shows its own label for it.
        // Highest first, so taking out #1 leaves #10 alone.
        var message = text, attached: [String] = []
        for (index, path) in images.enumerated().reversed() where message.contains(Self.imageLabel(index + 1)) {
            let label = Self.imageLabel(index + 1)
            attached.insert(path, at: 0)
            message = message.replacingOccurrences(of: label + " ", with: "").replacingOccurrences(of: label, with: "")
        }
        onSend(message, attached)
    }
}

/// The message box: ⏎ sends, ⇧⏎ adds a line, Esc and ⇧⇥ go to the agent.
final class ComposerTextView: NSTextView {
    weak var composer: ChatComposer?
    var placeholder = "" { didSet { needsDisplay = true } }

    override func keyDown(with event: NSEvent) {
        guard let composer else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if composer.menuShown, flags.subtracting([.numericPad, .function]).isEmpty {
            switch event.keyCode {
            case 126: return composer.slashMenu.move(-1) // ↑
            case 125: return composer.slashMenu.move(1) // ↓
            case 48: return composer.slashMenu.current.map(composer.complete) ?? () // ⇥
            case 36, 76: return composer.runSelected()
            case 53: return composer.closeMenu() // Esc
            default: break
            }
        }
        if string.isEmpty, composer.drivesScreen, flags.subtracting([.numericPad, .function]).isEmpty {
            switch event.keyCode {
            case 126: return composer.onArrow(.up)
            case 125: return composer.onArrow(.down)
            case 123: return composer.onArrow(.left)
            case 124: return composer.onArrow(.right)
            case 36, 76: return composer.onKey(ChatInput.enter)
            case 48: return composer.onKey(ChatInput.tab)
            default: break
            }
        }
        if flags.subtracting([.numericPad, .function]).isEmpty, event.keyCode == 126 || event.keyCode == 125,
           isOnEdgeLine(up: event.keyCode == 126), composer.recall(event.keyCode == 126 ? -1 : 1) {
            return
        }
        switch event.keyCode {
        case 36, 76: // Return, Enter
            if flags.contains(.shift) || flags.contains(.option) { return insertNewlineIgnoringFieldEditor(nil) }
            return composer.send()
        case 53 where string.isEmpty: // Esc
            return composer.onKey(ChatInput.escape)
        case 48 where flags.contains(.shift): // ⇧⇥
            return composer.onKey(ChatInput.backTab)
        default:
            break
        }
        if string.isEmpty, composer.answersPrompt, flags.subtracting([.shift, .capsLock]).isEmpty,
           let key = event.charactersIgnoringModifiers?.lowercased(), ChatInput.isApprovalKey(key) {
            return composer.onKey(key)
        }
        super.keyDown(with: event)
    }

    /// The caret is on the first line (for ↑) or the last (for ↓), so the arrow leaves the text.
    private func isOnEdgeLine(up: Bool) -> Bool {
        let caret = selectedRange().location
        let text = string as NSString
        return up ? !text.substring(to: caret).contains("\n") : !text.substring(from: caret).contains("\n")
    }

    override func paste(_ sender: Any?) {
        if composer?.attachImages(from: .general) == true { return }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if composer?.attachImages(from: sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: ChatStyle.font, .foregroundColor: Theme.fg4]
        var text = NSAttributedString(string: placeholder, attributes: attributes)
        // In a narrow pane, drop the key hints rather than cut them off.
        if text.size().width > bounds.width, let short = placeholder.components(separatedBy: "   ").first {
            text = NSAttributedString(string: short, attributes: attributes)
        }
        text.draw(at: NSPoint(x: 0, y: 0))
    }

    override var isFlipped: Bool { true }
}

/// `● working 14s  esc to interrupt                accept edits on ⇧⇥   ⌃\` terminal`
private final class StatusLineView: NSView {
    weak var composer: ChatComposer?

    override func draw(_ dirtyRect: NSRect) {
        guard let status = composer?.status else { return }
        let font = ChatStyle.smallFont
        let (dot, label, hint): (NSColor, String, String?) = switch status.state {
        case .working(let seconds): (Theme.accent, "working " + (seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"), "esc to interrupt")
        case .approval: (Theme.warn, "needs approval", "answer below, or y / n")
        case .waiting: (Theme.warn, "waiting for you", "↑↓ ⏎ to answer, or ⌃` terminal")
        case .exited: (Theme.danger, "exited", nil)
        case .idle: (Theme.fg3, "idle", nil)
        }
        let mid = bounds.midY
        dot.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: mid - 3.5, width: 7, height: 7)).fill()
        var x: CGFloat = 16
        for (text, color) in [(label, Theme.fg2), (hint ?? "", Theme.fg3)] where !text.isEmpty {
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            string.draw(at: NSPoint(x: x, y: mid - string.size().height / 2))
            x += string.size().width + 14
        }
        let right = [status.mode.map { "\($0) ⇧⇥" }, "⌃` terminal"].compactMap { $0 }.joined(separator: "   ")
        let string = NSAttributedString(string: right, attributes: [.font: font, .foregroundColor: Theme.fg3])
        let width = string.size().width
        if bounds.width - width > x { string.draw(at: NSPoint(x: bounds.width - width, y: mid - string.size().height / 2)) }
    }

    override var isFlipped: Bool { true }
}
