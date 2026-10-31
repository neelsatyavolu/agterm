import AgTermCore
import AppKit

struct DiffCount: Equatable {
    var added: Int
    var removed: Int
}

/// Everything a tab card draws. Built fresh from a session on each change.
struct TabModel: Equatable {
    var topic: String
    var folder: String
    var git: GitSummary?
    /// Lines changed since the tab's agent started; nil when no agent is running.
    var agentDiff: DiffCount?
    var status: TabStatus
    var selected: Bool
    /// The shell runs on the cloud machine (agterm Cloud).
    var inCloud = false
}

protocol TabBarDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didSelect index: Int)
    func tabBar(_ bar: TabBarView, didClose index: Int)
    func tabBarDidRequestNewTab(_ bar: TabBarView)
    /// Right-click on +: start an agent instead of a plain shell.
    func tabBarAgentMenu(_ bar: TabBarView) -> NSMenu
    func tabBar(_ bar: TabBarView, didMove from: Int, to: Int)
    /// Right-click on a tab: rename it and the like.
    func tabBar(_ bar: TabBarView, menuFor index: Int) -> NSMenu
    /// The cloud button beside +: move every tab to the cloud, or bring them back.
    func tabBarDidRequestCloud(_ bar: TabBarView)
}

/// Horizontal strip of two-line tab cards plus a new-tab button. Sits in the title bar.
/// The selected card shares the terminal's background so it reads as one surface.
/// When tabs don't fit at their minimum width the strip scrolls sideways.
final class TabBarView: NSView {
    static let height: CGFloat = 52
    /// Room for the traffic lights.
    private static let leadingInset: CGFloat = 80
    private static let plusWidth: CGFloat = 44
    private static let cloudWidth: CGFloat = 40
    private static let minTabWidth: CGFloat = 168
    private static let maxTabWidth: CGFloat = 300

    weak var delegate: TabBarDelegate?
    private var cards: [TabCardView] = []
    private let strip = NSView()
    private let plusButton = IconButton(.plus)
    private let cloudButton = IconButton(.cloud)
    private let leftButton = IconButton(.left)
    private let rightButton = IconButton(.right)
    private var scrollX: CGFloat = 0
    private var selectedIndex: Int?
    /// What the cloud button beside + offers (agterm Cloud).
    enum Cloud: Equatable {
        case hidden
        /// Move every tab to the cloud, to turn this Mac off.
        case moveUp
        /// Bring the tabs back from the cloud.
        case bringBack
        /// Moving one way or the other.
        case busy
    }

