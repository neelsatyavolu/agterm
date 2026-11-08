import AgTermCore
import AppKit

/// The tab the diff panel describes. `fingerprint` changes whenever git or the agent saw new
/// edits, which is when the panel reads git again; nothing is polled while it's closed.
struct DiffSource {
    let tabID: String
    let cwd: String
    let baseline: GitPoller.AgentBaseline?
    let hasAgent: Bool
    let fingerprint: String
}

/// The changes panel on the right of the terminal: pick Agent, Uncommitted or Branch, then a
/// file to see its diff.
final class DiffPanelView: NSView {
    static let defaultWidth: CGFloat = 480
    static let minWidth: CGFloat = 320
    static let scopeKey = "diffPanelScope"

    var onClose: (() -> Void)?
    /// The left edge was dragged by `dx` points (negative: wider).
    var onResize: ((CGFloat) -> Void)?

    private let scopes = NSSegmentedControl()
    private let summary = NSTextField(labelWithString: "")
    private let refresh = ToolbarButton(symbol: "arrow.clockwise")
    private let close = ToolbarButton(symbol: "xmark")
    private let split = NSSplitView()
    private let fileList = DiffFileListView()
    private let fileScroll = NSScrollView()
    private let lines = DiffLinesView()
    private let lineScroll = NSScrollView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let edge = ResizeEdge()

    private var source: DiffSource?
    private var listing: DiffListing?
    private var loadedKey: String?
    private var selectedPath: String?
    /// Results from an older request are dropped.
    private var generation = 0
    private var pending: DispatchWorkItem?

    private var scope: DiffScope {
        get { UserDefaults.standard.string(forKey: Self.scopeKey).flatMap(DiffScope.init(rawValue:)) ?? .agent }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.scopeKey) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        scopes.segmentCount = DiffScope.allCases.count
        for (index, scope) in DiffScope.allCases.enumerated() {
            scopes.setLabel(scope.title, forSegment: index)
            scopes.setToolTip(scope.help, forSegment: index)
            scopes.setWidth(0, forSegment: index)
        }
        scopes.trackingMode = .selectOne
        scopes.controlSize = .small
        scopes.segmentStyle = .rounded
        scopes.target = self
        scopes.action = #selector(scopeChanged)
        refresh.toolTip = "Read the changes again"
        refresh.onClick = { [weak self] in self?.reload(force: true) }
        close.toolTip = "Hide changes (⇧⌘E)"
        close.onClick = { [weak self] in self?.onClose?() }
        summary.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        summary.lineBreakMode = .byTruncatingTail
        message.font = NSFont.systemFont(ofSize: 12)
        message.alignment = .center
        message.isHidden = true

        for (scroll, document) in [(fileScroll, fileList as NSView), (lineScroll, lines as NSView)] {
            scroll.documentView = document
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.contentView.postsBoundsChangedNotifications = false
        }
        lineScroll.hasHorizontalScroller = true
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(fileScroll)
        split.addArrangedSubview(lineScroll)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        fileList.onSelect = { [weak self] index in self?.select(index) }
        edge.onDrag = { [weak self] dx in self?.onResize?(dx) }

