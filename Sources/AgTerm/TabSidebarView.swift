import AgTermCore
import AppKit

/// Tabs down the left side of the window (View → Tabs on the Left), each card showing more than
/// the tab bar has room for: the agent, its model and spend. The header holds the traffic
/// lights, + and the cloud button; the list scrolls when the tabs don't fit.
final class TabSidebarView: NSView {
    static let width: CGFloat = 264
    /// The header's height when the traffic lights can't be found.
    static let headerHeight: CGFloat = 52
    private static let inset: CGFloat = 8
    private static let spacing: CGFloat = 2
    private static let plusWidth: CGFloat = 40

    weak var delegate: TabBarDelegate?
    private var cards: [SidebarCardView] = []
    private let scroll = NSScrollView()
    private let list = SidebarListView()
    private let plusButton = IconButton(.plus)
    private let cloudButton = IconButton(.cloud)
    private var selectedIndex: Int?

    var cloud: TabBarView.Cloud = .hidden {
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
        }
    }

    var blinkOn = true {
        didSet { cards.forEach { $0.blinkOn = blinkOn } }
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { WindowDrag.mouseDown(event, in: window) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        // No scroller: with "Show scroll bars: Always" or a mouse attached, macOS swaps an overlay
        // scroller for a full-height track beside the cards. The list still scrolls by trackpad and wheel.
        scroll.hasVerticalScroller = false
        scroll.documentView = list
        addSubview(scroll)
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
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    #if DEBUG
    var cardsForTest: [NSView] { cards }
    #endif

    func refreshAppearance() {
        needsDisplay = true
        for view in subviews + list.subviews { view.needsDisplay = true }
    }

    func update(_ models: [TabModel]) {
        while cards.count < models.count {
            let card = SidebarCardView()
            card.onSelect = { [weak self, weak card] in self?.cardAction(card, close: false) }
            card.onClose = { [weak self, weak card] in self?.cardAction(card, close: true) }
            card.onMenu = { [weak self, weak card] event in self?.showMenu(for: card, event: event) }
            card.onBrowser = { [weak self, weak card] in
                guard let self, let card, let index = self.cards.firstIndex(where: { $0 === card }) else { return }
                self.delegate?.tabBar(self, didClickBrowser: index)
            }
            card.onDragBegan = { [weak self, weak card] in self?.beginDrag(card) }
            card.onDragMoved = { [weak self] dy in self?.moveDrag(dy) }
            card.onDragEnded = { [weak self] in self?.endDrag() }
            cards.append(card)
            list.addSubview(card)
        }
        while cards.count > models.count {
            cards.removeLast().removeFromSuperview()
        }
        for (card, model) in zip(cards, models) {
            card.model = model
            card.blinkOn = blinkOn
        }
        guard drag == nil else { return }
        layoutCards(animated: false)
        let newSelection = models.firstIndex(where: \.focused) ?? models.firstIndex(where: \.selected)
        if newSelection != selectedIndex {
            selectedIndex = newSelection
            if let index = newSelection { list.scrollToVisible(cards[index].frame) }
        }
    }

    private func cardAction(_ card: SidebarCardView?, close: Bool) {
        guard let card, let index = cards.firstIndex(where: { $0 === card }) else { return }
        if close { delegate?.tabBar(self, didClose: index) } else { delegate?.tabBar(self, didSelect: index) }
    }

    private func showMenu(for card: SidebarCardView?, event: NSEvent) {
        guard let card, let index = cards.firstIndex(where: { $0 === card }),
              let menu = delegate?.tabBar(self, menuFor: index) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: card)
    }

    // MARK: Drag to reorder

    private struct Drag {
        let from: Int
        let startY: CGFloat
        var dy: CGFloat = 0
        var to: Int
    }
    private var drag: Drag?

    private func beginDrag(_ card: SidebarCardView?) {
        guard let card, let index = cards.firstIndex(where: { $0 === card }) else { return }
        drag = Drag(from: index, startY: card.frame.minY, to: index)
        cards.forEach { $0.reordering = true }
        list.addSubview(card, positioned: .above, relativeTo: nil)
    }

    private func moveDrag(_ dy: CGFloat) {
        guard var d = drag else { return }
        d.dy = dy
        let dragged = cards[d.from]
        let center = d.startY + dy + dragged.frame.height / 2
        // The slot is how many of the other cards sit above the dragged card's middle.
        var y = Self.spacing
        var slot = 0
        for (i, card) in cards.enumerated() where i != d.from {
            let height = card.frame.height
            if center > y + height / 2 { slot += 1 }
            y += height + Self.spacing
        }
        d.to = slot
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
        cards = TabOrder.moved(cards, from: d.from, to: d.to)
        cards.forEach { $0.reordering = false }
        if d.from != d.to { delegate?.tabBar(self, didMove: d.from, to: d.to) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            layoutCards(animated: true)
        }, completionHandler: { [weak self] in
            self?.cards.forEach { $0.syncHover() }
        })
    }

    // MARK: Layout

    /// Cards stacked top to bottom, or during a drag: the dragged card under the mouse and the
    /// others closed up around the slot it would drop into.
    private func layoutCards(animated: Bool) {
        let width = max(0, scroll.contentSize.width - 2 * Self.inset)
        let density = fittingDensity()
        cards.forEach { $0.density = density }
        let heights = cards.map { $0.model.map { SidebarCardView.height(for: $0, density: density) } ?? 40 }
        var y = Self.spacing
        var slot = 0
        for (i, card) in cards.enumerated() {
            if let d = drag, i == d.from { continue }
            if let d = drag, slot == d.to { y += heights[d.from] + Self.spacing }
            let frame = NSRect(x: Self.inset, y: y, width: width, height: heights[i])
            if animated { card.animator().frame = frame } else { card.frame = frame }
            y += heights[i] + Self.spacing
            slot += 1
        }
        let total = heights.reduce(Self.spacing) { $0 + $1 + Self.spacing }
        if let d = drag {
            let height = heights[d.from]
            cards[d.from].frame = NSRect(x: Self.inset, y: min(max(d.startY + d.dy, 0), max(0, total - height)), width: width, height: height)
        }
        list.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(total, scroll.contentSize.height))
    }

    /// The most detail at which every card fits without scrolling; the least when none does.
    private func fittingDensity() -> SidebarCardView.Density {
        let room = scroll.contentSize.height
        let models = cards.compactMap(\.model)
        return SidebarCardView.Density.allCases.first { density in
            models.reduce(Self.spacing) { $0 + SidebarCardView.height(for: $1, density: density) + Self.spacing } <= room
        } ?? .compact
    }

    /// Just below the traffic lights, so the first tab sits close under them.
    private var headerHeight: CGFloat {
        guard let button = window?.standardWindowButton(.closeButton), let superview = button.superview else { return Self.headerHeight }
        let frame = convert(button.frame, from: superview)
        return min(Self.headerHeight, max(28, ceil(frame.maxY) + 8))
    }

    override func layout() {
        super.layout()
        let header = headerHeight
        let lights = window?.standardWindowButton(.closeButton).flatMap { button in button.superview.map { convert(button.frame, from: $0) } }
        // + and the cloud button line up with the traffic lights.
        let buttonY = lights.map { $0.midY - 18 } ?? 0
        plusButton.frame = NSRect(x: bounds.width - Self.plusWidth - 6, y: buttonY, width: Self.plusWidth, height: 36)
        cloudButton.frame = NSRect(x: plusButton.frame.minX - 34, y: buttonY, width: 36, height: 36)
        scroll.frame = NSRect(x: 0, y: header, width: bounds.width - 1, height: max(0, bounds.height - header))
        if drag == nil { layoutCards(animated: false) }
    }

    /// No fill of its own: the window margins behind it are the terminal's color, so the sidebar
    /// and the terminal read as one surface (a second see-through fill made a mismatched band).
    override func draw(_ dirtyRect: NSRect) {
        Theme.border.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }
}

/// The sidebar's scrolling list; empty space in it moves the window, as the header does.
private final class SidebarListView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { WindowDrag.mouseDown(event, in: window) }
}
