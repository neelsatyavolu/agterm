import AgTermCore
import AppKit

/// Edit cards and command rows of the transcript.
enum ChatCardText {
    /// `Edit  path  +a −r` over its diff lines, at most `ChatRows.editPreviewLines` until expanded.
    static func edit(_ edit: ChatEdit, expanded: Bool, gap: CGFloat) -> NSAttributedString {
        let left = ChatStyle.indent, inner = left + 12
        let card = ChatBox(fill: nil, border: Theme.border, left: left, gapAbove: gap, radius: 8)
        let small = ChatStyle.smallFont
        let out = NSMutableAttributedString()

        let head = NSMutableAttributedString()
        let headStyle = ChatStyle.paragraph(indent: inner, hanging: 2 * ChatStyle.charWidth, gap: gap + 6, after: 6)
        for (text, color, font) in [(edit.verb, Theme.fg, NSFontManager.shared.convert(small, toHaveTrait: .boldFontMask)),
                                    ("  " + edit.path, Theme.fg2, small), ("  +\(edit.additions)", Theme.ok, small),
                                    (" −\(edit.deletions)", Theme.danger, small), ("\n", Theme.fg, small)] {
            head.append(NSAttributedString(string: text, attributes: ChatStyle.attrs(color, font, headStyle)))
        }
        head.addAttribute(.chatLineBox, value: ChatBox(fill: Theme.color(Theme.palette.fg, alpha: 0.04), left: left, gapAbove: gap, radius: 0),
                          range: NSRange(location: 0, length: head.length))
        out.append(head)

        let lines = expanded ? edit.lines[...] : edit.preview
        let more = edit.hiddenLines > 0 || (expanded && edit.lines.count > ChatRows.editPreviewLines)
        for (index, line) in lines.enumerated() {
            let (sign, fill, color): (String, NSColor?, NSColor) = switch line.kind {
            case .added: ("+ ", Theme.ok.withAlphaComponent(0.12), Theme.ok)
            case .removed: ("− ", Theme.danger.withAlphaComponent(0.12), Theme.danger)
            case .context: ("  ", nil, Theme.fg3)
            }
            let top: CGFloat = index == 0 ? 4 : 0, bottom: CGFloat = index == lines.count - 1 && !more ? 6 : 0
            let style = ChatStyle.paragraph(indent: inner, hanging: 2 * ChatStyle.charWidth, gap: top, after: bottom)
            let row = NSMutableAttributedString(string: sign, attributes: ChatStyle.attrs(color, small, style))
            row.append(NSAttributedString(string: (line.text.isEmpty ? " " : ChatRowText.timelineCut(line.text, 2_000)) + "\n",
                                          attributes: ChatStyle.attrs(line.kind == .context ? Theme.fg3 : ChatStyle.text, small, style)))
            if let fill {
                row.addAttribute(.chatLineBox, value: ChatBox(fill: fill, left: left + 1, gapAbove: top, radius: 0),
                                 range: NSRange(location: 0, length: row.length))
            }
            out.append(row)
        }
        if more {
            let style = ChatStyle.paragraph(indent: inner, gap: 4, after: 6)
            let label = expanded ? "▴ fewer lines" : "… \(edit.hiddenLines) more lines"
            out.append(NSAttributedString(string: label, attributes: ChatStyle.attrs(Theme.fg3, small, style).merging([.link: "toggle:" + edit.id]) { $1 }))
            out.append(NSAttributedString(string: "\n", attributes: ChatStyle.attrs(Theme.fg3, small, style)))
        }
        out.addAttribute(.chatBox, value: card, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// `✓ $ cmd  first line  1.2s`, or `✕ $ cmd` over its error output.
    static func command(_ command: ChatCommand, expanded: Bool, gap: CGFloat, indent: CGFloat = ChatStyle.indent) -> NSAttributedString {
        let (glyph, color): (String, NSColor) = switch command.status {
        case .running: ("◐", Theme.accent)
        case .error: ("✕", Theme.danger)
        case .ok: ("✓", Theme.ok)
        }
        let hasOutput = !(command.output ?? "").isEmpty
        var parts: [(String, NSColor)] = [(glyph + " ", color), ("$ ", Theme.fg3), (ChatRowText.timelineCut(command.command, 300), Theme.fg)]
        if command.status == .ok, let summary = command.summary { parts.append(("  " + summary, Theme.fg3)) }
        if let time = ChatStyle.duration(command.durationMs) { parts.append(("  " + time, Theme.fg3)) }
        let canExpand = command.status == .ok && hasOutput
        if canExpand { parts.append((expanded ? "  ▾" : "  ▸", Theme.fg3)) }
        let out = NSMutableAttributedString(attributedString: ChatRowText.line(parts, gap: gap, toggle: canExpand ? command.id : nil, indent: indent))
        if command.status == .error, hasOutput {
            var lines = expanded ? Array((command.output ?? "").components(separatedBy: "\n").prefix(ChatRowText.bodyLines)) : command.errorLines
            if !expanded, command.hiddenErrorLines > 0 { lines.append("… \(command.hiddenErrorLines) more lines") }
            out.append(well(lines, color: Theme.danger, toggle: command.hiddenErrorLines > 0 ? command.id : nil))
        } else if expanded, let output = command.output {
            out.append(ChatRowText.body(output, color: Theme.fg2))
        }
        return out
    }

    /// Output in a tinted well under its row.
    static func well(_ lines: [String], color: NSColor, toggle: String? = nil) -> NSAttributedString {
        let style = ChatStyle.paragraph(indent: ChatStyle.indent + 10, gap: 4 + 6, after: 6)
        let text = lines.map { ChatRowText.timelineCut($0, 2_000) }.joined(separator: "\u{2028}")
        var attributes = ChatStyle.attrs(ChatStyle.text, ChatStyle.smallFont, style)
        attributes[.chatBox] = ChatBox(fill: color.withAlphaComponent(0.10), left: ChatStyle.indent, gapAbove: 4)
        let out = NSMutableAttributedString(string: (text.isEmpty ? " " : text) + "\n", attributes: attributes)
        if let toggle { out.addAttribute(.link, value: "toggle:" + toggle, range: NSRange(location: 0, length: out.length - 1)) }
        return out
    }
}
