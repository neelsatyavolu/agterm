import AgTermCore
import AppKit
import SwiftTerm

/// What a tab hears from its terminal, as SwiftTerm's LocalProcessTerminalViewDelegate told it.
protocol AgentTerminalViewDelegate: AnyObject {
    func sizeChanged(source: AgentTerminalView, newCols: Int, newRows: Int)
    func setTerminalTitle(source: AgentTerminalView, title: String)
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?)
    func processTerminated(source: TerminalView, exitCode: Int32?)
}

/// A terminal showing a shell through a `PtyLink` (in the sessions helper, or in-process) that
/// timestamps output, keystrokes and bells so tabs can tell whether the program inside is working.
final class AgentTerminalView: TerminalView, TerminalViewDelegate {
    var onOutput: (() -> Void)?
    /// Bytes sent to the program: your keystrokes, pastes, and replies from the phone.
    var onInput: (([UInt8]) -> Void)?
    var onBell: (() -> Void)?
    weak var processDelegate: AgentTerminalViewDelegate?
    /// The shell shown here; set once with `attach`.
    private(set) var link: PtyLink!

    /// While set, the program's output waits here instead of reaching the screen.
    private var heldOutput: [UInt8]?

    override init(frame: CGRect, font: NSFont?, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        terminalDelegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        terminalDelegate = self
    }

    /// Shows `link`'s shell. Call in the main-queue turn that made the link, before its output arrives.
    func attach(_ link: PtyLink) {
        self.link = link
        link.onData = { [weak self] bytes in self?.dataReceived(slice: bytes[...]) }
        link.onExit = { [weak self] status in
            guard let self else { return }
            self.processDelegate?.processTerminated(source: self, exitCode: status)
        }
    }

    /// The pty size for the current grid, with its pixel size.
    func windowSize() -> winsize {
        let terminal = getTerminal()
        let cell = cellSizeInPixels(source: terminal) ?? (width: 0, height: 0)
        return winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols),
                       ws_xpixel: UInt16(clamping: cell.width * terminal.cols), ws_ypixel: UInt16(clamping: cell.height * terminal.rows))
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        if heldOutput != nil {
            heldOutput?.append(contentsOf: slice)
            return
        }
        feed(byteArray: slice)
        onOutput?()
    }

    /// Keeps the program's output off the screen until `releaseOutput()` (What's New plays first).
    func holdOutput() {
        if heldOutput == nil { heldOutput = [] }
    }

    func releaseOutput() {
        guard let held = heldOutput else { return }
        heldOutput = nil
        if !held.isEmpty { dataReceived(slice: held[...]) }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(Array(data))
        link?.write(data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        link?.resize(windowSize())
        processDelegate?.sizeChanged(source: self, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        processDelegate?.setTerminalTitle(source: self, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        processDelegate?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(bytes: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([text as NSString])
    }

    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }

    // MARK: Smooth wheel scrolling

    /// Lines still to scroll; a wheel notch is spread over a few frames instead of jumping.
    private var pendingLines = 0
    private var scrollLink: CADisplayLink?

    /// SwiftTerm's scrollWheel can't be overridden from outside its module, so a local event
    /// monitor offers each wheel event to the terminal under the pointer first.
    private static let wheelMonitor: Any? = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
        guard let content = event.window?.contentView,
              var view = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return event }
        while !(view is AgentTerminalView), let parent = view.superview { view = parent }
        return (view as? AgentTerminalView)?.smoothScroll(event) == true ? nil : event
    }

    static func installScrollSmoothing() {
        _ = wheelMonitor
    }

    /// Returns false to let SwiftTerm handle the event as usual.
    private func smoothScroll(_ event: NSEvent) -> Bool {
        let terminal = getTerminal()
        let appTracksMouse = allowMouseReporting && terminal.mouseMode != .off && !event.modifierFlags.contains(.shift)
        // Trackpads already move line by line; apps that take the wheel keep SwiftTerm's handling.
        guard !event.hasPreciseScrollingDeltas, !appTracksMouse, !terminal.isCurrentBufferAlternate,
              event.scrollingDeltaY != 0 else { return false }
        let lines = Int(event.scrollingDeltaY.rounded())
        pendingLines = min(max(pendingLines + (lines != 0 ? lines : (event.scrollingDeltaY > 0 ? 1 : -1)), -300), 300)
        if scrollLink == nil {
            let link = displayLink(target: self, selector: #selector(stepScroll(_:)))
            link.add(to: .main, forMode: .common)
            scrollLink = link
        }
        return true
    }

    /// Ease out: move a quarter of what's left each frame, at least one line.
    @objc private func stepScroll(_ link: CADisplayLink) {
        guard pendingLines != 0 else {
            link.invalidate()
            scrollLink = nil
            return
        }
        let step = max(1, abs(pendingLines) / 4) * (pendingLines > 0 ? 1 : -1)
        if step > 0 { scrollUp(lines: step) } else { scrollDown(lines: -step) }
        pendingLines -= step
    }

    // MARK: Drag and drop

    func enableDrops() {
        registerForDraggedTypes(DropReader.acceptedTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        showDropTarget(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        showDropTarget(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        showDropTarget(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showDropTarget(false)
        DropReader.text(from: sender.draggingPasteboard) { [weak self] text in
            guard let self, let text, !text.isEmpty else { return }
            self.send(txt: DropText.wrap(text, bracketed: self.getTerminal().bracketedPasteMode))
            self.window?.makeFirstResponder(self)
        }
        return true
    }

    private func showDropTarget(_ on: Bool) {
        wantsLayer = true
        layer?.borderColor = Theme.accent.cgColor
        layer?.borderWidth = on ? 2 : 0
        layer?.cornerRadius = 8
    }

    /// The tab shows the bell instead of beeping.
    override func bell(source: Terminal) {
        onBell?()
    }
}
