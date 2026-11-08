import AgTermCore
import AppKit

/// One search result: the agent's logo, the conversation's title and date, its folder (and the
/// login it's on, when that's not yours), and the text around the match with your words marked.
final class ConversationSearchRow: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("ConversationSearchRow")
    static let height: CGFloat = 66

    private let logo = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let date = NSTextField(labelWithString: "")
    private let place = NSTextField(labelWithString: "")
    private let snippet = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        title.font = Theme.topicFont
        for label in [date, place] { label.font = Theme.metaFont }
        snippet.font = .systemFont(ofSize: 12)
        for label in [title, snippet] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        // A long folder keeps its last part, the one you'd recognize.
        place.lineBreakMode = .byTruncatingMiddle
        place.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        date.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [logo, title, date, place, snippet] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            logo.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            logo.widthAnchor.constraint(equalToConstant: 16),
            logo.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            date.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            date.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            date.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            place.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            place.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            place.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            snippet.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            snippet.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            snippet.topAnchor.constraint(equalTo: place.bottomAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ hit: ConversationHit, query: String) {
        let record = hit.record
        logo.image = AgentLogo.image(for: record.agent.rawValue)
        title.stringValue = record.displayTitle
        title.textColor = Theme.fg
        date.stringValue = Self.when(record.modified)
        date.textColor = Theme.fg3
        var location = record.folder.map(Self.tilde) ?? "Unknown folder"
        if let account = record.account {
            location += " · " + (AccountStore.shared.account(account)?.label ?? "another login")
        }
        place.stringValue = location
        place.textColor = Theme.fg3
        // With no match in the text (or no query), the opening prompt says what it was about.
        let body = hit.snippet.isEmpty && record.firstPrompt != record.displayTitle ? record.firstPrompt ?? "" : hit.snippet
        snippet.attributedStringValue = Self.marked(body, words: query.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// `text` in the secondary color with each of `words` in the main one, semibold.
    static func marked(_ text: String, words: [String]) -> NSAttributedString {
        let out = NSMutableAttributedString(string: text, attributes: [.foregroundColor: Theme.fg2, .font: NSFont.systemFont(ofSize: 12)])
        let whole = text as NSString
        for word in words where !word.isEmpty {
            var range = NSRange(location: 0, length: whole.length)
            while true {
                let found = whole.range(of: word, options: .caseInsensitive, range: range)
                guard found.location != NSNotFound else { break }
                out.addAttributes([.foregroundColor: Theme.fg, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)], range: found)
                range = NSRange(location: found.upperBound, length: whole.length - found.upperBound)
            }
        }
        return out
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The time today, the weekday this week, else the date.
    static func when(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 6 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month(.abbreviated).day()) }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The selected result: a soft accent fill that keeps every color in the row readable.
final class ConversationSearchRowBackground: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        Theme.color(Theme.palette.accent, alpha: 0.16).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}
