import AgTermCore
import AppKit

/// What an empty pane shows after Split Right or Split Down: a list to choose which tab goes
/// there, or a new shell. Clicking a tab in the sidebar or tab bar chooses it too; Esc cancels.
final class PanePickerView: NSView {
    struct Choice: Equatable {
        /// Nil for a new shell.
        var tabID: String?
        var title: String
        var detail: String
        var logo: NSImage?
    }

    var choices: [Choice] = [] { didSet { hovered = nil; needsDisplay = true } }
    var onChoose: ((Choice) -> Void)?
    var onCancel: (() -> Void)?
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    private static let rowHeight: CGFloat = 40
    private static let width: CGFloat = 340
    private static let headerHeight: CGFloat = 34

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The list, centered in the pane.
    private var listRect: NSRect {
        let height = Self.headerHeight + CGFloat(choices.count) * Self.rowHeight
        let width = min(Self.width, bounds.width - 24)
        return NSRect(x: (bounds.width - width) / 2, y: max(12, (bounds.height - height) / 2), width: width, height: height)
    }

    private func rowRect(_ index: Int) -> NSRect {
        let list = listRect
        return NSRect(x: list.minX, y: list.minY + Self.headerHeight + CGFloat(index) * Self.rowHeight, width: list.width, height: Self.rowHeight)
    }

    private func row(at point: NSPoint) -> Int? {
        choices.indices.first { rowRect($0).contains(point) }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { hovered = row(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let index = row(at: convert(event.locationInWindow, from: nil)) { onChoose?(choices[index]) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?() // Esc
        case 125: hovered = min((hovered ?? -1) + 1, choices.count - 1) // ↓
        case 126: hovered = max((hovered ?? choices.count) - 1, 0) // ↑
        case 36, 76: if let hovered { onChoose?(choices[hovered]) } // Return
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg.setFill()
        bounds.fill()
        let list = listRect
        TabCardDrawing.draw(TabCardDrawing.text("Show in this pane", Theme.topicFont, Theme.fg2), x: list.minX + 12, y: list.minY + 6, maxX: list.maxX)
        TabCardDrawing.draw(TabCardDrawing.text("esc", Theme.metaFont, Theme.fg4), x: list.maxX - 34, y: list.minY + 8, maxX: list.maxX)
        for (i, choice) in choices.enumerated() {
            let rect = rowRect(i)
            if i == hovered {
                Theme.surfaceHover.setFill()
                NSBezierPath(roundedRect: rect, xRadius: TabCardView.radius, yRadius: TabCardView.radius).fill()
            }
            var x = rect.minX + 12
            if let logo = choice.logo {
                logo.draw(in: NSRect(x: x, y: rect.minY + 12, width: 16, height: 16), from: .zero, operation: .sourceOver,
                          fraction: 1, respectFlipped: true, hints: nil)
            } else if choice.tabID == nil {
                Theme.fg3.setFill()
                NSRect(x: x + 3, y: rect.midY - 0.5, width: 10, height: 1).fill()
                NSRect(x: x + 7.5, y: rect.midY - 5, width: 1, height: 10).fill()
            }
            x += 26
            TabCardDrawing.draw(TabCardDrawing.text(choice.title, Theme.topicFont, Theme.fg), x: x, y: rect.minY + 3, maxX: rect.maxX - 12)
            TabCardDrawing.draw(TabCardDrawing.text(choice.detail, Theme.metaFont, Theme.fg3), x: x, y: rect.minY + 21, maxX: rect.maxX - 12)
        }
    }
}
