import AgTermCore
import AppKit

/// Everything a tab card draws. Built fresh from a session on each change.
struct TabModel: Equatable {
    var topic: String
    var folder: String
    var git: GitSummary?
    var status: TabStatus
    var selected: Bool
}

protocol TabBarDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didSelect index: Int)
    func tabBar(_ bar: TabBarView, didClose index: Int)
    func tabBarDidRequestNewTab(_ bar: TabBarView)
}

/// Horizontal strip of two-line tab cards plus a new-tab button. Sits in the title bar.
/// The selected card shares the terminal's background so it reads as one surface.
/// When tabs don't fit at their minimum width the strip scrolls sideways.
final class TabBarView: NSView {
    static let height: CGFloat = 52
    /// Room for the traffic lights.
    private static let leadingInset: CGFloat = 80
    private static let plusWidth: CGFloat = 44
    private static let minTabWidth: CGFloat = 168
    private static let maxTabWidth: CGFloat = 300

    weak var delegate: TabBarDelegate?
    private var cards: [TabCardView] = []
    private let strip = NSView()
    private let plusButton = IconButton(.plus)
    private let leftButton = IconButton(.left)
    private let rightButton = IconButton(.right)
    private var scrollX: CGFloat = 0
    private var selectedIndex: Int?
    /// Toggles twice a second so working dots blink.
    var blinkOn = true {
        didSet { cards.forEach { $0.blinkOn = blinkOn } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
        strip.clipsToBounds = true
        addSubview(strip)
        plusButton.onClick = { [weak self] in
            guard let self else { return }
            self.delegate?.tabBarDidRequestNewTab(self)
        }
        addSubview(plusButton)
        leftButton.onClick = { [weak self] in self?.scroll(by: -1) }
        rightButton.onClick = { [weak self] in self?.scroll(by: 1) }
        addSubview(leftButton)
        addSubview(rightButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { true }

    /// Redraws everything after a theme change.
    func refreshAppearance() {
        needsDisplay = true
        for view in subviews + strip.subviews { view.needsDisplay = true }
    }

    func update(_ models: [TabModel]) {
        while cards.count < models.count {
            let card = TabCardView()
            card.onSelect = { [weak self, weak card] in self?.cardAction(card, close: false) }
            card.onClose = { [weak self, weak card] in self?.cardAction(card, close: true) }
            cards.append(card)
            strip.addSubview(card)
        }
        while cards.count > models.count {
            cards.removeLast().removeFromSuperview()
        }
        for (card, model) in zip(cards, models) {
            card.model = model
            card.blinkOn = blinkOn
        }
        let newSelection = models.firstIndex(where: \.selected)
        if newSelection != selectedIndex {
            selectedIndex = newSelection
            scrollSelectedIntoView()
        }
        needsLayout = true
        needsDisplay = true
    }

    private func cardAction(_ card: TabCardView?, close: Bool) {
        guard let card, let index = cards.firstIndex(where: { $0 === card }) else { return }
        if close { delegate?.tabBar(self, didClose: index) } else { delegate?.tabBar(self, didSelect: index) }
    }

    // MARK: Layout

    private static let arrowWidth: CGFloat = 24

    private var tabWidth: CGFloat {
        let count = CGFloat(max(cards.count, 1))
        return min(Self.maxTabWidth, max(Self.minTabWidth, floor(fullStripWidth / count)))
    }

    /// Room for tabs when they all fit.
    private var fullStripWidth: CGFloat { max(0, bounds.width - Self.leadingInset - Self.plusWidth) }
    private var overflows: Bool { CGFloat(cards.count) * Self.minTabWidth > fullStripWidth }
    /// When tabs overflow, the strip gives up room at each end for the scroll arrows.
    private var stripX: CGFloat { Self.leadingInset + (overflows ? Self.arrowWidth : 0) }
    private var stripWidth: CGFloat { max(0, fullStripWidth - (overflows ? Self.arrowWidth * 2 : 0)) }
    private var maxScroll: CGFloat { max(0, CGFloat(cards.count) * tabWidth - stripWidth) }

    override func layout() {
        super.layout()
        if inLiveResize || window?.inLiveResize == true { scrollSelectedIntoView() }
        scrollX = min(max(0, scrollX), maxScroll)
        strip.frame = NSRect(x: stripX, y: 0, width: stripWidth, height: bounds.height)
        let width = tabWidth
        for (i, card) in cards.enumerated() {
            card.frame = NSRect(x: CGFloat(i) * width - scrollX, y: 0, width: width, height: bounds.height)
        }
        let contentEnd = overflows ? strip.frame.maxX + Self.arrowWidth : stripX + CGFloat(cards.count) * width
        plusButton.frame = NSRect(x: contentEnd, y: 0, width: Self.plusWidth, height: bounds.height)

        // Arrows beside the strip, hidden when there's nothing more on that side.
        leftButton.isHidden = !overflows || scrollX <= 0
        rightButton.isHidden = !overflows || scrollX >= maxScroll
        leftButton.frame = NSRect(x: strip.frame.minX - Self.arrowWidth, y: 1, width: Self.arrowWidth, height: bounds.height - 1)
        rightButton.frame = NSRect(x: strip.frame.maxX, y: 1, width: Self.arrowWidth, height: bounds.height - 1)
    }

    /// Scrolls the strip by whole tabs.
    private func scroll(by tabs: Int) {
        scrollX = min(max(0, scrollX + CGFloat(tabs) * tabWidth), maxScroll)
        needsLayout = true
        needsDisplay = true
    }

    private func scrollSelectedIntoView() {
        guard let index = selectedIndex else { return }
        let left = CGFloat(index) * tabWidth
        let right = left + tabWidth
        if left < scrollX { scrollX = left }
        if right > scrollX + stripWidth { scrollX = right - stripWidth }
    }

    override func scrollWheel(with event: NSEvent) {
        var delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= 24 }
        scrollX = min(max(0, scrollX - delta), maxScroll)
        needsLayout = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Fill bounds, not dirtyRect: since macOS 14 views don't clip by default and
        // dirtyRect can cover siblings, which once painted over the terminal.
        Theme.chrome.setFill()
        bounds.fill()
        // Bottom hairline, broken under the selected tab so it joins the terminal.
        Theme.border.setFill()
        guard let index = selectedIndex, cards.indices.contains(index) else {
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
            return
        }
        let card = convert(cards[index].frame, from: strip).intersection(strip.frame)
        guard !card.isNull, card.width > 0 else {
            NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
            return
        }
        NSRect(x: 0, y: 0, width: max(0, card.minX), height: 1).fill()
        NSRect(x: card.maxX, y: 0, width: max(0, bounds.width - card.maxX), height: 1).fill()
    }
}

private final class IconButton: NSView {
    enum Icon { case plus, left, right }

    var onClick: (() -> Void)?
    private let icon: Icon
    private var hovering = false { didSet { needsDisplay = true } }

    init(_ icon: Icon) {
        self.icon = icon
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let ink = hovering ? Theme.fg : Theme.fg3
        switch icon {
        case .plus:
            if hovering {
                Theme.surfaceHover.setFill()
                NSRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26).fill()
            }
            ink.setFill()
            NSRect(x: c.x - 6, y: c.y - 0.5, width: 12, height: 1).fill()
            NSRect(x: c.x - 0.5, y: c.y - 6, width: 1, height: 12).fill()
        case .left, .right:
            // Opaque so the arrow sits cleanly over the tab underneath.
            Theme.chrome.setFill()
            bounds.fill()
            Theme.border.setFill()
            NSRect(x: icon == .left ? bounds.maxX - 1 : 0, y: 10, width: 1, height: bounds.height - 20).fill()
            let dx: CGFloat = icon == .left ? 2.5 : -2.5
            let path = NSBezierPath()
            path.move(to: NSPoint(x: c.x + dx, y: c.y + 5))
            path.line(to: NSPoint(x: c.x - dx, y: c.y))
            path.line(to: NSPoint(x: c.x + dx, y: c.y - 5))
            path.lineWidth = 1.25
            ink.setStroke()
            path.stroke()
        }
    }
}
