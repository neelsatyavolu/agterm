import AgTermCore
import AppKit

/// One `ChatRow` as transcript text. Collapsed parts (thinking, folded tools, long diffs and
/// outputs) aren't built until their row is expanded; clicking a `▸` line toggles it through a
/// `toggle:<row id>` link.
enum ChatRowText {
    /// Lines and characters an expanded tool body shows at most.
    static let bodyLines = 60
    static let bodyChars = 8_000

    /// `open`: the ids of the expanded rows, and of the expanded commands inside a folded run.
    static func render(_ row: ChatRow, open: Set<String>) -> NSAttributedString {
        let gap = ChatStyle.rowGap
        let expanded = open.contains(row.id)
        switch row {
        case .user(_, let text, let queued):
            return user(text, queued: queued, gap: gap)
        case .assistant(_, let text, let streaming):
            let out = ChatStyle.markdown(text.isEmpty ? " " : text, gap: gap)
            if streaming { appendCursor(out) }
            return out
        case .thinking(let id, let text):
            let out = NSMutableAttributedString()
            // Claude often keeps its thinking to itself (signed but empty): a plain line, nothing to open.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return line([("▸ thinking", Theme.fg3)], gap: gap) }
            out.append(line([("\(expanded ? "▾" : "▸") thinking", Theme.fg3)], gap: gap, toggle: id))
            if expanded { out.append(body(text, color: Theme.fg3)) }
            return out
        case .tools(let id, let tools, let durationMs):
            return toolGroup(id: id, tools: tools, durationMs: durationMs, expanded: expanded, gap: gap)
        case .edit(let edit):
            return ChatCardText.edit(edit, expanded: expanded, gap: gap)
        case .command(let command):
            return ChatCardText.command(command, expanded: expanded, gap: gap)
        case .commands(let id, let commands, let durationMs):
            return commandGroup(id: id, commands: commands, durationMs: durationMs, expanded: expanded, open: open, gap: gap)
        case .tool(let tool):
            return single(tool, expanded: expanded, gap: gap)
        case .agent(let agent):
            return subagent(agent, expanded: expanded, gap: gap)
        case .interrupted:
            return line([("■ interrupted", Theme.danger)], gap: gap)
        case .worked(let id, let rows, let durationMs):
            return worked(id: id, rows: rows, durationMs: durationMs, open: open, gap: gap)
        case .changes(_, let edits):
            return changes(edits, open: open, gap: gap)
        }
    }

    /// The reply ends with a block cursor while the agent is still writing it.
    private static func appendCursor(_ out: NSMutableAttributedString) {
        let end = out.length > 0 && out.string.hasSuffix("\n") ? out.length - 1 : out.length
        let style = end > 0 ? out.attribute(.paragraphStyle, at: end - 1, effectiveRange: nil) as? NSParagraphStyle : nil
        out.insert(NSAttributedString(string: " ▌", attributes: ChatStyle.attrs(Theme.fg, ChatStyle.font, style ?? ChatStyle.paragraph())), at: end)
    }

    // MARK: Rows

