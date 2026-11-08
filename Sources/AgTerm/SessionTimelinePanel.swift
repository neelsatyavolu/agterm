import AgTermCore
import AppKit

/// The Session Timeline: every prompt sent in the tab, newest first, with how it went and when.
/// Click one (or pick it with ↑↓ and ⏎) to scroll the terminal to it. Esc closes.
final class SessionTimelinePanel: NSView {
    static let width: CGFloat = 360
    private static let headerHeight: CGFloat = 34
    private static let maxListHeight: CGFloat = 320

    var onSelect: ((SessionTimelineTurn) -> Void)?
    var onClose: (() -> Void)?

    private let title = NSTextField(labelWithString: "Session timeline")
    private let count = NSTextField(labelWithString: "")
    private let hairline = NSView()
    private let scroll = NSScrollView()
    private let list = SessionTimelineList()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        self.shadow = shadow
        title.font = .systemFont(ofSize: 12, weight: .medium)
        count.font = Theme.metaFont
        count.alignment = .right
        hairline.wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        list.onSelect = { [weak self] turn in self?.onSelect?(turn) }
        [title, count, hairline, scroll].forEach(addSubview)
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Shows `turns` (newest first), or `empty` when there are none. `note` replaces the count,
    /// e.g. when a turn couldn't be found.
    func show(_ turns: [SessionTimelineTurn], empty: String, note: String? = nil) {
        list.empty = empty
        list.turns = turns
        let noun = turns.first?.id.hasPrefix("shell-") == true ? "command" : "turn"
        count.stringValue = note ?? (turns.isEmpty ? "" : "\(turns.count) \(noun)\(turns.count == 1 ? "" : "s")")
        count.textColor = note == nil ? Theme.fg3 : Theme.danger
        refreshAppearance()
        needsLayout = true
    }

    /// The panel's height for what it shows.
    var preferredHeight: CGFloat {
        Self.headerHeight + 1 + min(Self.maxListHeight, list.contentHeight(width: Self.width))
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = NSRect(x: 12, y: 10, width: 160, height: 16)
        count.frame = NSRect(x: w - 12 - 180, y: 10, width: 180, height: 16)
        hairline.frame = NSRect(x: 0, y: Self.headerHeight, width: w, height: 1)
        scroll.frame = NSRect(x: 0, y: Self.headerHeight + 1, width: w, height: bounds.height - Self.headerHeight - 1)
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, list.contentHeight(width: w)))
    }

    func refreshAppearance() {
        layer?.backgroundColor = Theme.color(Theme.palette.chrome).cgColor
        layer?.borderColor = Theme.border.cgColor
        hairline.layer?.backgroundColor = Theme.border.cgColor
        title.textColor = Theme.fg2
        list.needsDisplay = true
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onClose?() // esc
        case 125: list.moveSelection(by: 1) // ↓
        case 126: list.moveSelection(by: -1) // ↑
        case 36, 76: // ⏎
            if let turn = list.selectedTurn { onSelect?(turn) }
        default: super.keyDown(with: event)
        }
    }

    #if DEBUG
    var turnsForTest: [SessionTimelineTurn] { list.turns }
    #endif
}

/// The rows, drawn rather than built from controls so they follow the theme exactly.
private final class SessionTimelineList: NSView {
    private static let promptFont = NSFont.systemFont(ofSize: 12.5)
    private static let chipFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private static let inset: CGFloat = 12
    /// Dot, then the text.
    private static let textX: CGFloat = 28
    private static let timeWidth: CGFloat = 36

