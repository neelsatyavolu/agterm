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

    /// A message to type into the agent; a raw key (Esc, ⇧⇥, an approval answer) to send.
    var onSend: (String) -> Void = { _ in }
    var onKey: (String) -> Void = { _ in }
    /// When true, y / n / a and digits from an empty box answer the prompt on screen.
    var answersPrompt = false
    var agentTitle = "agent" { didSet { input.placeholder = "Message \(agentTitle)   ⏎ send · ⇧⏎ newline · / commands" } }
    var status = Status() { didSet { if status != oldValue { statusLine.needsDisplay = true } } }

    let input = ComposerTextView()
    private let statusLine = StatusLineView()
    private let box = NSView()
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
        for view in [statusLine, box, input, prompt] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(statusLine)
        addSubview(box)
        box.addSubview(input)
        box.addSubview(prompt)
        boxHeight = box.heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            statusLine.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            statusLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            statusLine.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            statusLine.heightAnchor.constraint(equalToConstant: 16),
            box.topAnchor.constraint(equalTo: statusLine.bottomAnchor, constant: 8),
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
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.color(Theme.palette.fg, alpha: 0.08).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    func send() {
        let text = input.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        input.string = ""
        textDidChange(Notification(name: NSText.didChangeNotification))
        onSend(text)
    }
}

/// The message box: ⏎ sends, ⇧⏎ adds a line, Esc and ⇧⇥ go to the agent.
final class ComposerTextView: NSTextView {
    weak var composer: ChatComposer?
    var placeholder = "" { didSet { needsDisplay = true } }

    override func keyDown(with event: NSEvent) {
        guard let composer else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
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
        case .waiting: (Theme.warn, "waiting for you", "⌃` to answer in the terminal")
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
