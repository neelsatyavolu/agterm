import AppKit

/// Tooltips for the buttons in the title bar. AppKit's own never appear there, because the
/// transparent title bar sits over them, so this shows the button's text under it after a pause.
final class HoverTip {
    static let shared = HoverTip()
    private static let delay: TimeInterval = 0.6
    private static let maxWidth: CGFloat = 360
    private let panel: NSPanel
    private let box = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private weak var owner: NSView?
    private var pending: DispatchWorkItem?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.level = .popUpMenu
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 11.5)
        label.preferredMaxLayoutWidth = Self.maxWidth
        box.addSubview(label)
        panel.contentView = box
    }

    /// Shows `text` under `view` once the pointer has rested on it.
    func show(_ text: String?, for view: NSView) {
        hide()
        guard let text, !text.isEmpty else { return }
        owner = view
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, self.owner === view, NSApp.isActive else { return }
            self.present(text, under: view)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    /// Hides the tip if it belongs to `view`, or any tip when `view` is nil.
    func hide(for view: NSView? = nil) {
        if let view, owner !== view { return }
        pending?.cancel()
        pending = nil
        owner = nil
        panel.orderOut(nil)
    }

    private func present(_ text: String, under view: NSView) {
        guard let window = view.window, window.isVisible else { return }
        panel.appearance = Theme.appearance
        box.layer?.backgroundColor = Theme.color(Theme.palette.chrome).cgColor
        box.layer?.borderColor = Theme.border.cgColor
        label.textColor = Theme.fg
        label.stringValue = text
        let size = label.fittingSize
        label.frame = NSRect(x: 8, y: 5, width: ceil(size.width), height: ceil(size.height))
        let frame = NSSize(width: ceil(size.width) + 16, height: ceil(size.height) + 10)

        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let x = min(max(anchor.midX - frame.width / 2, screen.minX + 4), screen.maxX - frame.width - 4)
        let y = max(anchor.minY - frame.height - 6, screen.minY + 4)
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: frame), display: true)
        panel.orderFront(nil)
    }

    #if DEBUG
    /// Self-test: shows the tip at once, even with agterm in the background.
    func showNowForTest(_ text: String, for view: NSView) {
        hide()
        owner = view
        present(text, under: view)
    }

    var panelForTest: NSPanel { panel }
    #endif
}
