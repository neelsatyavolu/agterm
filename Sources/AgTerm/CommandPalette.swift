import AgTermCore
import AppKit

/// One thing the palette can do: a menu command or a tab to switch to.
struct PaletteEntry {
    let title: String
    /// The menu it's in, or the tab's folder.
    let detail: String
    let shortcut: String
    let run: () -> Void
}

/// ⇧⌘P: type a few letters of any menu command or open tab, ⏎ runs it. Opens at the top of the
/// terminal; ↑↓ (or ⌃P ⌃N, which the field editor sends as up and down) choose, esc or clicking
/// elsewhere closes it.
final class CommandPalette: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let width: CGFloat = 560
    static let rowHeight: CGFloat = 28
    static let visibleRows = 10

    /// Called after a choice runs or the palette is dismissed; the owner removes it and refocuses.
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let rule = NSBox()
    private let hint = NSTextField(labelWithString: "↑↓ choose   ⏎ run   esc close")
    private var tableHeight: NSLayoutConstraint!
    private var entries: [PaletteEntry] = []
    private(set) var results: [FuzzyMatch.Ranked<PaletteEntry>] = []
    private var closing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        self.shadow = shadow

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = .clear
        hint.font = Theme.metaFont

        let column = NSTableColumn(identifier: .init("entry"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        for view in [field, rule, scroll, hint] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        tableHeight = scroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            rule.heightAnchor.constraint(equalToConstant: 1),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 4),
            tableHeight,
            hint.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func refreshAppearance() {
        layer?.backgroundColor = Theme.color(Theme.palette.chrome).cgColor
        layer?.borderColor = Theme.border.cgColor
        rule.fillColor = Theme.border
        field.textColor = Theme.fg
        field.placeholderAttributedString = NSAttributedString(string: "Search commands and tabs", attributes: [
            .foregroundColor: Theme.fg3, .font: NSFont.systemFont(ofSize: 14),
        ])
        hint.textColor = Theme.fg3
        table.reloadData()
    }

    /// Opens empty with these entries, ready to type.
    func begin(_ entries: [PaletteEntry]) {
        self.entries = entries
        closing = false
        field.stringValue = ""
        filter()
        window?.makeFirstResponder(field)
    }

    #if DEBUG
    func selfTestType(_ text: String) {
        field.stringValue = text
        filter()
    }
    func selfTestRun() { runSelected() }
    #endif

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): move(-Self.visibleRows)
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): move(Self.visibleRows)
        default: return false
        }
        return true
    }

    func controlTextDidChange(_ obj: Notification) { filter() }

    /// Clicking anywhere else (the terminal, the tabs) closes it.
    func controlTextDidEndEditing(_ obj: Notification) { close() }

    private func filter() {
        results = FuzzyMatch.rank(field.stringValue, entries) { $0.title }
        table.reloadData()
        let rows = min(results.count, Self.visibleRows)
        tableHeight.constant = CGFloat(max(rows, 1)) * Self.rowHeight
        select(results.isEmpty ? -1 : 0)
    }

    private func move(_ step: Int) {
        guard !results.isEmpty else { return }
        select(min(max(table.selectedRow + step, 0), results.count - 1))
    }

    private func select(_ row: Int) {
        let previous = table.selectedRow
        if row < 0 { table.deselectAll(nil) } else {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        for index in [previous, row] where index >= 0 && index < results.count {
            (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? PaletteRow)?.isChosen = index == row
        }
    }

    @objc private func clicked() {
        guard table.clickedRow >= 0 else { return }
        select(table.clickedRow)
        runSelected()
    }

    private func runSelected() {
        guard results.indices.contains(table.selectedRow) else { return }
        let entry = results[table.selectedRow].item
        close()
        entry.run()
    }

    private func close() {
        guard !closing else { return }
        closing = true
        onClose?()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: PaletteRow.identifier, owner: nil) as? PaletteRow ?? PaletteRow()
        view.show(results[row], chosen: row == tableView.selectedRow)
        return view
    }
}

/// A result: its title with the typed letters in bold, then where it lives and its shortcut.
private final class PaletteRow: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("PaletteRow")
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")

    var isChosen = false {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingHead
        detail.font = .systemFont(ofSize: 12)
        shortcut.font = .systemFont(ofSize: 12)
        shortcut.alignment = .right
        for view in [title, detail, shortcut] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcut.leadingAnchor.constraint(greaterThanOrEqualTo: detail.trailingAnchor, constant: 10),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ result: FuzzyMatch.Ranked<PaletteEntry>, chosen: Bool) {
        let entry = result.item
        let matched = Set(result.match.positions)
        let text = NSMutableAttributedString()
        for (offset, character) in entry.title.enumerated() {
            let bold = matched.contains(offset)
            text.append(NSAttributedString(string: String(character), attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: bold ? .bold : .regular),
                .foregroundColor: Theme.fg,
            ]))
        }
        title.attributedStringValue = text
        detail.stringValue = entry.detail
        detail.textColor = Theme.fg3
        shortcut.stringValue = entry.shortcut
        shortcut.textColor = Theme.fg2
        isChosen = chosen
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isChosen else { return }
        Theme.color(Theme.palette.accent, alpha: 0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}
