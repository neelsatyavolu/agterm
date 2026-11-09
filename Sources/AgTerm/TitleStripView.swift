import AgTermCore
import AppKit

/// The strip above the terminal when the tabs are on the left: the tab's title after its agent's
/// logo, and room to drag the window by. On an agent tab agterm can read, a Chat | Term control
/// on the right; in Chat, the title becomes the agent, model, folder and branch, with tokens,
/// cost and lines changed beside the control. The Session Timeline button sits at the right end.
final class TitleStripView: NSView {
    static let height: CGFloat = 40
    private static let logoSize: CGFloat = 16
    private static let timelineWidth: CGFloat = 44
    /// Where the timeline button starts.
    private var trailingX: CGFloat { bounds.width - Self.timelineWidth - 4 }
    /// Room kept free left of the timeline button for the review toolbar.
    var trailingReserve: CGFloat = 0 { didSet { if trailingReserve != oldValue { needsDisplay = true } } }
    /// Where the title and the Chat | Term control must end.
    private var contentMaxX: CGFloat { trailingX - max(8, trailingReserve) }

    /// What Chat mode shows instead of the title.
    struct ChatInfo: Equatable {
        var agent: String
        var model: String?
        var folder: String
        var branch: String?
        var usage: String?
        /// `412k / 1M`: the context window, used and size.
        var context: String?
        var added = 0
        var removed = 0
    }

    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    var logo: NSImage? { didSet { if logo !== oldValue { needsDisplay = true } } }
    /// Nil hides the Chat | Term control; true when Chat is showing.
    var chatMode: Bool? { didSet { if chatMode != oldValue { needsDisplay = true } } }
    var chatInfo: ChatInfo? { didSet { if chatInfo != oldValue { needsDisplay = true } } }
    /// Chat (true) or Term (false) was clicked.
    var onChatMode: (Bool) -> Void = { _ in }
    private var segments: (chat: NSRect, term: NSRect)?
    /// Opens the Session Timeline; at the right end of the strip.
    let timelineButton = IconButton(.timeline)

    override init(frame: NSRect) {
        super.init(frame: frame)
        timelineButton.toolTip = "Session timeline (⇧⌘L)"
        addSubview(timelineButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        timelineButton.frame = NSRect(x: trailingX, y: 0, width: Self.timelineWidth, height: bounds.height)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let segments, chatMode != nil {
            if segments.chat.contains(point) { return onChatMode(true) }
            if segments.term.contains(point) { return onChatMode(false) }
        }
        WindowDrag.mouseDown(event, in: window)
    }

    override func draw(_ dirtyRect: NSRect) {
        var maxX = contentMaxX
        segments = nil
        if let chatMode {
            maxX = drawControl(chat: chatMode) - 16
            if chatMode, let info = chatInfo { maxX = drawStats(info, maxX: maxX) - 16 }
        }
        let text = chatMode == true ? chatInfo.map(chatTitle) ?? plainTitle : plainTitle
        let logoWidth = logo == nil ? 0 : Self.logoSize + 8
        let width = min(ceil(text.size().width) + logoWidth, maxX - 12)
        let x = max(12, min((bounds.width - width) / 2, maxX - width))
        if let logo {
            logo.draw(in: NSRect(x: x, y: (bounds.height - Self.logoSize) / 2, width: Self.logoSize, height: Self.logoSize),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        TabCardDrawing.draw(text, x: x + logoWidth, y: (bounds.height - 17) / 2, maxX: maxX)
    }

    private var plainTitle: NSMutableAttributedString { TabCardDrawing.text(title, Theme.topicFont, Theme.fg3) }

    /// `claude  opus 5.5  agterm  ⎇ main`.
    private func chatTitle(_ info: ChatInfo) -> NSMutableAttributedString {
        let out = TabCardDrawing.text(info.agent, Theme.topicFont, Theme.fg2)
        for (part, color) in [(info.model, Theme.fg3), (info.folder, Theme.fg3), (info.branch.map { "⎇ " + $0 }, Theme.fg3)] {
            guard let part, !part.isEmpty else { continue }
            out.append(TabCardDrawing.text("   " + part, Theme.metaFont, color))
        }
        return out
    }

    /// `412k / 1M   48.2k · $0.41   +86 −12`, right-aligned at `maxX`; returns where it starts.
    private func drawStats(_ info: ChatInfo, maxX: CGFloat) -> CGFloat {
        let text = NSMutableAttributedString()
        if let context = info.context { text.append(TabCardDrawing.text(context + "   ", Theme.metaFont, Theme.fg2)) }
        if let usage = info.usage { text.append(TabCardDrawing.text(usage + "   ", Theme.metaFont, Theme.fg3)) }
        if info.added > 0 || info.removed > 0 {
            text.append(TabCardDrawing.text("+\(info.added)", Theme.metaFont, Theme.ok))
            text.append(TabCardDrawing.text(" −\(info.removed)", Theme.metaFont, Theme.danger))
        }
        let width = ceil(text.size().width)
        guard width > 0, maxX - width > bounds.width / 2 else { return maxX }
        text.draw(at: NSPoint(x: maxX - width, y: (bounds.height - text.size().height) / 2))
        return maxX - width
    }

    /// The two-part control at the right edge; returns its left edge.
    private func drawControl(chat: Bool) -> CGFloat {
        let font = Theme.metaFont
        let labels = [TabCardDrawing.text("Chat", font, chat ? Theme.fg : Theme.fg3),
                      TabCardDrawing.text("Term ⌃`", font, chat ? Theme.fg3 : Theme.fg)]
        let widths = labels.map { ceil($0.size().width) + 16 }
        let height: CGFloat = 22
        let total = widths.reduce(0, +)
        let frame = NSRect(x: contentMaxX - total, y: (bounds.height - height) / 2, width: total, height: height)
        let chatRect = NSRect(x: frame.minX, y: frame.minY, width: widths[0], height: height)
        let termRect = NSRect(x: chatRect.maxX, y: frame.minY, width: widths[1], height: height)
        Theme.surfaceHover.setFill()
        NSBezierPath(roundedRect: (chat ? chatRect : termRect).insetBy(dx: 2, dy: 2), xRadius: 4, yRadius: 4).fill()
        Theme.border.setStroke()
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        outline.lineWidth = 1
        outline.stroke()
        for (label, rect) in zip(labels, [chatRect, termRect]) {
            label.draw(at: NSPoint(x: rect.minX + 8, y: rect.midY - label.size().height / 2))
        }
        segments = (chatRect, termRect)
        return frame.minX
    }

    override func resetCursorRects() {
        if let segments, chatMode != nil {
            addCursorRect(segments.chat, cursor: .pointingHand)
            addCursorRect(segments.term, cursor: .pointingHand)
        }
    }
}
