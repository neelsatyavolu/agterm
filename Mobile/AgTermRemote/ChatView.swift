import AgTermCore
import SwiftUI

/// The conversation agterm reads from Claude Code's or Codex's transcript: your messages,
/// the agent's replies, its thinking and the tools it ran.
struct ChatView: View {
    /// Without a transcript the Mac sends its screen as one `screen-` entry; Screen shows that better.
    private let entries: [MobileTimelineEntry]?

    init(entries: [MobileTimelineEntry]?) {
        self.entries = entries?.filter { !$0.id.hasPrefix("screen-") }
    }

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true

    var body: some View {
        ScrollView {
            // Not lazy: a lazy stack guesses the heights of rows it hasn't drawn, so "the bottom"
            // lands mid-conversation. The Mac keeps timelines under 900 KB.
            VStack(alignment: .leading, spacing: 14) {
                ForEach(entries ?? [], id: \.id) { EntryView(entry: $0) }
            }
            .padding(16)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { scroll in
            scroll.contentOffset.y + scroll.containerSize.height >= scroll.contentSize.height - 24
        } action: { _, bottom in
            atBottom = bottom
        }
        .onChange(of: entries) {
            if atBottom { position.scrollTo(edge: .bottom) }
        }
        .overlay {
            if entries == nil {
                ProgressView().tint(Ink.fg3)
            } else if entries?.isEmpty == true {
                Text("No conversation yet. It appears once the agent saves its transcript.")
                    .font(.system(size: 15)).foregroundStyle(Ink.fg3)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
    }
}

private struct EntryView: View {
    let entry: MobileTimelineEntry

    var body: some View {
        switch entry.kind {
        case "user":
            HStack {
                Spacer(minLength: 40)
                Text(entry.text ?? "")
                    .font(.system(size: 15))
                    .foregroundStyle(Ink.fg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Ink.surfaceHover)
                    .opacity(entry.state == "queued" ? 0.6 : 1)
                    .textSelection(.enabled)
            }
        case "assistant":
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(ChatMarkdown.blocks(entry.text ?? "").enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let text):
                        Text(Self.markdown(text))
                            .font(.system(size: 16, design: .serif))
                            .foregroundStyle(Ink.fg)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    case .table(let table):
                        TableView(table: table)
                    }
                }
            }
        case "thinking":
            Text(entry.text ?? "")
                .font(.system(size: 14, design: .serif).italic())
                .foregroundStyle(Ink.fg3)
                .lineLimit(4)
        case "tool":
            tool
        default:
            EmptyView()
        }
    }

    private var tool: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(toolColor).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            Text(entry.lead ?? entry.toolName ?? "Tool").foregroundStyle(Ink.fg2)
            Text(entry.subject ?? "").foregroundStyle(Ink.fg).lineLimit(1).truncationMode(.middle)
            if let detail = entry.detail { Text(detail).foregroundStyle(Ink.fg3).lineLimit(1) }
            Spacer(minLength: 4)
            if let added = entry.additions, let removed = entry.deletions { DiffText(added: added, removed: removed) }
        }
        .font(Ink.mono(12))
    }

    private var toolColor: Color {
        switch entry.status {
        case "running": Ink.accent
        case "error": Ink.danger
        default: Ink.fg4
        }
    }

    /// Inline markdown (bold, code, links). `ChatMarkdown` splits tables out first; other block
    /// syntax stays as typed.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// A table from a reply, fitted to the screen width: long cells wrap.
private struct TableView: View {
    let table: ChatMarkdown.Table

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { column in
                    Text(EntryView.markdown(table.header[column]))
                        .font(Ink.mono(12, .medium))
                        .foregroundStyle(Ink.fg3)
                        .multilineTextAlignment(textAlignment(column))
                        .gridColumnAlignment(gridAlignment(column))
                }
            }
            ForEach(table.rows.indices, id: \.self) { row in
                Rectangle().fill(Ink.border).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(table.rows[row].indices, id: \.self) { column in
                        Text(EntryView.markdown(table.rows[row][column]))
                            .font(.system(size: 15, design: .serif))
                            .foregroundStyle(Ink.fg)
                            .multilineTextAlignment(textAlignment(column))
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func gridAlignment(_ column: Int) -> HorizontalAlignment {
        switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
