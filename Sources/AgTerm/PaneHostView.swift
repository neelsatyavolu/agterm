import AgTermCore
import AppKit

/// Shows the selected tab's panes in their arrangement: sizes each pane's terminal, paints the
/// dividers between them (drag one to resize), and dims every pane but the one you type in.
/// Terminals of other tabs stay here, hidden. Other subviews (the command bar) are left alone.
final class PaneHostView: NSView {
    static let gap: CGFloat = 9

    /// The shown tab's arrangement and its panes' views, by tab ID.
    private(set) var tree: PaneNode?
    private var views: [String: NSView] = [:]
    private var focused: String?
    private var dims: [NSView] = []
    /// A divider was dragged: the split at `path` should give its first side `ratio`.
    var onResize: ((_ path: [Int], _ ratio: Double) -> Void)?
    private var resizing: PaneNode.Divider?

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func show(_ tree: PaneNode, views: [String: NSView], focused: String) {
        let changed = tree != self.tree || focused != self.focused || Set(views.keys) != Set(self.views.keys)
        self.tree = tree
        self.views = views
        self.focused = focused
        guard changed else { return }
        needsLayout = true
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private var space: PaneRect { PaneRect(x: 0, y: 0, width: Double(bounds.width), height: Double(bounds.height)) }

    /// Where `id`'s pane is, in this view.
    func frame(of id: String) -> NSRect? {
        tree?.frames(in: space, gap: Double(Self.gap))[id].map(NSRect.init)
    }

    /// The panes as laid out in this view's space, for finding neighbors.
    var layoutSpace: PaneRect { space }

    override func layout() {
        super.layout()
        guard let tree else { return }
        let frames = tree.frames(in: space, gap: Double(Self.gap))
        for (id, view) in views {
            if let frame = frames[id] { view.frame = NSRect(frame) }
        }
        layoutDims(frames)
    }

    /// One see-through shade over each pane you aren't typing in, when the tab has more than one.
    private func layoutDims(_ frames: [String: PaneRect]) {
        let others = frames.count > 1 ? frames.filter { $0.key != focused }.map(\.value) : []
        while dims.count < others.count { dims.append(PaneDim()) }
        while dims.count > others.count { dims.removeLast().removeFromSuperview() }
        for dim in dims where dim.superview == nil {
            addSubview(dim)
            raiseCommandBar()
        }
        for (dim, frame) in zip(dims, others) { dim.frame = NSRect(frame) }
    }

    /// Terminals of new tabs go under the shades, and the command bar stays over everything.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard !(subview is PaneDim), !(subview is CommandBar) else { return }
        dims.forEach { addSubview($0, positioned: .above, relativeTo: nil) }
        raiseCommandBar()
    }

    private func raiseCommandBar() {
        if let bar = subviews.first(where: { $0 is CommandBar }) { addSubview(bar, positioned: .above, relativeTo: nil) }
    }

    private var dividers: [PaneNode.Divider] {
        tree?.dividers(in: space, gap: Double(Self.gap)) ?? []
    }

    /// The gaps share the window margins' color, with a hairline down the middle.
    override func draw(_ dirtyRect: NSRect) {
        for divider in dividers {
            let rect = NSRect(divider.rect)
            Theme.bg.setFill()
            rect.fill()
            Theme.border.setFill()
            switch divider.axis {
            case .columns: NSRect(x: rect.midX - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
            case .rows: NSRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1).fill()
            }
        }
    }

    override func resetCursorRects() {
        for divider in dividers {
            addCursorRect(NSRect(divider.rect), cursor: divider.axis == .columns ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        resizing = dividers.first { NSRect($0.rect).insetBy(dx: -2, dy: -2).contains(point) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let divider = resizing else { return }
        let point = convert(event.locationInWindow, from: nil)
        let span = divider.span, gap = Double(Self.gap)
        let ratio = switch divider.axis {
        case .columns: (Double(point.x) - span.minX - gap / 2) / max(1, span.width - gap)
        case .rows: (Double(point.y) - span.minY - gap / 2) / max(1, span.height - gap)
        }
        onResize?(divider.path, ratio)
    }

    override func mouseUp(with event: NSEvent) {
        resizing = nil
        window?.invalidateCursorRects(for: self)
    }
}

/// Shades a pane you aren't typing in. Clicks go through to the terminal underneath.
private final class PaneDim: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        Theme.chrome.withAlphaComponent(0.35).setFill()
        bounds.fill()
    }
}

extension NSRect {
    init(_ rect: PaneRect) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
