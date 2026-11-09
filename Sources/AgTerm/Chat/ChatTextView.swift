import AppKit

/// The transcript's text view (TextKit 1): draws each `ChatBox` (cards, wells, the user's band)
/// behind its paragraphs, only for what's in the dirty rect.
final class ChatTextView: NSTextView {
    /// Every row ends in a newline, so TextKit lays out an empty line after the last one in these
    /// attributes; a hairline keeps it from adding a row gap and a line of space above the composer.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { [.font: NSFont.systemFont(ofSize: 1)] }
        set {}
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBoxes(.chatBox, in: dirtyRect)
        drawBoxes(.chatLineBox, in: dirtyRect)
        super.draw(dirtyRect)
    }

    private func drawBoxes(_ key: NSAttributedString.Key, in dirtyRect: NSRect) {
        guard let manager = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let visible = manager.glyphRange(forBoundingRect: dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let chars = manager.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
        let all = NSRange(location: 0, length: storage.length)
        var index = chars.location
        while index < NSMaxRange(chars), index < storage.length {
            var range = NSRange()
            let box = storage.attribute(key, at: index, longestEffectiveRange: &range, in: all) as? ChatBox
            defer { index = max(NSMaxRange(range), index + 1) }
            guard let box else { continue }
            var area = rect(of: range, gapAbove: box.gapAbove, manager: manager, container: container)
            area.size.height -= box.bottomInset
            draw(box, rect: area)
        }
    }

    /// The line fragments of `range` (paragraph spacing included), less the gap above.
    private func rect(of range: NSRange, gapAbove: CGFloat, manager: NSLayoutManager, container: NSTextContainer) -> NSRect {
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return .zero }
        let top = manager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let bottom = manager.lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)
        let origin = textContainerOrigin
        return NSRect(x: 0, y: top.minY + gapAbove + origin.y, width: 0, height: bottom.maxY - top.minY - gapAbove)
    }

    private func draw(_ box: ChatBox, rect line: NSRect) {
        guard line.height > 0 else { return }
        let right = box.fullWidth ? bounds.width : textContainerOrigin.x + (textContainer?.size.width ?? bounds.width)
        let rect = NSRect(x: textContainerOrigin.x + box.left, y: line.minY, width: right - textContainerOrigin.x - box.left, height: line.height)
        if box.fullWidth { return drawBand(box, NSRect(x: 0, y: rect.minY, width: bounds.width, height: rect.height)) }
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: box.radius, yRadius: box.radius)
        if let fill = box.fill {
            fill.setFill()
            box.radius > 0 ? path.fill() : rect.fill()
        }
        if let border = box.border {
            border.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawBand(_ box: ChatBox, _ rect: NSRect) {
        box.fill?.setFill()
        rect.fill()
        guard let border = box.border else { return }
        border.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
    }
}
