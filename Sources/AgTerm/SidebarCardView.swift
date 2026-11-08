import AgTermCore
import AppKit

/// One tab in the sidebar, up to four lines:
///   ● Topic …………………………………   (× on hover)
///     WORKING  Claude Code · Opus 4.5
///     folder  branch ………… +12 −4
///     $1.24 · 38k tokens · 12m · 2 panes
final class SidebarCardView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    /// Dragging up or down reorders tabs; the sidebar moves the card while the mouse is down.
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var mouseDownY: CGFloat?
    private var dragging = false
    var model: TabModel? {
        didSet { if model != oldValue { needsDisplay = true } }
    }
    var blinkOn = true {
        didSet { if blinkOn != oldValue, model?.status == .working { needsDisplay = true } }
    }
    private var mouseInside = false { didSet { if mouseInside != oldValue { needsDisplay = true } } }
    var reordering = false { didSet { if reordering != oldValue { needsDisplay = true } } }
    private var hovering: Bool { mouseInside && !reordering }

    private static let padX: CGFloat = 12
    private static let textX: CGFloat = 28
    private static let topY: CGFloat = 9
    private static let topicHeight: CGFloat = 19
    private static let lineHeight: CGFloat = 17
    private static let bottomPad: CGFloat = 9

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The card's height for `model`: the topic, plus a line for each detail it has.
    static func height(for model: TabModel) -> CGFloat {
        let lines = (detailLine(model) ? 1 : 0) + (folderLine(model) ? 1 : 0) + (metaLine(model, now: Date()) == nil ? 0 : 1)
        return topY + topicHeight + CGFloat(lines) * lineHeight + bottomPad
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { mouseInside = true }
    override func mouseExited(with event: NSEvent) { mouseInside = false }

    func syncHover() {
        guard let window else { return }
        mouseInside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            mouseDownY = nil
            return rightMouseDown(with: event)
        }
        let point = convert(event.locationInWindow, from: nil)
        if hovering, closeRect.insetBy(dx: -4, dy: -4).contains(point) {
            mouseDownY = nil
            onClose?()
        } else {
            mouseDownY = event.locationInWindow.y
            onSelect?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownY else { return }
        // Window coordinates grow upward; the list grows downward.
        let dy = start - event.locationInWindow.y
        if !dragging, abs(dy) > 4 {
            dragging = true
            onDragBegan?()
        }
        if dragging { onDragMoved?(dy) }
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownY = nil
        if dragging {
            dragging = false
            onDragEnded?()
        }
    }

    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }

    private var rightEdge: CGFloat { bounds.maxX - Self.padX }
    private var closeRect: NSRect { NSRect(x: rightEdge - 14, y: Self.topY + 2, width: 14, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        drawBackground(model)
        TabCardDrawing.dot(model.status, center: NSPoint(x: Self.padX + 4, y: Self.topY + 9), blinkOn: blinkOn)
        if hovering { TabCardDrawing.close(in: closeRect) }
        let topicRight = hovering ? closeRect.minX - 8 : rightEdge
        TabCardDrawing.draw(TabCardDrawing.text(model.topic, Theme.topicFont, model.selected ? Theme.fg : Theme.fg2),
                            x: Self.textX, y: Self.topY, maxX: topicRight)
        var y = Self.topY + Self.topicHeight
        if Self.detailLine(model) {
            drawDetail(model, y: y)
            y += Self.lineHeight
        }
        if Self.folderLine(model) {
            drawFolder(model, y: y)
            y += Self.lineHeight
        }
        if let meta = Self.metaLine(model, now: Date()) {
            TabCardDrawing.draw(TabCardDrawing.text(meta, Theme.metaFont, Theme.fg3), x: Self.textX, y: y, maxX: rightEdge)
        }
    }

    private func drawBackground(_ model: TabModel) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: TabCardView.radius, yRadius: TabCardView.radius)
        if model.selected {
            Theme.bg.setFill()
            shape.fill()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            Theme.accent.setFill()
            NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else if hovering {
            Theme.surfaceHover.setFill()
            shape.fill()
        }
    }

    /// Status, then the agent and its model, or the program running in a plain shell.
    private static func detailLine(_ model: TabModel) -> Bool {
        model.moving != nil || TabCardDrawing.statusLabel(model.status) != nil || model.agent != nil || model.program != nil
    }

    private func drawDetail(_ model: TabModel, y: CGFloat) {
        var x = Self.textX
        if let label = TabCardDrawing.statusLabel(model.status) {
            label.draw(at: NSPoint(x: x, y: y + 2))
            x += ceil(label.size().width) + 8
        }
        if let moving = model.moving {
            return TabCardDrawing.draw(TabCardDrawing.text(moving, Theme.metaFont, Theme.accent), x: x, y: y, maxX: rightEdge)
        }
        let line = NSMutableAttributedString()
        if let agent = model.agent ?? model.program {
            line.append(TabCardDrawing.text(agent, Theme.metaFont, Theme.fg2))
        }
        if let name = model.model {
            line.append(TabCardDrawing.text(" · " + name, Theme.metaFont, Theme.fg3))
        }
        TabCardDrawing.draw(line, x: x, y: y, maxX: rightEdge)
    }

    /// Home shows no folder name; the line is left out when it would be empty.
    private static func folderLine(_ model: TabModel) -> Bool {
        !model.folder.isEmpty || model.git?.branch != nil || TabCardDrawing.diffText(model) != nil || model.inCloud || model.moving != nil
    }

    /// Folder and branch on the left, the diff right-aligned; the branch gives way first, then the folder.
    private func drawFolder(_ model: TabModel, y: CGFloat) {
        var x = Self.textX
        if model.inCloud || model.moving != nil, let cloud = TabCardDrawing.cloud() {
            cloud.draw(in: NSRect(x: x, y: y + 1, width: cloud.size.width, height: cloud.size.height))
            x += ceil(cloud.size.width) + 5
        }
        var right = rightEdge
        if let diff = TabCardDrawing.diffText(model) {
            let width = ceil(diff.size().width)
            diff.draw(at: NSPoint(x: right - width, y: y))
            right -= width + 10
        }
        let folder = TabCardDrawing.text(model.folder, Theme.metaFont, Theme.fg3)
        let folderWidth = min(ceil(folder.size().width), max(0, right - x))
        // Up to `right`, not just the folder's width: a short one like "~" is narrower than `draw` will draw.
        TabCardDrawing.draw(folder, x: x, y: y, maxX: right)
        x += folderWidth
        if let branch = model.git?.branch {
            let label = TabCardDrawing.text(branch, Theme.metaFont, Theme.fg4)
            if x + 8 + ceil(label.size().width) <= right { label.draw(at: NSPoint(x: x + 8, y: y)) }
        }
    }

    /// Spend, how long the agent has run, and the pane count, when there's any of them.
    private static func metaLine(_ model: TabModel, now: Date) -> String? {
        let parts = [model.usage, model.agentSince.map { UsageText.elapsed(now.timeIntervalSince($0)) },
                     model.panes > 1 ? "\(model.panes) panes" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
