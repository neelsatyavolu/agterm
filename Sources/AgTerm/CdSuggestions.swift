import AgTermCore
import AppKit

/// While you type `cd <word>` at a shell prompt, lists matching folders under the cursor.
/// ⇥ puts the highlighted one on the command line, ↑↓ move, esc hides the list.
final class CdSuggestions {
    private let list = CdSuggestionList()
    private weak var session: TerminalSession?
    private var word = ""
    /// The word the list was hidden for with esc; it stays hidden until the word changes.
    private var dismissed: String?
    private var pending: DispatchWorkItem?
    private var keyMonitor: Any?

    init() {
        _ = FolderIndex.shared.candidates(cwd: NSHomeDirectory())
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    /// A tab's screen changed right after you typed; look again once the echo settles.
    func typed(in session: TerminalSession) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.update(session)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    #if DEBUG
    var shownForTest: [String] { list.superview == nil ? [] : list.pathsForTest }
    #endif

    func hide() {
        pending?.cancel()
        list.removeFromSuperview()
        session = nil
    }

    private func update(_ session: TerminalSession) {
        let view = session.view
        guard view.window?.firstResponder === view, !session.isRunningProgram,
              let word = CdSuggest.query(beforeCursor: Self.textBeforeCursor(view)) else { return hide() }
        if word != dismissed { dismissed = nil }
        let known = FolderIndex.shared.candidates(cwd: session.cwd)
        let paths = CdSuggest.rank(query: word, cwd: session.cwd, candidates: known.folders, visits: known.visits)
        guard dismissed == nil, !paths.isEmpty, let container = view.superview else { return hide() }
        self.session = session
        self.word = word
        list.show(paths, home: NSHomeDirectory())
        if list.superview !== container { container.addSubview(list) }
        place(in: container, view: view)
    }

    private static func textBeforeCursor(_ view: AgentTerminalView) -> String {
        let terminal = view.getTerminal()
        let cursor = terminal.getCursorLocation()
        return terminal.getLine(row: cursor.y)?.translateToString(endCol: cursor.x) ?? ""
    }

    /// Under the word being typed, or above the line when there's no room below.
    private func place(in container: NSView, view: AgentTerminalView) {
        let caret = view.convert(view.caretFrame, to: container)
        let size = list.fittingSize
        let x = caret.minX - CGFloat(word.count) * caret.width - CdSuggestionList.inset
        var y = caret.minY - size.height - 2
        if y < 4 { y = caret.maxY + 2 }
        list.frame = NSRect(x: min(max(4, x), container.bounds.width - size.width - 4), y: y,
                            width: size.width, height: size.height)
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard list.superview != nil, let session, event.window === session.view.window,
              event.window?.firstResponder === session.view,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 48: // tab
            guard let path = list.selectedPath else { return false }
            let text = CdSuggest.display(path, home: NSHomeDirectory())
            session.view.send(data: CdSuggest.keystrokes(replacing: word, with: text)[...])
            hide()
        case 125: list.move(by: 1) // down
        case 126: list.move(by: -1) // up
        case 53: // esc
            dismissed = word
            hide()
        default:
            return false
        }
        return true
    }
}

/// The list itself: folder name, then where it lives, one row each, and a key hint.
final class CdSuggestionList: NSView {
    static let inset: CGFloat = 6
    private static let rowHeight: CGFloat = 24
    private static let hintHeight: CGFloat = 20
    private static let width: CGFloat = 460

    private var rows: [(path: String, name: String, parent: String)] = []
    private var selected = 0

    #if DEBUG
    var pathsForTest: [String] { rows.map(\.path) }
    #endif

    var selectedPath: String? { rows.indices.contains(selected) ? rows[selected].path : nil }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        self.shadow = shadow
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var fittingSize: NSSize {
        NSSize(width: Self.width, height: CGFloat(rows.count) * Self.rowHeight + Self.hintHeight + Self.inset * 2)
    }

    func show(_ paths: [String], home: String) {
        let previous = selectedPath
        rows = paths.map { path in
            let parent = CdSuggest.display((path as NSString).deletingLastPathComponent, home: home)
                .replacingOccurrences(of: "\\", with: "")
            return (path, (path as NSString).lastPathComponent, parent)
        }
        selected = rows.firstIndex { $0.path == previous } ?? 0
        layer?.backgroundColor = Theme.color(Theme.palette.chrome).cgColor
        layer?.borderColor = Theme.border.cgColor
        needsDisplay = true
    }

    func move(by step: Int) {
        guard !rows.isEmpty else { return }
        selected = (selected + step + rows.count) % rows.count
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = Theme.terminalFont(family: Theme.settings.fontFamily, size: 13)
        let nameStyle: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.fg]
        let parentStyle: [NSAttributedString.Key: Any] = [.font: Theme.metaFont, .foregroundColor: Theme.fg3]
        let inner = bounds.width - Self.inset * 2
        for (index, row) in rows.enumerated() {
            let rect = NSRect(x: Self.inset, y: Self.inset + CGFloat(index) * Self.rowHeight, width: inner, height: Self.rowHeight)
            if index == selected {
                Theme.accent.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            }
            let name = NSAttributedString(string: row.name, attributes: nameStyle)
            let nameWidth = min(name.size().width, inner * 0.55)
            name.draw(with: NSRect(x: rect.minX + 8, y: rect.minY + 4, width: nameWidth, height: 18),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            let parentX = rect.minX + 8 + nameWidth + 10
            NSAttributedString(string: row.parent, attributes: parentStyle)
                .draw(with: NSRect(x: parentX, y: rect.minY + 6, width: rect.maxX - parentX - 8, height: 16),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        let hintY = Self.inset + CGFloat(rows.count) * Self.rowHeight + 3
        NSAttributedString(string: "⇥ go   ↑↓ choose   esc hide", attributes: parentStyle)
            .draw(at: NSPoint(x: Self.inset + 8, y: hintY))
    }
}
