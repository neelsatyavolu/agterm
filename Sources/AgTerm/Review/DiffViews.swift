import AgTermCore
import AppKit

/// The changed files: name, folder and line counts. Draws only the rows on screen.
final class DiffFileListView: NSView {
    static let rowHeight: CGFloat = 26
    var files: [FileChange] = [] {
        didSet {
            hovered = nil
            resize()
            needsDisplay = true
        }
    }
    var selected: Int? { didSet { if selected != oldValue { needsDisplay = true; revealSelection() } } }
    var onSelect: ((Int) -> Void)?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func resize() {
        let width = enclosingScrollView?.contentSize.width ?? bounds.width
        setFrameSize(NSSize(width: width, height: max(CGFloat(files.count) * Self.rowHeight, enclosingScrollView?.contentSize.height ?? 0)))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = row(at: event) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let index = row(at: event) else { return }
        choose(index)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: choose(min((selected ?? -1) + 1, files.count - 1))
        case 126: choose(max((selected ?? files.count) - 1, 0))
        default: super.keyDown(with: event)
        }
    }

    private func choose(_ index: Int) {
        guard files.indices.contains(index) else { return }
        selected = index
        onSelect?(index)
    }

    private func row(at event: NSEvent) -> Int? {
        let index = Int(convert(event.locationInWindow, from: nil).y / Self.rowHeight)
        return files.indices.contains(index) ? index : nil
    }

    private func revealSelection() {
        guard let selected else { return }
        scrollToVisible(NSRect(x: 0, y: CGFloat(selected) * Self.rowHeight, width: 1, height: Self.rowHeight))
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg.setFill()
        dirtyRect.fill()
        guard !files.isEmpty else { return }
        let first = max(0, Int(dirtyRect.minY / Self.rowHeight))
        let last = min(files.count - 1, Int(dirtyRect.maxY / Self.rowHeight))
        guard first <= last else { return }
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.fg]
        let dirAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.fg3]
        for index in first...last {
            let rect = NSRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
            if index == selected || index == hovered {
                (index == selected ? Theme.surfaceHover : Theme.surface).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 1), xRadius: 6, yRadius: 6).fill()
            }
            let file = files[index]
            let counts = Self.counts(file)
            let countsWidth = ceil(counts.size().width)
            counts.draw(at: NSPoint(x: rect.maxX - 14 - countsWidth, y: rect.minY + 6))
            let name = (file.path as NSString).lastPathComponent
            let dir = (file.path as NSString).deletingLastPathComponent
            let text = NSMutableAttributedString(string: name, attributes: nameAttrs)
            if !dir.isEmpty { text.append(NSAttributedString(string: "  " + dir, attributes: dirAttrs)) }
            if file.untracked { text.append(NSAttributedString(string: "  new", attributes: dirAttrs)) }
            let room = NSRect(x: 14, y: rect.minY + 5, width: max(0, rect.width - 40 - countsWidth), height: 17)
            text.draw(with: room, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private static func counts(_ file: FileChange) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        if file.binary { return NSAttributedString(string: "binary", attributes: [.font: font, .foregroundColor: Theme.fg3]) }
        let text = NSMutableAttributedString()
        if file.added > 0 || file.removed == 0 { text.append(NSAttributedString(string: "+\(file.added)", attributes: [.font: font, .foregroundColor: Theme.ok])) }
        if file.removed > 0 {
            text.append(NSAttributedString(string: (text.length > 0 ? " " : "") + "−\(file.removed)", attributes: [.font: font, .foregroundColor: Theme.danger]))
        }
        return text
    }
}

/// One file's diff: line numbers, tinted added and removed rows, no wrapping. Draws only the
/// rows on screen, so a long diff costs nothing until you scroll to it.
final class DiffLinesView: NSView {
    var document: DiffDocument? {
        didSet {
            longest = (document?.lines.lazy.map { $0.text.count }.max() ?? 0)
            resize()
            needsDisplay = true
        }
    }
    /// The file's path, for Copy Path.
    var path: String?
    private var longest = 0
    private var font = DiffLinesView.makeFont()
    private var lineHeight: CGFloat = 16
    private var charWidth: CGFloat = 7
    private static let maxColumns = 600

