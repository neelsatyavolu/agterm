import AgTermCore
import AppKit

/// What the toolbar shows for the tab you're typing in. Equatable so an unchanged tab redraws nothing.
struct ReviewToolbarState: Equatable {
    var isRepo = false
    var changedFiles = 0
    var ahead = 0
    /// A branch with no upstream yet, on a repo with a remote.
    var unpublished = false
    var agent: String?
    var pullRequest: PullRequest?
    var panelOpen = false
    var inWorktree = false
}

/// The buttons at the top right: pull request, worktrees, hand off, commit, usage and the diff
/// panel. Each says what it does in its tooltip, with its shortcut.
final class ReviewToolbar: NSView {
    let pullRequest = ToolbarButton(symbol: "arrow.triangle.pull")
    let worktree = ToolbarButton(symbol: "arrow.triangle.branch")
    let handOff = ToolbarButton(symbol: "arrow.left.arrow.right")
    let commit = ToolbarButton(symbol: "checkmark.circle")
    let usage = ToolbarButton(symbol: "chart.bar.xaxis")
    let changes = ToolbarButton(symbol: "sidebar.right")
    private let stack = NSStackView()
    private(set) var state = ReviewToolbarState()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let divider = Hairline()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [pullRequest, worktree, handOff, commit, usage, divider, changes] as [NSView] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(6, after: usage)
        stack.setCustomSpacing(6, after: divider)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 16),
        ])
        usage.toolTip = "Usage: tokens, estimated cost and limits for every agent (⇧⌘U)"
        apply(state, force: true)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    func update(_ new: ReviewToolbarState) {
        guard new != state else { return }
        apply(new, force: false)
    }

    private func apply(_ new: ReviewToolbarState, force: Bool) {
        state = new
        pullRequest.isHidden = new.pullRequest == nil
        if let pr = new.pullRequest {
            pullRequest.title = "#\(pr.number)"
            pullRequest.toolTip = "Open pull request #\(pr.number) on GitHub" + (pr.isOpen ? "" : " (\(pr.state.lowercased()))")
        }

        worktree.isEnabled = new.isRepo
        worktree.toolTip = new.isRepo
            ? "Worktrees: start an agent on a new branch in a folder of its own (⇧⌘N)"
            : "Worktrees need a git repository"

        handOff.isEnabled = new.agent != nil
        handOff.toolTip = new.agent.map { "Hand this \(AgentKind.named($0)?.title ?? $0) conversation to another agent" }
            ?? "Hand off: start an agent in this tab first"

        let canPush = new.changedFiles == 0 && (new.ahead > 0 || new.unpublished)
        commit.symbol = canPush ? "arrow.up.circle" : "checkmark.circle"
        commit.isEnabled = new.isRepo && (new.changedFiles > 0 || canPush)
        commit.toolTip = !new.isRepo ? "Commit: not a git repository"
            : new.changedFiles > 0 ? "Commit \(Self.files(new.changedFiles)), then push or open a pull request (⌥⌘C)"
            : canPush && new.ahead == 0 ? "Push this branch, which isn't on the remote yet, or open a pull request (⌥⌘C)"
            : canPush ? "Push \(new.ahead) commit\(new.ahead == 1 ? "" : "s") or open a pull request (⌥⌘C)"
            : "Nothing to commit"

        changes.isOn = new.panelOpen
        changes.toolTip = new.panelOpen ? "Hide changes (⇧⌘E)" : "Show changes: what the agent, this branch or uncommitted work changed (⇧⌘E)"
        if force { needsLayout = true }
    }

    private static func files(_ count: Int) -> String { "\(count) changed file\(count == 1 ? "" : "s")" }

    func refreshAppearance() { stack.arrangedSubviews.forEach { $0.needsDisplay = true } }
}

/// An icon button in the title bar, optionally with a short label (the pull request number).
final class ToolbarButton: NSView {
    var onClick: (() -> Void)?
    var symbol: String { didSet { if symbol != oldValue { image = Self.image(symbol); needsDisplay = true } } }
    var title: String? { didSet { if title != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }
    private var image: NSImage?
    private var hovering = false { didSet { needsDisplay = true } }
    private static let size: CGFloat = 28
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)

    init(symbol: String) {
        self.symbol = symbol
        image = Self.image(symbol)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private static func image(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }

    override var intrinsicContentSize: NSSize {
        guard let title else { return NSSize(width: Self.size, height: Self.size) }
        let width = ceil(NSAttributedString(string: title, attributes: [.font: Self.font]).size().width)
        return NSSize(width: Self.size + width + 4, height: Self.size)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { if isEnabled { onClick?() } }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }

    override func accessibilityLabel() -> String? { toolTip }

    /// Pops `menu` up under the button, as a toolbar menu does.
    func popUp(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        if isEnabled, hovering || isOn {
            (isOn ? Theme.surfaceHover : Theme.surface).setFill()
            NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
        }
        let ink = !isEnabled ? Theme.fg4 : isOn ? Theme.accent : hovering ? Theme.fg : Theme.fg2
        if let image {
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                ink.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            let x = title == nil ? (bounds.width - image.size.width) / 2 : 8
            tinted.draw(in: NSRect(x: x, y: (bounds.height - image.size.height) / 2, width: image.size.width, height: image.size.height))
        }
        if let title {
            let text = NSAttributedString(string: title, attributes: [.font: Self.font, .foregroundColor: ink])
            text.draw(at: NSPoint(x: 8 + (image?.size.width ?? 0) + 4, y: (bounds.height - text.size().height) / 2))
        }
    }
}

/// A short vertical line between groups of toolbar buttons.
final class Hairline: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.border.setFill()
        bounds.fill()
    }
}
