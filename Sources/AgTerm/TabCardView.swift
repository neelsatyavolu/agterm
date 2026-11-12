import AgTermCore
import AppKit

/// One tab, two lines:
///   ● Topic …………………………………………   (× on hover)
///     WORKING  folder  branch …… +12 −4
final class TabCardView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// Right-click or control-click: the tab's menu.
    var onMenu: ((NSEvent) -> Void)?
    /// The globe: the agent's Perch tabs.
    var onBrowser: (() -> Void)?
    private var browserRect: NSRect?
    /// Dragging sideways reorders tabs; the bar moves the card while the mouse is down.
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    private var mouseDownX: CGFloat?
    private var dragging = false
    var model: TabModel? {
        didSet { if model != oldValue { needsDisplay = true } }
    }
    var blinkOn = true {
        didSet { if blinkOn != oldValue, model?.status == .working { needsDisplay = true } }
    }
    private var mouseInside = false { didSet { if mouseInside != oldValue { needsDisplay = true } } }
    /// Set by the bar while any tab is being dragged, so cards passing under the mouse
    /// don't light up as if hovered.
    var reordering = false { didSet { if reordering != oldValue { needsDisplay = true } } }
    private var hovering: Bool { mouseInside && !reordering }

    private static let padX: CGFloat = 14
    private static let textX: CGFloat = 30
    private static let line1Y: CGFloat = 10
    private static let line2Y: CGFloat = 29
    private static let gap: CGFloat = 10

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// A tab works on the first click, even in a window in the background, like Safari's:
    /// otherwise that click only brings the window forward and a drag moves the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { mouseInside = true }
    override func mouseExited(with event: NSEvent) { mouseInside = false }

    /// Enter and exit events only come when the mouse moves, not when the card slides under
    /// a still mouse, so the bar calls this once cards settle after a drag.
    func syncHover() {
        guard let window else { return }
        mouseInside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            mouseDownX = nil
            return rightMouseDown(with: event)
        }
        let point = convert(event.locationInWindow, from: nil)
        if hovering, closeRect.insetBy(dx: -4, dy: -4).contains(point) {
            mouseDownX = nil
            onClose?()
        } else if let browserRect, browserRect.insetBy(dx: -3, dy: -3).contains(point) {
            mouseDownX = nil
            onBrowser?()
        } else {
            mouseDownX = event.locationInWindow.x
            onSelect?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownX else { return }
        let dx = event.locationInWindow.x - start
        if !dragging, abs(dx) > 4 {
            dragging = true
            onDragBegan?()
        }
        if dragging { onDragMoved?(dx) }
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownX = nil
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
    private var closeRect: NSRect { NSRect(x: rightEdge - 14, y: Self.line1Y + 1, width: 14, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        drawBackground(model)
        TabCardDrawing.dot(model.status, center: NSPoint(x: Self.padX + 4, y: Self.line1Y + 8), blinkOn: blinkOn)

        // Line 1: the topic gets the full width; the close button appears on hover.
        let topicRight = hovering ? closeRect.minX - Self.gap : rightEdge
        if hovering { TabCardDrawing.close(in: closeRect) }
        let topicColor = model.selected ? Theme.fg : Theme.fg2
        TabCardDrawing.draw(text(model.topic, Theme.topicFont, topicColor), x: Self.textX, y: Self.line1Y, maxX: topicRight)

        // Line 2: status, folder, the diff right after the folder, then the branch if it fits.
        // The diff never truncates; the folder gives way first.
        var x = Self.textX
        if let label = TabCardDrawing.statusLabel(model.status) {
            label.draw(at: NSPoint(x: x, y: Self.line2Y + 1.5))
            x += ceil(label.size().width) + 8
        }
        browserRect = model.moving == nil ? TabCardDrawing.browser(model.browserTabs, x: x, y: Self.line2Y) : nil
        if let browserRect { x = browserRect.maxX + 8 }
        if model.inCloud || model.moving != nil, let cloud = TabCardDrawing.cloud() {
            // A cloud before the folder: this tab's shell runs on the cloud machine.
            cloud.draw(in: NSRect(x: x, y: Self.line2Y + 1, width: cloud.size.width, height: cloud.size.height))
            x += ceil(cloud.size.width) + 5
        }
        if let moving = model.moving {
            if let share = model.movingProgress {
                // Across the foot of the card, where the selected tab's accent line runs.
                let track = NSRect(x: Self.padX, y: 5, width: bounds.width - 2 * Self.padX, height: 2)
                Theme.fg4.withAlphaComponent(0.35).setFill()
                track.fill()
                Theme.accent.setFill()
                NSRect(x: track.minX, y: track.minY, width: track.width * min(1, max(0, share)), height: track.height).fill()
            }
            return TabCardDrawing.draw(text(moving, Theme.metaFont, Theme.accent), x: x, y: Self.line2Y, maxX: rightEdge)
        }
        let diff = TabCardDrawing.diffText(model)
        let diffWidth = diff.map { ceil($0.size().width) + 8 } ?? 0
        let folder = text(model.folder, Theme.metaFont, Theme.fg3)
        let folderWidth = min(ceil(folder.size().width), max(0, rightEdge - x - diffWidth))
        TabCardDrawing.draw(folder, x: x, y: Self.line2Y, maxX: x + folderWidth)
        x += folderWidth
        if let diff {
            diff.draw(at: NSPoint(x: x + 8, y: Self.line2Y))
            x += diffWidth
        }
        if let branch = model.git?.branch {
            let label = text(branch, Theme.metaFont, Theme.fg4)
            if x + 10 + ceil(label.size().width) <= rightEdge { label.draw(at: NSPoint(x: x + 10, y: Self.line2Y)) }
        }
    }

    private func drawBackground(_ model: TabModel) {
        if model.selected {
            // Rounded on top, square at the bottom where it joins the terminal.
            let shape = Self.topRoundedRect(bounds.insetBy(dx: 2, dy: 0).offsetBy(dx: 0, dy: 5), radius: Self.radius)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            Theme.bg.setFill()
            bounds.fill()
            Theme.accent.setFill()
            NSRect(x: 0, y: 5, width: bounds.width, height: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        if hovering {
            Theme.surfaceHover.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 6), xRadius: Self.radius, yRadius: Self.radius).fill()
        }
        Theme.border.setFill()
        NSRect(x: bounds.maxX - 1, y: 12, width: 1, height: bounds.height - 24).fill()
    }

    static let radius: CGFloat = 8

    /// A rect with rounded top corners in this flipped view (y grows downward).
    private static func topRoundedRect(_ r: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.minX, y: r.maxY))
        path.line(to: NSPoint(x: r.minX, y: r.minY + radius))
        path.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.minY + radius), radius: radius, startAngle: 180, endAngle: 270)
        path.line(to: NSPoint(x: r.maxX - radius, y: r.minY))
        path.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius, startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: r.maxX, y: r.maxY))
        path.close()
        return path
    }

    private func text(_ string: String, _ font: NSFont, _ color: NSColor) -> NSMutableAttributedString {
        TabCardDrawing.text(string, font, color)
    }
}