    override var isFlipped: Bool { true }

    private static func makeFont() -> NSFont {
        Theme.terminalFont(family: Theme.settings.fontFamily, size: max(10, min(CGFloat(Theme.settings.fontSize) - 1, 13)))
    }

    func refreshAppearance() {
        font = Self.makeFont()
        resize()
        needsDisplay = true
    }

    private var gutter: CGFloat { charWidth * 10 + 16 }

    func resize() {
        let sample = NSAttributedString(string: "M", attributes: [.font: font])
        charWidth = ceil(sample.size().width * 100) / 100
        lineHeight = ceil(font.ascender - font.descender + font.leading) + 4
        let visible = enclosingScrollView?.contentSize ?? bounds.size
        let rows = CGFloat(document?.lines.count ?? 0) + (document?.truncated == true ? 1 : 0)
        let width = gutter + CGFloat(min(longest, Self.maxColumns) + 2) * charWidth
        setFrameSize(NSSize(width: max(visible.width, width), height: max(visible.height, rows * lineHeight + 8)))
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg.setFill()
        dirtyRect.fill()
        guard let lines = document?.lines else { return }
        let rows = lines.count + (document?.truncated == true ? 1 : 0)
        guard rows > 0 else { return }
        let first = max(0, Int((dirtyRect.minY - 4) / lineHeight))
        let last = min(rows - 1, Int((dirtyRect.maxY - 4) / lineHeight))
        guard first <= last else { return }
        let numberAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.fg4]
        for index in first...last {
            let y = 4 + CGFloat(index) * lineHeight
            let rect = NSRect(x: dirtyRect.minX, y: y, width: dirtyRect.width, height: lineHeight)
            guard index < lines.count else {
                draw("Diff cut at \(lines.count) lines", at: y, x: gutter, color: Theme.fg3)
                continue
            }
            let line = lines[index]
            if let tint = Self.tint(line.kind) {
                tint.setFill()
                rect.fill()
            }
            if let old = line.old { NSAttributedString(string: String(old), attributes: numberAttrs).draw(at: NSPoint(x: 8, y: y + 2)) }
            if let new = line.new { NSAttributedString(string: String(new), attributes: numberAttrs).draw(at: NSPoint(x: 8 + charWidth * 5, y: y + 2)) }
            switch line.kind {
            case .added: draw("+", at: y, x: gutter - charWidth - 4, color: Theme.ok)
            case .removed: draw("−", at: y, x: gutter - charWidth - 4, color: Theme.danger)
            case .hunk, .note, .context: break
            }
            let text = String(line.text.replacingOccurrences(of: "\t", with: "    ").prefix(Self.maxColumns))
            draw(text, at: y, x: gutter, color: line.kind == .hunk || line.kind == .note ? Theme.fg3 : Theme.fg)
        }
    }

    private func draw(_ text: String, at y: CGFloat, x: CGFloat, color: NSColor) {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]).draw(at: NSPoint(x: x, y: y + 2))
    }

    private static func tint(_ kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .added: Theme.ok.withAlphaComponent(0.13)
        case .removed: Theme.danger.withAlphaComponent(0.13)
        case .hunk: Theme.surface
        case .context, .note: nil
        }
    }

    // MARK: Copying

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Diff", action: #selector(copyDiff), keyEquivalent: "").target = self
        if path != nil { menu.addItem(withTitle: "Copy Path", action: #selector(copyPath), keyEquivalent: "").target = self }
        return menu
    }

    @objc private func copyDiff() {
        guard let lines = document?.lines else { return }
        let text = lines.map { line -> String in
            switch line.kind {
            case .added: "+" + line.text
            case .removed: "-" + line.text
            case .context: " " + line.text
            case .hunk, .note: line.text
            }
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func copyPath() {
        guard let path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
