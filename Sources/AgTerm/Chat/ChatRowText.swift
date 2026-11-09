import AgTermCore
import AppKit

/// One `ChatRow` as transcript text. Collapsed parts (thinking, folded tools, long diffs and
/// outputs) aren't built until their row is expanded; clicking a `▸` line toggles it through a
/// `toggle:<row id>` link.
enum ChatRowText {
    /// Lines and characters an expanded tool body shows at most.
    static let bodyLines = 60
    static let bodyChars = 8_000

    static func render(_ row: ChatRow, expanded: Bool) -> NSAttributedString {
        let gap = ChatStyle.rowGap
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
        case .tool(let tool):
            return single(tool, expanded: expanded, gap: gap)
        case .agent(let agent):
            return subagent(agent, expanded: expanded, gap: gap)
        case .interrupted:
            return line([("■ interrupted", Theme.danger)], gap: gap)
        }
    }

    /// The reply ends with a block cursor while the agent is still writing it.
    private static func appendCursor(_ out: NSMutableAttributedString) {
        let end = out.length > 0 && out.string.hasSuffix("\n") ? out.length - 1 : out.length
        let style = end > 0 ? out.attribute(.paragraphStyle, at: end - 1, effectiveRange: nil) as? NSParagraphStyle : nil
        out.insert(NSAttributedString(string: " ▌", attributes: ChatStyle.attrs(Theme.fg, ChatStyle.font, style ?? ChatStyle.paragraph())), at: end)
    }

    // MARK: Rows

    private static func user(_ text: String, queued: Bool, gap: CGFloat) -> NSAttributedString {
        let gutter = 2 * ChatStyle.charWidth
        let style = ChatStyle.paragraph(indent: ChatStyle.indent - gutter, hanging: gutter, gap: gap + 11, after: 11)
        let band = ChatBox(fill: Theme.color(Theme.palette.fg, alpha: 0.04), border: Theme.color(Theme.palette.fg, alpha: 0.07),
                           left: 0, gapAbove: gap, fullWidth: true, radius: 0)
        let out = NSMutableAttributedString(string: "› ", attributes: ChatStyle.attrs(Theme.accent, ChatStyle.boldFont, style))
        let body = text.isEmpty ? " " : text.replacingOccurrences(of: "\n", with: "\u{2028}")
        out.append(NSAttributedString(string: body, attributes: ChatStyle.attrs(queued ? Theme.fg3 : Theme.fg, ChatStyle.font, style)))
        if queued { out.append(NSAttributedString(string: "  queued", attributes: ChatStyle.attrs(Theme.fg3, ChatStyle.smallFont, style))) }
        out.append(NSAttributedString(string: "\n", attributes: ChatStyle.attrs(Theme.fg, ChatStyle.font, style)))
        out.addAttribute(.chatBox, value: band, range: NSRange(location: 0, length: out.length))
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
