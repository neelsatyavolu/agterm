import AgTermCore
import AppKit

/// The Chat view's transcript: one read-only text view (so selection, copy and Find work across
/// rows). An update replaces only the text from the first changed row to the end. Only the
/// newest `window` rows are laid out; "Show earlier" adds older ones.
final class ChatTranscriptView: NSScrollView, NSTextViewDelegate {
    static let window = 300

    /// TextKit 1, for the text blocks that draw bands, cards and wells.
    private let textView = ChatTextView(usingTextLayoutManager: false)
    private(set) var rows: [ChatRow] = []
    /// Index of the first row shown.
    private(set) var first = 0
    /// The text length of each shown row, in order.
    private var lengths: [Int] = []
    /// The "Show earlier" line, or the empty-chat line; 0 when neither.
    private var headLength = 0
    private var expanded = Set<String>()
    /// Shown while there are no rows yet.
    var placeholder = "" { didSet { if rows.isEmpty, placeholder != oldValue { rebuild() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        borderType = .noBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 0, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.delegate = self
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        documentView = textView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `new`, re-rendering only from the first row that differs.
    func update(_ new: [ChatRow]) {
        guard let change = TimelineDiff.firstChange(from: rows, to: new) else { return }
        let wasEmpty = rows.isEmpty
        rows = new
        if wasEmpty || new.isEmpty || change < first || lengths.isEmpty {
            first = max(0, new.count - Self.window)
            return rebuild()
        }
        let start = headLength + lengths[..<min(change - first, lengths.count)].reduce(0, +)
        lengths.removeSubrange(min(change - first, lengths.count)...)
        let tail = NSMutableAttributedString()
        for row in new[change...] {
            let text = ChatRowText.render(row, expanded: expanded.contains(row.id))
            lengths.append(text.length)
            tail.append(text)
        }
        replace(NSRange(location: start, length: storage.length - start), with: tail)
        if following { scrollToBottom() }
    }

    /// Everything again: a theme or font change, or older rows added at the top.
    func rebuild() {
        let all = NSMutableAttributedString(attributedString: head())
        headLength = all.length
        lengths = []
        for row in rows[first...] {
            let text = ChatRowText.render(row, expanded: expanded.contains(row.id))
            lengths.append(text.length)
            all.append(text)
        }
        replace(NSRange(location: 0, length: storage.length), with: all)
        if following { scrollToBottom() }
    }

    private func head() -> NSAttributedString {
        if rows.isEmpty {
            return ChatRowText.line([(placeholder, Theme.fg3)], gap: ChatStyle.rowGap)
        }
        // TextKit drops the spacing above a document's first paragraph, which the first row's
        // box needs; a hairline-high first line keeps every row off index 0.
        guard first > 0 else { return NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 1)]) }
        return ChatRowText.line([("▴ Show \(min(first, Self.window)) earlier of \(first)", Theme.fg3)], gap: 4, toggle: "earlier")
    }

    private var storage: NSTextStorage { textView.textStorage! }
    /// The text's length, and the range the last update replaced (self-tests check it's the tail).
    var textLength: Int { storage.length }
    private(set) var lastReplaced = NSRange()

    private func replace(_ range: NSRange, with text: NSAttributedString) {
        lastReplaced = range
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: text)
        storage.endEditing()
    }

    // MARK: Expanding

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let link = link as? String, link.hasPrefix("toggle:") else { return false }
        let id = String(link.dropFirst("toggle:".count))
        if id == "earlier" {
            first = max(0, first - Self.window)
            let offset = contentView.bounds.maxY
            let height = textView.frame.height
            rebuild()
            // Keep the rows you were reading where they were.
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            contentView.scroll(to: NSPoint(x: 0, y: max(0, textView.frame.height - height + offset - contentView.bounds.height)))
            return true
        }
        toggle(id)
        return true
    }

    /// Expands or collapses one row, replacing only its text.
    func toggle(_ id: String) {
        guard let index = rows[first...].firstIndex(where: { $0.id == id }) else { return }
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        let slot = index - first
        let start = headLength + lengths[..<slot].reduce(0, +)
        let text = ChatRowText.render(rows[index], expanded: expanded.contains(id))
        replace(NSRange(location: start, length: lengths[slot]), with: text)
        lengths[slot] = text.length
    }

    // MARK: Scrolling and width

    /// Whether new rows scroll into view: until you scroll up, and again once you're back at the end.
    private(set) var following = true

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        following = isAtBottom
    }

    private var isAtBottom: Bool {
        contentView.bounds.maxY >= textView.frame.height - 40
    }

    func scrollToBottom() {
        following = true
        textView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: max(0, storage.length - 1), length: storage.length > 0 ? 1 : 0))
        textView.sizeToFit()
        contentView.scroll(to: NSPoint(x: 0, y: max(0, textView.frame.height - contentView.bounds.height)))
        reflectScrolledClipView(contentView)
    }

    /// The column is at most `maxColumns` wide, so long lines stay readable in a wide window.
    override func tile() {
        super.tile()
        let width = contentSize.width
        let column = min(width - 24, ChatStyle.indent + ChatStyle.maxColumns * ChatStyle.charWidth + 24)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: max(200, column), height: .greatestFiniteMagnitude)
        textView.minSize = NSSize(width: width, height: contentSize.height)
        textView.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if textView.frame.width != width { textView.setFrameSize(NSSize(width: width, height: textView.frame.height)) }
        // After the layout pass that resized the view, so the end is measured at the new size.
        if following { DispatchQueue.main.async { [weak self] in if self?.following == true { self?.scrollToBottom() } } }
    }
}
