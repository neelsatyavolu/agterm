import AgTermCore
import AppKit

/// Drawing shared by the tab bar's cards and the sidebar's.
enum TabCardDrawing {
    static func dot(_ status: TabStatus, center: NSPoint, blinkOn: Bool) {
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

    static func close(in rect: NSRect) {
        let r = rect.insetBy(dx: 3, dy: 3)
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
    static func statusLabel(_ status: TabStatus) -> NSAttributedString? {
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

    /// Agent tabs: lines changed since the agent started (shown even at +0 −0).
    /// Other tabs: the folder's uncommitted changes.
    static func diffText(_ model: TabModel) -> NSAttributedString? {
        if let agent = model.agentDiff { return lines(agent.added, agent.removed) }
        guard let git = model.git else { return nil }
        if git.added > 0 || git.removed > 0 { return lines(git.added, git.removed) }
        return git.files > 0 ? text("\(git.files) new", Theme.metaFont, Theme.fg3) : nil
    }

    static func lines(_ added: Int, _ removed: Int) -> NSAttributedString {
        let diff = text("+\(added)", Theme.metaFont, Theme.ok)
        diff.append(text(" −\(removed)", Theme.metaFont, Theme.danger))
        return diff
    }

    /// The cloud mark before a cloud tab's folder, in the accent color.
    static func cloud() -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "In the cloud")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)) else { return nil }
        return NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            Theme.accent.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    static func text(_ string: String, _ font: NSFont, _ color: NSColor) -> NSMutableAttributedString {
        NSMutableAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
    }

    /// Single line, truncated with an ellipsis at maxX.
    static func draw(_ string: NSAttributedString, x: CGFloat, y: CGFloat, maxX: CGFloat) {
        guard maxX - x > 12 else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let styled = NSMutableAttributedString(attributedString: string)
        styled.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: styled.length))
        styled.draw(with: NSRect(x: x, y: y, width: maxX - x, height: 18),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
