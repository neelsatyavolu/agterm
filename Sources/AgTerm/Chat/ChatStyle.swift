import AgTermCore
import AppKit

/// Fonts, colors and paragraph shapes for the Chat view's transcript, all from `Theme`, so a
/// theme switch only needs the rows rendered again. What people read (your messages, the
/// agent's replies) is in the system font; what they scan (steps, code, paths, numbers) stays
/// in the terminal font.
enum ChatStyle {
    /// Where row text starts: room for a `›` or status glyph before it.
    static let indent: CGFloat = 32
    /// The widest the transcript column gets, in characters.
    static let maxColumns: CGFloat = 100
    static let rowGap: CGFloat = 14

    static var font: NSFont { Theme.terminalFont }
    static var smallFont: NSFont { Theme.terminalFont(family: Theme.settings.fontFamily, size: max(9, font.pointSize - 1)) }
    static var boldFont: NSFont { NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
    static var charWidth: CGFloat { ("M" as NSString).size(withAttributes: [.font: font]).width }

    /// Replies and your messages: the system font, a point above the terminal font.
    static var prose: NSFont { NSFont.systemFont(ofSize: max(12, font.pointSize + 1)) }
    static var proseBold: NSFont { NSFont.systemFont(ofSize: prose.pointSize, weight: .semibold) }
    static var heading: NSFont { NSFont.systemFont(ofSize: prose.pointSize + 2, weight: .semibold) }
    /// Code inside prose: the terminal font, sized to sit on the prose line.
    static var inlineCode: NSFont { Theme.terminalFont(family: Theme.settings.fontFamily, size: max(10, prose.pointSize - 1.5)) }
    /// Extra space between wrapped prose lines.
    static let proseLeading: CGFloat = 3.5

    static var text: NSColor { Theme.color(Theme.palette.fg, alpha: 0.88) }
    static var tint: NSColor { Theme.color(Theme.palette.fg, alpha: 0.07) }

    /// A paragraph style starting at `indent`, with `gap` above it and `after` below.
    static func paragraph(indent: CGFloat = ChatStyle.indent, hanging: CGFloat = 0, gap: CGFloat = 0,
                          after: CGFloat = 0, leading: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = leading
        style.firstLineHeadIndent = indent
        style.headIndent = indent + hanging
        style.paragraphSpacingBefore = gap
        style.paragraphSpacing = after
        style.lineBreakMode = .byWordWrapping
        return style
    }

    static func attrs(_ color: NSColor, _ font: NSFont = ChatStyle.font, _ paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    /// `0.6s`, `12s`, `2m 5s`.
    static func duration(_ ms: Int?) -> String? {
        guard let ms, ms > 0 else { return nil }
        if ms < 10_000 { return String(format: "%.1fs", Double(ms) / 1000) }
        let seconds = ms / 1000
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    // MARK: Markdown

    /// An agent's reply: markdown (`ChatText`) in the system font, with code in the terminal font.
    static func markdown(_ markdown: String, gap: CGFloat) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        let leading = proseLeading
        for (index, line) in ChatText.lines(markdown).enumerated() {
            let top = index == 0 ? gap : 0
            var style = paragraph(gap: top, leading: leading)
            switch line {
            case .text(let spans):
                out.append(spanned(spans, style))
            case .heading(let spans):
                style = paragraph(gap: max(top, 8), after: 2, leading: leading)
                out.append(spanned(spans, style, font: heading))
            case .bullet(let indent, let marker, let spans):
                let mark = (marker == "-" || marker == "*" ? "•" : marker) + "  "
                let width = (mark as NSString).size(withAttributes: [.font: prose]).width
                let start = Self.indent + CGFloat(indent) * 2 * charWidth
                style = paragraph(indent: start, hanging: width, gap: top + 2, leading: leading)
                out.append(NSAttributedString(string: mark, attributes: attrs(Theme.fg3, prose, style)))
                out.append(spanned(spans, style))
            case .quote(let spans):
                style = paragraph(indent: Self.indent + 14, gap: top, leading: leading)
                var quote = NSMutableAttributedString(attributedString: spanned(spans, style, color: Theme.fg2))
                quote = quote.length > 0 ? quote : NSMutableAttributedString(string: " ", attributes: attrs(Theme.fg2, prose, style))
                quote.addAttribute(.chatLineBox, value: ChatBox(fill: Theme.fg4, left: 0, width: 2, radius: 0),
                                   range: NSRange(location: 0, length: quote.length))
                out.append(quote)
            case .code(let lines):
                // One paragraph (lines split by U+2028), so the well is one box.
                style = paragraph(indent: indent + 12, gap: top + 14, after: 12)
                var code = attrs(Theme.fg, smallFont, style)
                code[.chatBox] = ChatBox(fill: tint, left: indent, gapAbove: top + 6, bottomInset: 4)
                out.append(NSAttributedString(string: (lines.isEmpty ? " " : lines.joined(separator: "\u{2028}")) + "\n", attributes: code))
                continue
            case .tableRow(let row, let header):
                out.append(NSAttributedString(string: row, attributes: attrs(header ? Theme.fg : text, header ? boldFont : smallFont, style)))
            case .blank:
                style = paragraph(gap: 0)
                out.append(NSAttributedString(string: "\n", attributes: attrs(text, NSFont.systemFont(ofSize: max(6, prose.pointSize * 0.5)), style)))
                continue
            }
            out.append(NSAttributedString(string: "\n", attributes: attrs(text, prose, style)))
        }
        return out
    }

    private static func spanned(_ spans: [ChatSpan], _ style: NSParagraphStyle, font: NSFont = prose,
                                color: NSColor = text) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let bold = font == prose ? proseBold : font
        for span in spans {
            switch span.style {
            case .plain: out.append(NSAttributedString(string: span.text, attributes: attrs(color, font, style)))
            case .bold: out.append(NSAttributedString(string: span.text, attributes: attrs(Theme.fg, bold, style)))
            case .code:
                var code = attrs(Theme.fg, inlineCode, style)
                code[.backgroundColor] = tint
                out.append(NSAttributedString(string: span.text, attributes: code))
            }
        }
        return out
    }
}

extension NSAttributedString.Key {
    /// A `ChatBox` behind a run of paragraphs: a card, a well, the user's band.
    static let chatBox = NSAttributedString.Key("agterm.chatBox")
    /// A `ChatBox` inside a card: its header, a diff line's tint.
    static let chatLineBox = NSAttributedString.Key("agterm.chatLineBox")
    /// The thin rule beside a finished turn's opened steps.
    static let chatRail = NSAttributedString.Key("agterm.chatRail")
}

/// A rectangle drawn behind the paragraphs carrying it (`ChatTextView`); a full-width one is a band
/// with hairlines above and below. Paragraph spacing gives
/// it room above and below the text; `gapAbove` of the first paragraph's spacing stays outside.
final class ChatBox: NSObject {
    let fill: NSColor?
    let border: NSColor?
    /// Where it starts; `fullWidth` boxes run to the view's edge, the others to the column's.
    let left: CGFloat
    let gapAbove: CGFloat
    /// Of the last paragraph's spacing below, how much stays outside.
    let bottomInset: CGFloat
    let fullWidth: Bool
    let radius: CGFloat
    /// A fixed width (a quote's or a step list's rule) instead of running to the column's edge.
    let width: CGFloat?
    /// Fits the text it holds, this far around it (your message's bubble), instead of the column.
    let hug: NSSize?

    init(fill: NSColor?, border: NSColor? = nil, left: CGFloat, gapAbove: CGFloat = 0, bottomInset: CGFloat = 0,
         fullWidth: Bool = false, width: CGFloat? = nil, hug: NSSize? = nil, radius: CGFloat = 6) {
        self.width = width
        self.hug = hug
        self.fill = fill
        self.border = border
        self.left = left
        self.gapAbove = gapAbove
        self.fullWidth = fullWidth
        self.radius = radius
        self.bottomInset = bottomInset
    }

    /// The same box starting `dx` further right.
    func moved(by dx: CGFloat) -> ChatBox {
        ChatBox(fill: fill, border: border, left: left + dx, gapAbove: gapAbove, bottomInset: bottomInset, fullWidth: fullWidth,
                width: width, hug: hug, radius: radius)
    }
}
