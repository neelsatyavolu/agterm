#if DEBUG
import AppKit
import SwiftTerm

extension SelfTest {
    /// Clicking in the line you're typing moves the cursor there: `AGTERM_CLICK_CHECK=1 AGTERM_SELFTEST=<dir>`.
    /// Types `echo abcdef` at zsh's prompt, clicks on the `d` the way a mouse click is routed, types
    /// `X` and runs it; the shell must print `abcXdef`.
    static func clickCheck(_ controller: MainWindowController) {
        let session = controller.sessions[0]
        let terminal = session.view.getTerminal()
        after(2) { session.view.send(txt: "clear\r") }
        after(3) { session.view.send(txt: "echo abcdef") }
        after(4) {
            guard let row = (0..<terminal.rows).first(where: { terminal.getLine(row: $0)?.translateToString(trimRight: true).hasSuffix("echo abcdef") == true }),
                  let col = terminal.getLine(row: row)?.translateToString(trimRight: true).count.advanced(by: -3) else {
                print("selftest: click: prompt line not found"); exit(1)
            }
            let routed = terminal.handleSemanticPromptClick(at: Position(col: col, row: terminal.buffer.yDisp + row))
            print("selftest: click routed:", routed)
            after(0.5) { session.view.send(txt: "X\r") }
        }
        after(6) {
            print("selftest: click result:", screenLine(session, containing: "abcXdef") != nil ? "abcXdef" : "missing")
            exit(0)
        }
    }
}
#endif