    /// Your message: a bubble on the right, fitted to the text, in the system font. A message
    /// still in the agent's queue is dimmed and says so.
    private static func user(_ text: String, queued: Bool, gap: CGFloat) -> NSAttributedString {
        let pad = NSSize(width: 14, height: 9)
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.firstLineHeadIndent = ChatStyle.indent + 64
        style.headIndent = ChatStyle.indent + 64
        style.tailIndent = -pad.width
        style.paragraphSpacingBefore = gap + 16 + pad.height
        style.paragraphSpacing = pad.height + 6
        style.lineSpacing = ChatStyle.proseLeading
        style.lineBreakMode = .byWordWrapping
        let body = text.isEmpty ? " " : text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "\u{2028}")
        let out = NSMutableAttributedString(string: body, attributes: ChatStyle.attrs(queued ? Theme.fg3 : Theme.fg, ChatStyle.prose, style))
        if queued { out.append(NSAttributedString(string: "\u{2028}queued", attributes: ChatStyle.attrs(Theme.fg3, ChatStyle.smallFont, style))) }
        out.append(NSAttributedString(string: "\n", attributes: ChatStyle.attrs(Theme.fg, ChatStyle.prose, style)))
        let bubble = ChatBox(fill: Theme.color(Theme.palette.fg, alpha: Theme.palette.isDark ? 0.075 : 0.055),
                             border: queued ? Theme.border : nil, left: 0, hug: pad, radius: 10)
        out.addAttribute(.chatBox, value: bubble, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// `▸ Worked 1m 12s · thought · read 3 · edited 2 · ran 1`; opened, the turn's steps, indented
    /// beside a thin rule, each opening on its own as it does while the turn runs.
    private static func worked(id: String, rows: [ChatRow], durationMs: Int?, open: Set<String>, gap: CGFloat) -> NSAttributedString {
        let expanded = open.contains(id)
        var parts: [(String, NSColor)] = [("\(expanded ? "▾" : "▸") ", Theme.fg3), ("Worked", Theme.fg2)]
        if let time = ChatStyle.duration(durationMs) { parts.append((" " + time, Theme.fg2)) }
        for part in ChatTurns.summary(rows) {
            parts.append((" · ", Theme.fg4))
            parts.append((part, part.hasSuffix("failed") ? Theme.danger : Theme.fg3))
        }
        let out = NSMutableAttributedString(attributedString: line(parts, gap: gap, toggle: id, font: ChatStyle.smallFont))
        guard expanded else { return out }
        let steps = NSMutableAttributedString()
        for row in rows { steps.append(render(row, open: open)) }
        let shift: CGFloat = 16
        out.append(shifted(steps, by: shift))
        out.addAttribute(.chatRail, value: ChatBox(fill: Theme.border, left: 4, width: 1, radius: 0),
                         range: NSRange(location: out.length - steps.length, length: steps.length))
        return out
    }

    /// `2 files changed` over a row per file (`auth/redirect.ts  +4 −1 ▸`), each opening to its diff.
    private static func changes(_ edits: [ChatEdit], open: Set<String>, gap: CGFloat) -> NSAttributedString {
        let small = ChatStyle.smallFont
        let out = NSMutableAttributedString(attributedString: line([("\(edits.count) file\(edits.count == 1 ? "" : "s") changed", Theme.fg3)],
                                                                   gap: gap + 4, font: small))
        for edit in edits {
            let id = ChatTurns.fileID(edit)
            let expanded = open.contains(id)
            var parts: [(String, NSColor)] = [(expanded ? "▾ " : "▸ ", Theme.fg3), (edit.path, Theme.fg)]
            if edit.verb == "Write" { parts.append(("  new", Theme.fg3)) }
            if edit.verb == "Delete" { parts.append(("  deleted", Theme.fg3)) }
            parts.append(("  +\(edit.additions)", Theme.ok))
            parts.append((" −\(edit.deletions)", Theme.danger))
            out.append(line(parts, gap: 3, toggle: id, font: small))
            if expanded {
                out.append(ChatCardText.edit(edit.capped(bodyLines * 2), expanded: true, gap: 6, toggle: id))
            }
        }
        return out
    }

    /// The same text moved `dx` to the right: its paragraphs, and the boxes drawn behind them.
    static func shifted(_ text: NSAttributedString, by dx: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        let all = NSRange(location: 0, length: out.length)
        out.enumerateAttribute(.paragraphStyle, in: all) { value, range, _ in
            guard let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle else { return }
            style.firstLineHeadIndent += dx
            style.headIndent += dx
            out.addAttribute(.paragraphStyle, value: style, range: range)
        }
        for key in [NSAttributedString.Key.chatBox, .chatLineBox] {
            out.enumerateAttribute(key, in: all) { value, range, _ in
                guard let box = value as? ChatBox else { return }
                out.addAttribute(key, value: box.moved(by: dx), range: range)
            }
        }
        return out
    }

    private static func toolGroup(id: String, tools: [ChatTool], durationMs: Int?, expanded: Bool, gap: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var parts: [(String, NSColor)] = [("\(expanded ? "▾" : "▸") \(tools.count) tool\(tools.count == 1 ? "" : "s")", Theme.fg2)]
        if !expanded { parts.append(("  " + timelineCut(ChatRows.summary(tools), 160), Theme.fg3)) }
        if let time = ChatStyle.duration(durationMs) { parts.append(("  " + time, Theme.fg3)) }
        out.append(line(parts, gap: gap, toggle: id))
        if expanded {
            for tool in tools { out.append(line([("  " + tool.label, Theme.fg3)], gap: 2)) }
        }
        return out
    }

    /// `▸ Ran 3 shell commands  14s`; opened, each command on its own row, which opens to its output.
    private static func commandGroup(id: String, commands: [ChatCommand], durationMs: Int?, expanded: Bool, open: Set<String>,
                                     gap: CGFloat) -> NSAttributedString {
        var parts: [(String, NSColor)] = [("\(expanded ? "▾" : "▸") Ran \(commands.count) shell command\(commands.count == 1 ? "" : "s")", Theme.fg2)]
        if let time = ChatStyle.duration(durationMs) { parts.append(("  " + time, Theme.fg3)) }
        let out = NSMutableAttributedString(attributedString: line(parts, gap: gap, toggle: id))
        if expanded {
            for command in commands {
                out.append(ChatCardText.command(command, expanded: open.contains(command.id), gap: 4,
                                                indent: ChatStyle.indent + 2 * ChatStyle.charWidth))
            }
        }
        return out
    }

    private static func single(_ tool: ChatTool, expanded: Bool, gap: CGFloat) -> NSAttributedString {
        let (glyph, color) = statusGlyph(tool.status)
        let canExpand = tool.status != .error && !(tool.body ?? "").isEmpty
        var parts: [(String, NSColor)] = [(glyph + " ", color), (tool.lead, Theme.fg)]
        if let subject = tool.subject, !subject.isEmpty { parts.append((" " + timelineCut(subject, 200), Theme.fg2)) }
        if let detail = tool.detail, !detail.isEmpty { parts.append(("  " + timelineCut(detail, 120), Theme.fg3)) }
        if canExpand { parts.append((expanded ? "  ▾" : "  ▸", Theme.fg3)) }
        let out = NSMutableAttributedString(attributedString: line(parts, gap: gap, toggle: canExpand ? tool.id : nil))
        if tool.status == .error, let body = tool.body, !body.isEmpty {
            out.append(ChatCardText.well(Array(body.components(separatedBy: "\n").prefix(ChatRows.errorPreviewLines)), color: Theme.danger))
        } else if expanded, let body = tool.body {
            out.append(Self.body(body, color: Theme.fg2))
        }
        return out
    }

    /// `◐ Agent Review the branch  code-reviewer  2m 5s ▸`; opened, the agent's answer as markdown.
    private static func subagent(_ agent: ChatAgent, expanded: Bool, gap: CGFloat) -> NSAttributedString {
        let (glyph, color) = statusGlyph(agent.status)
        let result = agent.result.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let canExpand = agent.status != .error && result != nil
        var parts: [(String, NSColor)] = [(glyph + " ", color), (agent.label, Theme.fg)]
        if let title = agent.title, !title.isEmpty { parts.append((" " + timelineCut(title, 200), Theme.fg2)) }
        if let type = agent.type, !type.isEmpty { parts.append(("  " + timelineCut(type, 60), Theme.fg3)) }
        if agent.status == .running { parts.append(("  running", Theme.fg3)) }
        if let time = ChatStyle.duration(agent.durationMs) { parts.append(("  " + time, Theme.fg3)) }
        if canExpand { parts.append((expanded ? "  ▾" : "  ▸", Theme.fg3)) }
        let out = NSMutableAttributedString(attributedString: line(parts, gap: gap, toggle: canExpand ? agent.id : nil))
        if agent.status == .error, let result {
            out.append(ChatCardText.well(Array(result.components(separatedBy: "\n").prefix(ChatRows.errorPreviewLines)), color: Theme.danger))
        } else if expanded, let result {
            let lines = result.components(separatedBy: "\n")
            let shown = lines.prefix(bodyLines).joined(separator: "\n") + (lines.count > bodyLines ? "\n\n… \(lines.count - bodyLines) more lines" : "")
            out.append(ChatStyle.markdown(timelineCut(shown, bodyChars), gap: 6))
        }
        return out
    }

    private static func statusGlyph(_ status: ChatToolStatus) -> (String, NSColor) {
        switch status {
        case .running: ("◐", Theme.accent)
        case .error: ("✕", Theme.danger)
        case .ok: ("✓", Theme.ok)
        }
    }

    // MARK: Pieces

    /// One paragraph of colored parts, a toggle link over all of it when `toggle` is set.
    static func line(_ parts: [(String, NSColor)], gap: CGFloat, toggle: String? = nil, font: NSFont = ChatStyle.font,
                     indent: CGFloat = ChatStyle.indent) -> NSAttributedString {
        let style = ChatStyle.paragraph(indent: indent, hanging: 2 * ChatStyle.charWidth, gap: gap)
        let out = NSMutableAttributedString()
        for (text, color) in parts { out.append(NSAttributedString(string: text, attributes: ChatStyle.attrs(color, font, style))) }
        out.append(NSAttributedString(string: "\n", attributes: ChatStyle.attrs(Theme.fg, font, style)))
        if let toggle { out.addAttribute(.link, value: "toggle:" + toggle, range: NSRange(location: 0, length: out.length - 1)) }
        return out
    }

    /// An expanded body, cut to `bodyLines` and `bodyChars`.
    static func body(_ text: String, color: NSColor) -> NSAttributedString {
        var lines = Array(text.components(separatedBy: "\n").prefix(bodyLines))
        let all = text.components(separatedBy: "\n").count
        if all > bodyLines { lines.append("… \(all - bodyLines) more lines") }
        let shown = timelineCut(lines.joined(separator: "\u{2028}"), bodyChars)
        let style = ChatStyle.paragraph(indent: ChatStyle.indent + 2 * ChatStyle.charWidth, gap: 4)
        return NSAttributedString(string: shown + "\n", attributes: ChatStyle.attrs(color, ChatStyle.smallFont, style))
    }

    static func timelineCut(_ text: String, _ max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max - 1)) + "…"
    }
}
