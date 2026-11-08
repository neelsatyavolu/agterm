import AgTermCore
import AppKit

/// Shell → Search Conversations… (⇧⌘F): finds past Claude Code, Codex and Grok conversations by
/// their text and reopens one in a new tab. Transcripts are read off the main thread into
/// `ConversationIndex`, which caches them on disk; nothing stays in memory once the window closes.
final class ConversationSearchWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = ConversationSearchWindow()

    /// Opens a tab in `folder` and types `command` at its first prompt.
    var openTab: ((_ folder: String, _ command: String) -> Void)?
    #if DEBUG
    /// Self-tests read fixture folders and keep their own cache.
    var rootsOverride: [ConversationRoot]?
    var cacheOverride: URL?
    #endif

    private var panel: NSPanel?
    private let field = NSTextField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "↑↓ choose   ⏎ resume   esc close")
    private let icon = NSImageView()
    private let line = NSView()

    private var records: [ConversationRecord] = []
    private var hits: [ConversationHit] = []
    private var reading: (done: Int, total: Int)?
    private var pendingSearch: DispatchWorkItem?
    /// Bumped by every new read or search and on close; work that sees a newer one stops.
    private let reads = Generation(), searches = Generation()
    private var readGeneration = 0
    private let readQueue = DispatchQueue(label: "agterm.conversation-index", qos: .utility)
    private let searchQueue = DispatchQueue(label: "agterm.conversation-search", qos: .userInitiated)
    /// Only touched on `readQueue`.
    private lazy var index = ConversationIndex(cacheURL: cacheURL)

    private var cacheURL: URL {
        #if DEBUG
        if let cacheOverride { return cacheOverride }
        #endif
        return AgentIntegration.supportDir.appendingPathComponent("conversation-search.plist")
    }

    // MARK: Showing

    func show(over parent: NSWindow?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        applyTheme()
        if !panel.isVisible {
            if let parent {
                let frame = parent.frame
                panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - panel.frame.height - 90))
            } else {
                panel.center()
            }
            field.stringValue = ""
            hits = []
            table.reloadData()
            read()
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close() { panel?.close() }

    func windowWillClose(_ notification: Notification) {        reads.bump()
        searches.bump()
        pendingSearch?.cancel()
        records = []
        hits = []
        table.reloadData()
        readQueue.async { [index] in index.unload() }
    }

    // MARK: Reading transcripts

    private func read() {
        let roots = Self.roots(), titles = Self.codexTitles()
        #if DEBUG
        let chosen = rootsOverride ?? roots
        #else
        let chosen = roots
        #endif
        let token = reads.bump()
        readGeneration = token
        reading = (0, 0)
        updateStatus()
        readQueue.async { [weak self, index, reads] in
            index.refresh(roots: chosen, codexTitles: titles, isCancelled: { reads.isStale(token) }) { records, done, total in
                DispatchQueue.main.async { self?.didRead(records, progress: (done, total), token: token) }
            }
            let records = index.records
            DispatchQueue.main.async { self?.didRead(records, progress: nil, token: token) }
        }
    }

    private func didRead(_ records: [ConversationRecord], progress: (done: Int, total: Int)?, token: Int) {
        guard panel?.isVisible == true, token == readGeneration else { return }
        self.records = records
        reading = progress
        search(delay: 0)
    }

    /// Your own folders, the default ones and each added login's, which mostly link to yours
    /// (the index reads a folder once).
    static func roots() -> [ConversationRoot] {
        AccountProvider.allCases.flatMap { provider -> [ConversationRoot] in
            let folder = provider == .claude ? "projects" : "sessions"
            let own = [AccountStore.nativeHome(provider), URL(fileURLWithPath: NSHomeDirectory() + "/." + provider.rawValue)]
                .map { ConversationRoot(agent: provider, url: $0.appendingPathComponent(folder), account: nil) }
            let logins = AccountStore.shared.accounts(provider).map {
                ConversationRoot(agent: provider, url: AccountStore.home($0.id).appendingPathComponent(folder), account: $0.id)
            }
            return own + logins
        }
    }

    /// Codex thread names: each login keeps its own session_index.jsonl.
    private static func codexTitles() -> [URL] {
        ([AccountStore.nativeCodexHome, URL(fileURLWithPath: NSHomeDirectory() + "/.codex")]
            + AccountStore.shared.accounts(.codex).map { AccountStore.home($0.id) })
            .map { $0.appendingPathComponent("session_index.jsonl") }
    }

    // MARK: Searching

    func controlTextDidChange(_ obj: Notification) { search(delay: 0.12) }

    private func search(delay: TimeInterval) {
        pendingSearch?.cancel()
        let query = field.stringValue, records = self.records
        let work = DispatchWorkItem { [weak self] in self?.run(query, in: records) }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func run(_ query: String, in records: [ConversationRecord]) {
        let token = searches.bump()
        let selected = hits.indices.contains(table.selectedRow) ? hits[table.selectedRow].record.path : nil
        var first = true
        searchQueue.async { [weak self, searches] in
            ConversationSearch.run(query, in: records, isCancelled: { searches.isStale(token) }) { batch in
                DispatchQueue.main.async {
                    guard let self, !searches.isStale(token) else { return }
                    // Results replace the old list as they arrive, newest first.
                    self.show(batch, replacing: first, keeping: selected)
                    first = false
                }
            }
            DispatchQueue.main.async {
                guard let self, !searches.isStale(token) else { return }
                if first { self.show([], replacing: true, keeping: nil) }
                self.updateStatus()
            }
        }
    }

    private func show(_ batch: [ConversationHit], replacing: Bool, keeping path: String?) {
        hits = replacing ? batch : hits + batch
        table.reloadData()
        let row = path.flatMap { path in hits.firstIndex { $0.record.path == path } } ?? (hits.isEmpty ? -1 : 0)
        if replacing || table.selectedRow < 0, row >= 0 { select(row) }
        updateStatus()
    }

    private func updateStatus() {
        let found = hits.count == 1 ? "1 conversation" : "\(hits.count.formatted()) conversations"
        if let reading, reading.total > 0 {
            status.stringValue = "Reading conversations… \(reading.done.formatted()) of \(reading.total.formatted())"
        } else if reading != nil, records.isEmpty {
            status.stringValue = "Reading conversations…"
        } else if records.isEmpty {
            status.stringValue = "No Claude Code, Codex or Grok conversations found"
        } else if hits.isEmpty {
            status.stringValue = "No conversations match"
        } else {
            status.stringValue = field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty ? "Recent: \(found)" : found
        }
    }

    // MARK: Choosing

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): select(table.selectedRow + 1)
        case #selector(NSResponder.moveUp(_:)): select(table.selectedRow - 1)
        case #selector(NSResponder.insertNewline(_:)): openSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func select(_ row: Int) {
        guard !hits.isEmpty else { return }
        let row = min(max(row, 0), hits.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func openSelected() {
        guard hits.indices.contains(table.selectedRow) else { return }
        let record = hits[table.selectedRow].record
        guard let command = ConversationResume.command(record) else { return NSSound.beep() }
        close()
        openTab?(record.folder ?? NSHomeDirectory(), command)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ConversationSearchRow.identifier, owner: self) as? ConversationSearchRow
            ?? ConversationSearchRow()
        cell.show(hits[row], query: field.stringValue)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { ConversationSearchRowBackground() }

    // MARK: Layout

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 480, height: 300)
        panel.delegate = self
        panel.title = "Search Conversations"
        for button in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 17)
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        line.wantsLayer = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = ConversationSearchRow.height
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.refusesFirstResponder = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        for label in [status, hint] { label.font = Theme.metaFont }
        hint.alignment = .right
        let content = NSView()
        for view in [icon, field, line, scroll, status, hint] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 34),
            line.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            line.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 14),
            line.heightAnchor.constraint(equalToConstant: 1),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: status.trailingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            hint.centerYAnchor.constraint(equalTo: status.centerYAnchor),
        ])
        panel.contentView = content
        return panel
    }

    private func applyTheme() {
        guard let panel else { return }
        panel.appearance = Theme.appearance
        panel.backgroundColor = Theme.color(Theme.palette.chrome)
        field.textColor = Theme.fg
        field.placeholderAttributedString = NSAttributedString(string: "Search past conversations", attributes: [
            .foregroundColor: Theme.fg3, .font: NSFont.systemFont(ofSize: 17),
        ])
        icon.contentTintColor = Theme.fg3
        line.layer?.backgroundColor = Theme.border.cgColor
        status.textColor = Theme.fg3
        hint.textColor = Theme.fg4
        let selected = table.selectedRow
        table.reloadData()
        if selected >= 0 { select(selected) }
    }

    #if DEBUG
    var panelForTest: NSPanel? { panel }
    var resultCountForTest: Int { hits.count }
    var statusForTest: String { status.stringValue }
    var selectedRowForTest: Int { table.selectedRow }
    func typeForTest(_ text: String) {
        field.stringValue = text
        search(delay: 0)
    }
    func openSelectedForTest() { openSelected() }
    #endif
}

/// A counter read from any thread: work started under an older value is stale.
private final class Generation {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func bump() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func isStale(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value != token
    }
}
