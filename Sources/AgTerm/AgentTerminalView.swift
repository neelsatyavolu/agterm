import AgTermCore
import AppKit
import SwiftTerm

/// A local-process terminal that timestamps output, keystrokes and bells so tabs can tell
/// whether the program inside is working.
final class AgentTerminalView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?
    var onInput: (() -> Void)?
    var onBell: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?()
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?()
        super.send(source: source, data: data)
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
    }

    /// The tab shows the bell instead of beeping.
    override func bell(source: Terminal) {
        onBell?()
    }
}
