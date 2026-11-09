import AgTermCore
import AppKit

/// The composer's `/` menu: the commands matching what you typed, the matched letters in the
/// accent, each with what it does. ↑↓ move, ⇥ fills the name in, ⏎ runs it, a click fills it in.
/// The `@` menu of files uses it too.
final class ChatSlashMenu: NSView {
    private(set) var items: [SlashCommand] = []
    private(set) var selected = 0
    /// The first row shown, when there are more matches than rows.
    private var top = 0
    private var query = ""
    /// `/` before commands, `@` before paths.
    private var prefix = "/"
    var onChoose: (SlashCommand) -> Void = { _ in }

    static var rowHeight: CGFloat { ceil(ChatStyle.font.ascender - ChatStyle.font.descender + ChatStyle.font.leading) + 6 }
    static let padding: CGFloat = 4

    var rowCount: Int { min(items.count, SlashMenu.maxRows) }
    var fittingHeight: CGFloat { items.isEmpty ? 0 : CGFloat(rowCount) * Self.rowHeight + Self.padding * 2 }
    var current: SlashCommand? { items.indices.contains(selected) ? items[selected] : nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        applyAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyAppearance() {
        layer?.backgroundColor = Theme.color(Theme.palette.bg.mixed(with: Theme.palette.fg, 0.05)).cgColor
        layer?.borderColor = Theme.color(Theme.palette.fg, alpha: 0.14).cgColor
        needsDisplay = true
    }

    func show(_ items: [SlashCommand], query: String, prefix: String) {
        self.prefix = prefix
        // A new catalog for the same query keeps the row you were on; new letters start at the top.
        let keep = query == self.query ? current?.name : nil
        self.items = items
        self.query = query
        selected = keep.flatMap { name in items.firstIndex { $0.name == name } } ?? 0
        top = 0
        reveal()
        needsDisplay = true
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
        reveal()
        needsDisplay = true
    }

    private func reveal() {
        if selected < top { top = selected }
        if selected >= top + SlashMenu.maxRows { top = selected - SlashMenu.maxRows + 1 }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = Int((point.y - Self.padding) / Self.rowHeight) + top
        guard items.indices.contains(row) else { return }
        selected = row
        onChoose(items[row])
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = ChatStyle.font, bold = ChatStyle.boldFont
        let rows = Array(items.enumerated().dropFirst(top).prefix(SlashMenu.maxRows))
        let nameWidth = min(bounds.width * 0.45,
                            rows.map { (prefix + $0.element.name as NSString).size(withAttributes: [.font: bold]).width }.max() ?? 0)
        for (line, (index, item)) in rows.enumerated() {
            let rect = NSRect(x: 4, y: Self.padding + CGFloat(line) * Self.rowHeight, width: bounds.width - 8, height: Self.rowHeight)
            if index == selected {
                Theme.color(Theme.palette.fg, alpha: 0.08).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            let textY = rect.minY + (rect.height - (font.ascender - font.descender)) / 2
            let name = self.name(item, selected: index == selected)
            name.draw(with: NSRect(x: rect.minX + 10, y: textY, width: nameWidth, height: rect.height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            let aboutX = rect.minX + 10 + nameWidth + 24
            guard aboutX < rect.maxX - 40, !item.about.isEmpty else { continue }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: item.about, attributes: [.font: font, .foregroundColor: Theme.fg3, .paragraphStyle: style])
                .draw(with: NSRect(x: aboutX, y: textY, width: rect.maxX - 10 - aboutX, height: rect.height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// `/workflows` (or `@Sources/main.swift`) with the letters the query matched in bold accent.
    private func name(_ item: SlashCommand, selected: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let text = NSMutableAttributedString(string: prefix + item.name, attributes: [
            .font: ChatStyle.font, .foregroundColor: selected ? Theme.fg : Theme.fg2, .paragraphStyle: style,
        ])
        let positions = FuzzyMatch.match(query, in: item.name)?.positions ?? []
        let characters = Array(item.name)
        var offset = (prefix as NSString).length
        for (index, character) in characters.enumerated() {
            let length = String(character).utf16.count
            if positions.contains(index) {
                text.addAttributes([.font: ChatStyle.boldFont, .foregroundColor: Theme.accent], range: NSRange(location: offset, length: length))
            }
            offset += length
        }
        return text
    }

    override var isFlipped: Bool { true }
}