    var onSelect: ((SessionTimelineTurn) -> Void)?
    var turns: [SessionTimelineTurn] = [] {
        didSet {
            if turns.map(\.id) != oldValue.map(\.id) { selected = nil }
            needsDisplay = true
        }
    }
    var empty = ""
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var selected: Int? { didSet { if selected != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    var selectedTurn: SessionTimelineTurn? { selected.flatMap { turns.indices.contains($0) ? turns[$0] : nil } }

    func moveSelection(by step: Int) {
        guard !turns.isEmpty else { return }
        let next = selected.map { $0 + step } ?? (step > 0 ? 0 : turns.count - 1)
        selected = min(max(0, next), turns.count - 1)
        if let selected { scrollToVisible(rowRect(selected)) }
    }

    func contentHeight(width: CGFloat) -> CGFloat {
        turns.isEmpty ? 64 : (0..<turns.count).reduce(0) { $0 + rowHeight($1, width: width) }
    }

    private func promptHeight(_ index: Int, width: CGFloat) -> CGFloat {
        let text = attributedPrompt(index)
        let box = text.boundingRect(with: NSSize(width: width - Self.textX - Self.timeWidth - Self.inset, height: 34),
                                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return min(34, ceil(box.height))
    }

    private func rowHeight(_ index: Int, width: CGFloat) -> CGFloat { 10 + promptHeight(index, width: width) + 6 + 16 + 10 }

    private func rowRect(_ index: Int) -> NSRect {
        let y = (0..<index).reduce(CGFloat(0)) { $0 + rowHeight($1, width: bounds.width) }
        return NSRect(x: 0, y: y, width: bounds.width, height: rowHeight(index, width: bounds.width))
    }

    private func row(at point: NSPoint) -> Int? {
        var y: CGFloat = 0
        for index in turns.indices {
            y += rowHeight(index, width: bounds.width)
            if point.y < y { return index }
        }
        return nil
    }

    private func attributedPrompt(_ index: Int) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        let text = SessionTimelineFormat.oneLine(turns[index].prompt)
        return NSAttributedString(string: text.isEmpty ? "(prompt)" : text,
                                  attributes: [.font: Self.promptFont, .foregroundColor: Theme.fg, .paragraphStyle: style])
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !turns.isEmpty else {
            let text = NSAttributedString(string: empty, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.fg3])
            let size = text.size()
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: 24))
            return
        }
        var y: CGFloat = 0
        for index in turns.indices {
            let height = rowHeight(index, width: bounds.width)
            let rect = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
            guard rect.intersects(dirtyRect) else { continue }
            drawRow(index, in: rect)
        }
    }

    private func drawRow(_ index: Int, in rect: NSRect) {
        let turn = turns[index]
        if index == hovered || index == selected {
            Theme.surfaceHover.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        if index < turns.count - 1 {
            Theme.border.withAlphaComponent(0.5).setFill()
            NSRect(x: Self.inset, y: rect.maxY - 1, width: rect.width - Self.inset * 2, height: 1).fill()
        }
        let colors = Self.colors(turn.status)
        colors.dot.setFill()
        NSBezierPath(ovalIn: NSRect(x: Self.inset + 2, y: rect.minY + 15, width: 6, height: 6)).fill()

        let promptWidth = rect.width - Self.textX - Self.timeWidth - Self.inset
        let promptHeight = promptHeight(index, width: rect.width)
        attributedPrompt(index).draw(with: NSRect(x: Self.textX, y: rect.minY + 10, width: promptWidth, height: promptHeight),
                                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let time = NSAttributedString(string: SessionTimelineFormat.relative(turn.startedAt),
                                      attributes: [.font: Theme.metaFont, .foregroundColor: Theme.fg3])
        time.draw(at: NSPoint(x: rect.maxX - Self.inset - time.size().width, y: rect.minY + 10))

        let label = NSAttributedString(string: turn.status.rawValue, attributes: [.font: Self.chipFont, .foregroundColor: colors.text])
        let chip = NSRect(x: Self.textX, y: rect.minY + 10 + promptHeight + 6, width: ceil(label.size().width) + 12, height: 16)
        let path = NSBezierPath(roundedRect: chip.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        colors.fill.setFill()
        path.fill()
        colors.border.setStroke()
        path.lineWidth = 1
        path.stroke()
        label.draw(at: NSPoint(x: chip.minX + 6, y: chip.minY + (16 - label.size().height) / 2))
    }

    /// agmux's chips: running in the accent, failed in red, the rest quiet.
    private static func colors(_ status: SessionTimelineTurn.Status) -> (dot: NSColor, text: NSColor, fill: NSColor, border: NSColor) {
        switch status {
        case .running: (Theme.accent, Theme.accent, Theme.accent.withAlphaComponent(0.12), Theme.accent.withAlphaComponent(0.35))
        case .failed: (Theme.danger, Theme.danger, Theme.danger.withAlphaComponent(0.12), Theme.danger.withAlphaComponent(0.3))
        case .cancelled: (Theme.fg4, Theme.fg3, Theme.surface, Theme.border)
        case .done: (Theme.fg4, Theme.fg2, Theme.surface, Theme.border)
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = row(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }
    override func mouseDown(with event: NSEvent) {
        guard let index = row(at: convert(event.locationInWindow, from: nil)) else { return }
        selected = index
        onSelect?(turns[index])
    }
}
