import AgTermCore
import SwiftUI
import UIKit

/// The tab's live screen, in the Mac's theme colors. Fits the Mac's width by default; pinch to
/// zoom in (then it scrolls sideways). Stays pinned to the bottom unless you scroll up.
struct ScreenView: View {
    let snapshot: ScreenSnapshot?

    @AppStorage("screenZoom") private var zoom = 1.0
    @State private var pinch = 1.0
    @State private var lines: [AttributedString] = []
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true

    private static let padding: CGFloat = 8
    /// Advance of one monospaced character per point of font size.
    private static let advance: CGFloat = {
        let font = UIFont.monospacedSystemFont(ofSize: 100, weight: .regular)
        return ("M" as NSString).size(withAttributes: [.font: font]).width / 100
    }()

    var body: some View {
        let palette = ThemeCatalog.named(snapshot?.theme ?? ThemeCatalog.defaultID)
        GeometryReader { geometry in
            let fit = (geometry.size.width - Self.padding * 2) / (CGFloat(max(snapshot?.cols ?? 80, 20)) * Self.advance)
            let size = min(max(fit * zoom * pinch, 5), 28)
            let zoomed = size > fit + 0.01
            ScrollView(zoomed ? [.vertical, .horizontal] : .vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index])
                            .lineLimit(1)
                            .fixedSize(horizontal: zoomed, vertical: false)
                    }
                }
                .font(.system(size: size, design: .monospaced))
                .foregroundStyle(Color(palette.fg))
                .padding(Self.padding)
                .frame(minWidth: geometry.size.width, alignment: .leading)
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { scroll in
                scroll.contentOffset.y + scroll.containerSize.height >= scroll.contentSize.height - 24
            } action: { _, bottom in
                atBottom = bottom
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { pinch = $0.magnification }
                    .onEnded { value in
                        zoom = min(max(zoom * value.magnification, 1), 4)
                        pinch = 1
                    })
        }
        .background(Color(palette.bg))
        .accessibilityIdentifier("screen")
        .overlay {
            if snapshot == nil { ProgressView().tint(Ink.fg3) }
        }
        .onChange(of: snapshot, initial: true) { _, new in
            lines = new.map { ScreenText.lines($0, palette: ThemeCatalog.named($0.theme)) } ?? []
            if atBottom { position.scrollTo(edge: .bottom) }
        }
    }
}

/// Turns snapshot runs into styled text. Sizes come from the view, so changing the zoom
/// doesn't rebuild the lines.
enum ScreenText {
    static func lines(_ snapshot: ScreenSnapshot, palette: ThemePalette) -> [AttributedString] {
        snapshot.lines.enumerated().map { index, runs in
            var line = AttributedString()
            for run in runs { line += styled(run, palette: palette) }
            if index == snapshot.cursorRow, let col = snapshot.cursorCol { addCursor(&line, at: col, palette: palette) }
            // An empty Text has no height; a space keeps the row.
            return line.characters.isEmpty ? AttributedString(" ") : line
        }
    }

    private static func styled(_ run: ScreenRun, palette: ThemePalette) -> AttributedString {
        var text = AttributedString(run.t)
        let style = run.style
        var fg = color(run.fg, palette: palette) ?? palette.fg
        var bg = color(run.bg, palette: palette)
        if style.contains(.inverse) {
            (fg, bg) = (bg ?? palette.bg, fg)
        }
        var foreground = Color(fg)
        if style.contains(.dim) { foreground = foreground.opacity(0.5) }
        if style.contains(.invisible) { foreground = .clear }
        text.foregroundColor = foreground
        if let bg { text.backgroundColor = Color(bg) }
        var intent: InlinePresentationIntent = []
        if style.contains(.bold) { intent.insert(.stronglyEmphasized) }
        if style.contains(.italic) { intent.insert(.emphasized) }
        if !intent.isEmpty { text.inlinePresentationIntent = intent }
        if style.contains(.underline) { text.underlineStyle = .single }
        if style.contains(.crossedOut) { text.strikethroughStyle = .single }
        return text
    }

    private static func addCursor(_ line: inout AttributedString, at col: Int, palette: ThemePalette) {
        let count = line.characters.count
        if col >= count { line += AttributedString(String(repeating: " ", count: col - count + 1)) }
        let start = line.characters.index(line.startIndex, offsetBy: col)
        let end = line.characters.index(after: start)
        line[start..<end].backgroundColor = Color(palette.accent)
        line[start..<end].foregroundColor = Color(palette.bg)
    }

    /// nil means the default color.
    static func color(_ color: CellColor, palette: ThemePalette) -> RGB? {
        switch color {
        case .default: return nil
        case .rgb(let r, let g, let b): return RGB(r: r, g: g, b: b)
        case .ansi(let n) where n < 16: return palette.ansi[Int(n)]
        case .ansi(let n) where n < 232:
            let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
            let i = Int(n) - 16
            return RGB(r: levels[i / 36], g: levels[i / 6 % 6], b: levels[i % 6])
        case .ansi(let n):
            let gray = UInt8(8 + 10 * (Int(n) - 232))
            return RGB(r: gray, g: gray, b: gray)
        }
    }
}
