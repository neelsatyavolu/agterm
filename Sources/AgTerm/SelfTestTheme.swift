#if DEBUG
import AppKit

extension SelfTest {
    /// Light themes keep text readable, and programs that ask are told about light and dark:
    /// `AGTERM_THEME_CHECK=1 AGTERM_SELFTEST=<dir>`. Prints the colors Claude Code's dark theme uses
    /// on Paper (`theme-paper.png`), then a script turns on mode 2031, asks with `CSI ? 996 n`, and
    /// the theme switches to Ink; it must hear light first, then dark.
    static func themeCheck(_ controller: MainWindowController, outDir: String) {
        guard let window = controller.window else { exit(1) }
        window.setContentSize(NSSize(width: 900, height: 420))
        let session = controller.sessions[0]
        let theme = Preferences.shared.appearance.themeID
        let script = (outDir as NSString).appendingPathComponent("scheme-reports.py")
        try? """
            import os, select, termios, time, tty
            old = termios.tcgetattr(0)
            tty.setraw(0)
            os.write(1, b"\\x1b[?2031h\\x1b[?996n")
            got, end = b"", time.time() + 4
            while time.time() < end:
                if select.select([0], [], [], 0.2)[0]:
                    got += os.read(0, 100)
            os.write(1, b"\\x1b[?2031l")
            termios.tcsetattr(0, termios.TCSADRAIN, old)
            print("REPORTS", got.replace(b"\\x1b", b"ESC").decode())
            """.write(toFile: script, atomically: true, encoding: .utf8)
        Preferences.shared.update { $0.themeID = "paper" }
        let samples = (outDir as NSString).appendingPathComponent("theme-samples.txt")
        try? [
            "\u{1B}[1;38;2;255;255;255mBold white, the way Claude Code's dark theme writes a question\u{1B}[0m",
            "\u{1B}[38;2;153;153;153mGray 153: Searched for 1 pattern, ran 4 shell commands\u{1B}[0m",
            "\u{1B}[38;2;80;80;80mGray 80, the faintest hint text\u{1B}[0m and \u{1B}[2mdim default text\u{1B}[0m",
            "\u{1B}[37mANSI white\u{1B}[0m \u{1B}[97mbright white\u{1B}[0m \u{1B}[33myellow\u{1B}[0m \u{1B}[93mbright yellow\u{1B}[0m \u{1B}[36mcyan\u{1B}[0m",
            "\u{1B}[48;2;55;55;55;38;2;255;255;255m ❯ a highlighted prompt keeps its own colors \u{1B}[0m",
        ].joined(separator: "\n").appending("\n").write(toFile: samples, atomically: true, encoding: .utf8)
        after(2) { session.view.send(txt: "clear; cat '\(samples)'\r") }
        after(3.5) {
            snapshot(window, "\(outDir)/theme-paper.png")
            session.view.send(txt: "clear; /usr/bin/python3 '\(script)'\r")
        }
        after(5.5) { Preferences.shared.update { $0.themeID = "ink" } }
        after(10) {
            print("selftest: theme reports:", screenLine(session, containing: "REPORTS") ?? "none")
            Preferences.shared.update { $0.themeID = theme }
            after(0.5) { exit(0) }
        }
    }
}
#endif
