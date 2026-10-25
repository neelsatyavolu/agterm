import AgTermCore
import AppKit

/// One tab, two lines:
///   ● Topic …………………………………………   (× on hover)
///     WORKING  folder  branch …… +12 −4
final class TabCardView: NSView {
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
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

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hovering, closeRect.insetBy(dx: -4, dy: -4).contains(point) { onClose?() } else { onSelect?() }
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

        // Line 2: status word, folder, branch; diff pinned right so it never truncates.
        var x = Self.textX
        if let label = statusLabel(model.status) {
            label.draw(at: NSPoint(x: x, y: Self.line2Y + 1.5))
            x += ceil(label.size().width) + 8
        }
        var metaRight = rightEdge
        if let diff = diffText(model.git) {
            let width = ceil(diff.size().width)
            diff.draw(at: NSPoint(x: rightEdge - width, y: Self.line2Y))
            metaRight = rightEdge - width - Self.gap
        }
        draw(location(model, width: metaRight - x), x: x, y: Self.line2Y, maxX: metaRight)
    }

    private func drawBackground(_ model: TabModel) {
        if model.selected {
            Theme.bg.setFill()
            bounds.fill()
            Theme.accent.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
            return
        }
        if hovering {
            Theme.surfaceHover.setFill()
            bounds.fill()
        }
        Theme.border.setFill()
        NSRect(x: bounds.maxX - 1, y: 12, width: 1, height: bounds.height - 24).fill()
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
    private func location(_ model: TabModel, width: CGFloat) -> NSAttributedString {
        let folder = text(model.folder, Theme.metaFont, Theme.fg3)
        guard let branch = model.git?.branch else { return folder }
        let full = NSMutableAttributedString(attributedString: folder)
        full.append(text("  \(branch)", Theme.metaFont, Theme.fg4))
        return full.size().width <= width ? full : folder
    }

    private func diffText(_ git: GitSummary?) -> NSAttributedString? {
        guard let git else { return nil }
        if git.added > 0 || git.removed > 0 {
            let diff = text("+\(git.added)", Theme.metaFont, Theme.ok)
            diff.append(text(" −\(git.removed)", Theme.metaFont, Theme.danger))
            return diff
        }
        return git.files > 0 ? text("\(git.files) new", Theme.metaFont, Theme.fg3) : nil
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