    var cloud: Cloud = .hidden {
        didSet {
            guard cloud != oldValue else { return }
            cloudButton.isHidden = cloud == .hidden
            cloudButton.cloud = cloud
            cloudButton.toolTip = switch cloud {
            case .moveUp: "Move all tabs to the cloud. They keep running when you turn this Mac off."
            case .bringBack: "Bring your tabs back from the cloud."
            case .busy: "Moving tabs…"
            case .hidden: nil
            }
            needsLayout = true
        }
    }

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
        plusButton.onRightClick = { [weak self] event in
            guard let self, let menu = self.delegate?.tabBarAgentMenu(self) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self.plusButton)
        }
        plusButton.toolTip = "New tab. Right-click to start an agent."
        addSubview(plusButton)
        cloudButton.onClick = { [weak self] in
            guard let self, self.cloud != .busy else { return }
            self.delegate?.tabBarDidRequestCloud(self)
        }
        cloudButton.isHidden = true
        addSubview(cloudButton)
        leftButton.onClick = { [weak self] in self?.scroll(by: -1) }
        rightButton.onClick = { [weak self] in self?.scroll(by: 1) }
        addSubview(leftButton)
        addSubview(rightButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The window isn't movable by the system (so dragging a tab can never move it); the empty
    /// part of the bar moves it here instead, and a double-click there zooms or minimizes it
    /// as set in System Settings, like a title bar.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
            return
        }
        window.isMovable = true
        window.performDrag(with: event)
        window.isMovable = false
    }

    #if DEBUG
    var selectedCardForTest: NSView { cards[selectedIndex ?? 0] }
    #endif

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
            card.onMenu = { [weak self, weak card] event in self?.showMenu(for: card, event: event) }
            card.onDragBegan = { [weak self, weak card] in self?.beginDrag(card) }
            card.onDragMoved = { [weak self] dx in self?.moveDrag(dx) }
            card.onDragEnded = { [weak self] in self?.endDrag() }
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

    private func showMenu(for card: TabCardView?, event: NSEvent) {
        guard let card, let index = cards.firstIndex(where: { $0 === card }),
              let menu = delegate?.tabBar(self, menuFor: index) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: card)
    }

    // MARK: Drag to reorder

    private struct Drag {
        let from: Int
        let startX: CGFloat
        var dx: CGFloat = 0
        var to: Int
    }
    private var drag: Drag?

    private func beginDrag(_ card: TabCardView?) {
        guard let card, let index = cards.firstIndex(where: { $0 === card }) else { return }
        drag = Drag(from: index, startX: card.frame.minX, to: index)
        cards.forEach { $0.reordering = true }
        strip.addSubview(card, positioned: .above, relativeTo: nil) // draw on top while moving
    }

    private func moveDrag(_ dx: CGFloat) {
        guard var d = drag else { return }
        d.dx = dx
        let width = tabWidth
        let center = d.startX + dx + scrollX + width / 2
        d.to = min(max(Int(center / width), 0), cards.count - 1)
        let slotChanged = d.to != drag?.to
        drag = d
        if slotChanged {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.allowsImplicitAnimation = true
                layoutCards(animated: true)
            }
        } else {
            layoutCards(animated: false)
        }
    }

    private func endDrag() {
        guard let d = drag else { return }
        drag = nil
        // Move the card itself to its new place, so the update that follows the move hands
        // every card its own tab again instead of sliding them back and swapping contents.
        cards = TabOrder.moved(cards, from: d.from, to: d.to)
        cards.forEach { $0.reordering = false }
        if d.from != d.to {
            delegate?.tabBar(self, didMove: d.from, to: d.to)
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            layoutCards(animated: true)
        }, completionHandler: { [weak self] in
            self?.cards.forEach { $0.syncHover() }
        })
    }

    /// Normal positions, or during a drag: the dragged card under the mouse and the others
    /// closed up around the slot it would drop into.
    private func layoutCards(animated: Bool) {
        let width = tabWidth
        var slot = 0
        for (i, card) in cards.enumerated() {
            var frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            if let d = drag, i == d.from {
                frame.origin.x = min(max(d.startX + d.dx, -scrollX), CGFloat(cards.count - 1) * width - scrollX)
                card.frame = frame
                continue
            }
            if let d = drag, slot == d.to { slot += 1 }
            frame.origin.x = CGFloat(slot) * width - scrollX
            slot += 1
            if animated { card.animator().frame = frame } else { card.frame = frame }
        }
    }

    // MARK: Layout

    private static let arrowWidth: CGFloat = 24

    private var tabWidth: CGFloat {
        let count = CGFloat(max(cards.count, 1))
        return min(Self.maxTabWidth, max(Self.minTabWidth, floor(fullStripWidth / count)))
    }

    /// Room for tabs when they all fit.
    private var fullStripWidth: CGFloat {
        max(0, bounds.width - Self.leadingInset - Self.plusWidth - (cloud == .hidden ? 0 : Self.cloudWidth))
    }
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
        layoutCards(animated: false)
        let contentEnd = overflows ? strip.frame.maxX + Self.arrowWidth : stripX + CGFloat(cards.count) * width
        plusButton.frame = NSRect(x: contentEnd, y: 0, width: Self.plusWidth, height: bounds.height)
        cloudButton.frame = NSRect(x: plusButton.frame.maxX - 6, y: 0, width: Self.cloudWidth, height: bounds.height)

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
    enum Icon { case plus, left, right, cloud }

    var onClick: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    private let icon: Icon
    private var hovering = false { didSet { needsDisplay = true } }
    /// For `.cloud`: which way it points.
    var cloud: TabBarView.Cloud = .moveUp { didSet { needsDisplay = true } }

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
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let onRightClick { return onRightClick(event) }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let onRightClick else { return super.rightMouseDown(with: event) }
        onRightClick(event)
    }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let ink = hovering ? Theme.fg : Theme.fg3
        switch icon {
        case .plus:
            if hovering {
                Theme.surfaceHover.setFill()
                NSBezierPath(roundedRect: NSRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26), xRadius: 7, yRadius: 7).fill()
            }
            ink.setFill()
            NSRect(x: c.x - 6, y: c.y - 0.5, width: 12, height: 1).fill()
            NSRect(x: c.x - 0.5, y: c.y - 6, width: 1, height: 12).fill()
        case .cloud:
            if hovering && cloud != .busy {
                Theme.surfaceHover.setFill()
                NSBezierPath(roundedRect: NSRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26), xRadius: 7, yRadius: 7).fill()
            }
            let name = switch cloud {
            case .bringBack: "icloud.and.arrow.down"
            case .busy: "arrow.triangle.2.circlepath.icloud"
            default: "icloud.and.arrow.up"
            }
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?.withSymbolConfiguration(config) else { return }
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                (self.cloud == .busy ? Theme.fg3 : ink).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: c.x - symbol.size.width / 2, y: c.y - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
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
