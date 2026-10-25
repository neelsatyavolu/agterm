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


    /// The tab shows the bell instead of beeping.
    override func bell(source: Terminal) {
        onBell?()
    }
}
