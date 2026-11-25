import AgTermCore
import AppKit

/// What the line under the composer shows, like an agent's own status line: the model, how full
/// its context is, what the session cost, its effort and your plan's usage limits.
struct ChatComposerInfo: Equatable {
    struct Limit: Equatable {
        var name: String
        var percent: Double
    }

    var model: String?
    var effort: String?
    var context: ContextUse?
    var tokens: Int?
    var cost: String?
    var limits: [Limit] = []
}

/// A small control in the composer's toolbar: the model and effort, the permission mode, `/`, `@`.
final class ChatChip: NSButton {
    enum Tone { case plain, danger, warn, accent }

    var tone = Tone.plain { didSet { needsDisplay = true } }
    private var hovering = false

    convenience init(_ title: String, target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    static let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)

    private var color: NSColor {
        switch tone {
        case .plain: hovering ? Theme.fg : Theme.fg2
        case .danger: Theme.danger
        case .warn: Theme.warn
        case .accent: Theme.accent
        }
    }

    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: Self.font]).width
        return NSSize(width: ceil(width) + 18, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (hovering || isHighlighted ? Theme.surfaceHover : NSColor.clear).setFill()
        path.fill()
        (tone == .plain ? Theme.border : color.withAlphaComponent(0.45)).setStroke()
        path.lineWidth = 1
        path.stroke()
        let text = NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: color])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var isFlipped: Bool { true }
}

/// Send while there's a message; Stop (Esc to the agent) while it works and the box is empty.
final class ChatSendButton: NSButton {
    enum Mode { case send, stop, disabled }

    var mode = Mode.disabled { didSet { if mode != oldValue { needsDisplay = true; toolTip = mode == .stop ? "Stop (Esc)" : "Send (⏎)" } } }

    convenience init(target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        title = ""
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Send (⏎)"
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor = mode == .disabled ? Theme.fg4.withAlphaComponent(0.35) : Theme.fg
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        Theme.bg.withAlphaComponent(1).setFill()
        Theme.bg.withAlphaComponent(1).setStroke()
        let mid = NSPoint(x: bounds.midX, y: bounds.midY)
        if mode == .stop {
            NSBezierPath(roundedRect: NSRect(x: mid.x - 4.5, y: mid.y - 4.5, width: 9, height: 9), xRadius: 1.5, yRadius: 1.5).fill()
            return
        }
        // An arrow up.
        let arrow = NSBezierPath()
        arrow.lineWidth = 1.8
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        arrow.move(to: NSPoint(x: mid.x, y: mid.y + 6))
        arrow.line(to: NSPoint(x: mid.x, y: mid.y - 6))
        arrow.move(to: NSPoint(x: mid.x - 5, y: mid.y - 1))
        arrow.line(to: NSPoint(x: mid.x, y: mid.y - 6))
        arrow.line(to: NSPoint(x: mid.x + 5, y: mid.y - 1))
        arrow.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard mode != .disabled else { return }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() { if mode != .disabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override var isFlipped: Bool { true }
}

/// `Opus 5.5 · ▮▮▮▯ 184k / 1M · 15k tokens · $0.18 · effort high · weekly 79%`, in the terminal
/// font, dropping parts from the end when the pane is narrow.
final class ChatInfoLine: NSView {
    var info = ChatComposerInfo() { didSet { if info != oldValue { needsDisplay = true } } }

    /// A piece of one part: text, or the context bar.
    private enum Piece {
        case text(String, NSColor)
        case bar
    }

    private static let barWidth: CGFloat = 40

    private var parts: [[Piece]] {
        var out: [[Piece]] = []
        if let model = info.model { out.append([.text(model, Theme.fg2)]) }
        if let context = info.context { out.append([.bar, .text(context.text, Theme.fg3)]) }
        if let tokens = info.tokens, tokens > 0, let text = UsageText.tokens(tokens) { out.append([.text(text, Theme.fg3)]) }
        if let cost = info.cost { out.append([.text(cost, Theme.fg3)]) }
        if let effort = info.effort { out.append([.text("effort ", Theme.fg4), .text(effort, Theme.fg3)]) }
        for limit in info.limits {
            let color = limit.percent >= 90 ? Theme.danger : limit.percent >= 75 ? Theme.warn : Theme.fg3
            out.append([.text(limit.name.lowercased() + " ", Theme.fg4), .text(String(format: "%.0f%%", limit.percent), color)])
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = ChatStyle.smallFont
        var x: CGFloat = 0
        let mid = bounds.midY
        for (index, part) in parts.enumerated() {
            let gap: CGFloat = index > 0 ? 22 : 0
            guard x + gap + width(part, font: font) <= bounds.width else { break }
            if index > 0 {
                drawText("·", Theme.fg4, font: font, x: x + 8, mid: mid)
                x += gap
            }
            for piece in part {
                switch piece {
                case .bar: x = drawBar(x: x, mid: mid)
                case .text(let text, let color): x = drawText(text, color, font: font, x: x, mid: mid)
                }
            }
        }
    }

    private func width(_ part: [Piece], font: NSFont) -> CGFloat {
        part.reduce(0) { sum, piece in
            switch piece {
            case .bar: sum + Self.barWidth
            case .text(let text, _): sum + (text as NSString).size(withAttributes: [.font: font]).width
            }
        }
    }

    @discardableResult
    private func drawText(_ text: String, _ color: NSColor, font: NSFont, x: CGFloat, mid: CGFloat) -> CGFloat {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        string.draw(at: NSPoint(x: x, y: mid - size.height / 2))
        return x + size.width
    }

    /// The context window as a short bar: blue until it's three-quarters full.
    private func drawBar(x: CGFloat, mid: CGFloat) -> CGFloat {
        guard let context = info.context, context.window > 0 else { return x }
        let fraction = min(1, Double(context.used) / Double(context.window))
        let track = NSRect(x: x, y: mid - 2, width: 32, height: 4)
        Theme.border.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        (fraction >= 0.9 ? Theme.danger : fraction >= 0.75 ? Theme.warn : Theme.fg2).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: track.minY, width: max(3, track.width * fraction), height: 4), xRadius: 2, yRadius: 2).fill()
        return x + Self.barWidth
    }

    override var isFlipped: Bool { true }
}