        for view in [scopes, summary, refresh, close, split, message, edge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scopes.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            scopes.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            close.centerYAnchor.constraint(equalTo: scopes.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            refresh.centerYAnchor.constraint(equalTo: scopes.centerYAnchor),
            refresh.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -2),
            refresh.leadingAnchor.constraint(greaterThanOrEqualTo: scopes.trailingAnchor, constant: 8),
            summary.topAnchor.constraint(equalTo: scopes.bottomAnchor, constant: 8),
            summary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            split.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 6),
            split.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
            fileScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: DiffFileListView.rowHeight * 2),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            edge.leadingAnchor.constraint(equalTo: leadingAnchor),
            edge.widthAnchor.constraint(equalToConstant: 6),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refreshAppearance()
    }

    override func layout() {
        super.layout()
        fileList.resize()
        lines.resize()
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.bg.setFill()
        bounds.fill()
        Theme.border.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    func refreshAppearance() {
        summary.textColor = Theme.fg3
        message.textColor = Theme.fg3
        lines.refreshAppearance()
        [fileList, refresh, close, self].forEach { $0.needsDisplay = true }
    }

    // MARK: Loading

    /// Shows `source`, reading git again only if something changed since the last look.
    func show(_ source: DiffSource?) {
        let previousTab = self.source?.tabID
        self.source = source
        if source?.tabID != previousTab { selectedPath = nil }
        reload(force: false)
    }

    private func effectiveScope(_ source: DiffSource) -> DiffScope {
        scope == .agent && source.baseline == nil ? .uncommitted : scope
    }

    private func reload(force: Bool) {
        guard !isHidden else { return }
        guard let source else { return render(nil, error: .notRepo) }
        let scope = effectiveScope(source)
        scopes.selectedSegment = DiffScope.allCases.firstIndex(of: scope) ?? 0
        scopes.setEnabled(source.baseline != nil, forSegment: 0)
        let key = [source.tabID, source.fingerprint, scope.rawValue].joined(separator: "|")
        guard force || key != loadedKey else { return }
        loadedKey = key
        pending?.cancel()
        generation += 1
        let ticket = generation
        // Coalesces bursts (an agent saving many files) into one git run.
        let work = DispatchWorkItem { [weak self] in
            GitRunner.reads.async {
                let result = DiffLoader.list(cwd: source.cwd, scope: scope, baseline: source.baseline)
                DispatchQueue.main.async {
                    guard let self, ticket == self.generation else { return }
                    switch result {
                    case let .success(listing): self.render(listing, error: nil, force: force)
                    case let .failure(error): self.render(nil, error: error)
                    }
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (force ? 0 : 0.25), execute: work)
    }

    /// `force`: Refresh was pressed, so the open file's diff is read again even if the counts match.
    private func render(_ listing: DiffListing?, error: DiffError?, force: Bool = false) {
        let previous = self.listing
        self.listing = listing
        guard let listing else {
            split.isHidden = true
            summary.stringValue = ""
            message.isHidden = false
            message.stringValue = error?.message ?? ""
            return
        }
        let empty = listing.files.isEmpty
        split.isHidden = empty
        message.isHidden = !empty
        message.stringValue = "No changes \(listing.baseLabel)."
        let count = listing.files.count
        summary.stringValue = "\(count) file\(count == 1 ? "" : "s")  +\(listing.added) −\(listing.removed)  \(listing.baseLabel)"
        guard listing != previous || force else { return }
        fileList.files = listing.files
        let index = selectedPath.flatMap { path in listing.files.firstIndex { $0.path == path } } ?? (empty ? nil : 0)
        fileList.selected = index
        if let index { select(index) } else { lines.document = nil }
    }

    private func select(_ index: Int) {
        guard let listing, listing.files.indices.contains(index) else { return }
        let file = listing.files[index]
        selectedPath = file.path
        lines.path = file.path
        let ticket = generation
        GitRunner.reads.async { [weak self] in
            let document = DiffLoader.patch(listing, file)
            DispatchQueue.main.async { [weak self] in
                guard let self, ticket == self.generation, self.selectedPath == file.path else { return }
                self.lines.document = document
                self.lineScroll.contentView.scroll(to: .zero)
                self.lineScroll.reflectScrolledClipView(self.lineScroll.contentView)
            }
        }
    }

    @objc private func scopeChanged() {
        guard let picked = DiffScope.allCases[safe: scopes.selectedSegment] else { return }
        scope = picked
        reload(force: true)
    }

    // MARK: Self-test

    var summaryForTest: String { summary.stringValue }
    var fileCountForTest: Int { listing?.files.count ?? -1 }
}

/// The panel's left edge: drag to resize.
private final class ResizeEdge: NSView {
    var onDrag: ((CGFloat) -> Void)?
    private var last: CGFloat?

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { last = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) {
        guard let last else { return }
        onDrag?(event.locationInWindow.x - last)
        self.last = event.locationInWindow.x
    }
    override func mouseUp(with event: NSEvent) { last = nil }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
