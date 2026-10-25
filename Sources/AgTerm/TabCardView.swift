import AgTermCore
import AppKit

/// One tab, two lines:
///   ● Topic …………………………………………   (× on hover)
///     WORKING  folder  branch …… +12 −4
final class TabCardView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
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
    private var hovering = false { didSet { needsDisplay = true } }

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

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hovering, closeRect.insetBy(dx: -4, dy: -4).contains(point) {
            mouseDownX = nil
            onClose?()
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

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onClose?() }
    }

    private var rightEdge: CGFloat { bounds.maxX - Self.padX }
    private var closeRect: NSRect { NSRect(x: rightEdge - 14, y: Self.line1Y + 1, width: 14, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        guard let model else { return }
        drawBackground(model)
        drawDot(model.status, center: NSPoint(x: Self.padX + 4, y: Self.line1Y + 8))

        // Line 1: the topic gets the full width; the close button appears on hover.
        let topicRight = hovering ? closeRect.minX - Self.gap : rightEdge
        if hovering { drawClose() }
        let topicColor = model.selected ? Theme.fg : Theme.fg2
        draw(text(model.topic, Theme.topicFont, topicColor), x: Self.textX, y: Self.line1Y, maxX: topicRight)

        // Line 2: status, folder, the diff right after the folder, then the branch if it fits.
        // The diff never truncates; the folder gives way first.
        var x = Self.textX
        if let label = statusLabel(model.status) {
            label.draw(at: NSPoint(x: x, y: Self.line2Y + 1.5))
            x += ceil(label.size().width) + 8
        }
        let diff = diffText(model)
        let diffWidth = diff.map { ceil($0.size().width) + 8 } ?? 0
        let folder = text(model.folder, Theme.metaFont, Theme.fg3)
        let folderWidth = min(ceil(folder.size().width), max(0, rightEdge - x - diffWidth))
        draw(folder, x: x, y: Self.line2Y, maxX: x + folderWidth)
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

    private func drawDot(_ status: TabStatus, center: NSPoint) {
        let radius: CGFloat = 3.5
        let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        switch status {
        case .idle:
            Theme.fg4.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
            return
        case .working: (blinkOn ? Theme.accent : Theme.accentMuted).setFill()
        case .done: Theme.ok.setFill()
        case .waiting: Theme.fg.setFill()
        case .exited: Theme.fg4.setFill()
        }
        NSBezierPath(ovalIn: rect).fill()
    }

    private func drawClose() {
        let r = closeRect.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: r.minX, y: r.minY))
        path.line(to: NSPoint(x: r.maxX, y: r.maxY))
        path.move(to: NSPoint(x: r.maxX, y: r.minY))
        path.line(to: NSPoint(x: r.minX, y: r.maxY))
        path.lineWidth = 1.25
        Theme.fg2.setStroke()
        path.stroke()
    }

    /// Only states worth reading get a label; idle stays quiet.
    private func statusLabel(_ status: TabStatus) -> NSAttributedString? {
        let color: NSColor
        switch status {
        case .idle: return nil
        case .working: color = Theme.accent
        case .done: color = Theme.ok
        case .waiting: color = Theme.fg
        case .exited: color = Theme.fg3
        }
        return NSAttributedString(string: status.label.uppercased(), attributes: [
            .font: Theme.labelFont, .foregroundColor: color, .kern: 0.8,
        ])
    }

    /// Folder, plus the branch when both fit; the branch is dropped rather than cut to "m…".
    /// Agent tabs: lines changed since the agent started (shown even at +0 −0).
    /// Other tabs: the folder's uncommitted changes.
    private func diffText(_ model: TabModel) -> NSAttributedString? {
        if let agent = model.agentDiff { return lines(agent.added, agent.removed) }
        guard let git = model.git else { return nil }
        if git.added > 0 || git.removed > 0 { return lines(git.added, git.removed) }
        return git.files > 0 ? text("\(git.files) new", Theme.metaFont, Theme.fg3) : nil
    }

    private func lines(_ added: Int, _ removed: Int) -> NSAttributedString {
        let diff = text("+\(added)", Theme.metaFont, Theme.ok)
        diff.append(text(" −\(removed)", Theme.metaFont, Theme.danger))
        return diff
    }

    private func text(_ string: String, _ font: NSFont, _ color: NSColor) -> NSMutableAttributedString {
        NSMutableAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }

    /// Single line, truncated with an ellipsis at maxX.
    private func draw(_ string: NSAttributedString, x: CGFloat, y: CGFloat, maxX: CGFloat) {
        guard maxX - x > 12 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let styled = NSMutableAttributedString(attributedString: string)
        styled.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: styled.length))
        styled.draw(with: NSRect(x: x, y: y, width: maxX - x, height: 18),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
