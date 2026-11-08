import AgTermCore
import AppKit

/// Fonts, colors and paragraph shapes for the Chat view's transcript, all from `Theme`, so a
/// theme switch only needs the rows rendered again.
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

    static var text: NSColor { Theme.color(Theme.palette.fg, alpha: 0.88) }
    static var tint: NSColor { Theme.color(Theme.palette.fg, alpha: 0.07) }

    /// A paragraph style starting at `indent`, with `gap` above it and `after` below.
    static func paragraph(indent: CGFloat = ChatStyle.indent, hanging: CGFloat = 0, gap: CGFloat = 0,
                          after: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
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

    /// An agent's reply: markdown drawn as monospaced lines (`ChatText`).
    static func markdown(_ markdown: String, gap: CGFloat) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for (index, line) in ChatText.lines(markdown).enumerated() {
            let top = index == 0 ? gap : 0
            var style = paragraph(gap: top)
            switch line {
            case .text(let spans):
                out.append(spanned(spans, style))
            case .heading(let spans):
                style = paragraph(gap: max(top, 4))
                out.append(spanned(spans, style, bold: true))
            case .bullet(let indent, let marker, let spans):
                let mark = marker + " "
                style = paragraph(indent: Self.indent + CGFloat(indent) * 2 * charWidth, hanging: CGFloat(mark.count) * charWidth, gap: top)
                out.append(NSAttributedString(string: mark, attributes: attrs(Theme.fg3, font, style)))
                out.append(spanned(spans, style))
            case .quote(let spans):
                style = paragraph(hanging: 2 * charWidth, gap: top)
                out.append(NSAttributedString(string: "│ ", attributes: attrs(Theme.fg4, font, style)))
                out.append(spanned(spans, style, color: Theme.fg2))
            case .code(let lines):
                // One paragraph (lines split by U+2028), so the well is one box.
                style = paragraph(indent: indent + 10, gap: top + 12, after: 12)
                var code = attrs(Theme.fg, font, style)
                code[.chatBox] = ChatBox(fill: tint, left: indent, gapAbove: top + 6, bottomInset: 6)
                out.append(NSAttributedString(string: (lines.isEmpty ? " " : lines.joined(separator: "\u{2028}")) + "\n", attributes: code))
                continue
            case .tableRow(let row, let header):
                out.append(NSAttributedString(string: row, attributes: attrs(header ? Theme.fg : text, header ? boldFont : font, style)))
            case .blank:
                style = paragraph(gap: 0)
            }
            out.append(NSAttributedString(string: "\n", attributes: attrs(text, font, style)))
        }
        return out
    }

    private static func spanned(_ spans: [ChatSpan], _ style: NSParagraphStyle, bold: Bool = false, color: NSColor = text) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for span in spans {
            switch span.style {
            case .plain: out.append(NSAttributedString(string: span.text, attributes: attrs(color, bold ? boldFont : font, style)))
            case .bold: out.append(NSAttributedString(string: span.text, attributes: attrs(Theme.fg, boldFont, style)))
            case .code:
                var code = attrs(Theme.fg, font, style)
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

    init(fill: NSColor?, border: NSColor? = nil, left: CGFloat, gapAbove: CGFloat = 0, bottomInset: CGFloat = 0,
         fullWidth: Bool = false, radius: CGFloat = 6) {
        self.fill = fill
        self.border = border
        self.left = left
        self.gapAbove = gapAbove
        self.fullWidth = fullWidth
        self.radius = radius
        self.bottomInset = bottomInset
    }
}
