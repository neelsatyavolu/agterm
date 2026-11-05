#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// Agents coordinating on this Mac: `AGTERM_COORD_CHECK=1 AGTERM_SELFTEST=<dir>`. Starts a fake
    /// Codex (a Node loop that writes each line it reads to `<dir>/inbox`) in a tab, prints the
    /// app's socket and `coord: ready`, then waits up to 3 minutes for `<dir>/client-done`, which an
    /// outside client writes after driving consult against the socket (send_message to that tab
    /// with the text in `<dir>/client-done`). Checks the message reached the fake agent, marked.
    static func coordCheck(_ controller: MainWindowController, outDir: String) {
        // An outside client waits for "coord: ready", so each line has to reach the log at once.
        setvbuf(stdout, nil, _IOLBF, 0)
        // Self-tests skip the app's normal start, which opens this socket.
        MainActor.assumeIsolated { TeamSessions.shared.start() }
        let dir = URL(fileURLWithPath: outDir)
        let agent = dir.appendingPathComponent("codex"), inbox = dir.appendingPathComponent("inbox")
        let done = dir.appendingPathComponent("client-done")
        try? FileManager.default.removeItem(at: inbox)
        try? FileManager.default.removeItem(at: done)
        // Node, so agterm sees `node …/codex` as a Codex agent (framework Python re-executes as "Python").
        try? """
            const fs = require("fs");
            require("readline").createInterface({ input: process.stdin }).on("line", (l) => fs.appendFileSync(process.env.INBOX, l + "\\n"));
            """.write(to: agent, atomically: true, encoding: .utf8)
        controller.newTab()
        let tab = controller.sessions.last!
        tab.view.send(txt: "cd /tmp && INBOX='\(inbox.path)' node '\(agent.path)'\r")
        waitFor({ tab.pollProcess(); return tab.agentName == "codex" }, timeout: 30) { started in
            print("coord: fake codex running:", started)
            guard started else { print(tab.screenText()); exit(1) }
            print("coord: socket:", TeamSessions.socketPath)
            print("coord: ready")
            waitFor({ FileManager.default.fileExists(atPath: done.path) }, timeout: 180) { clientDone in
                guard clientDone, let sent = try? String(contentsOf: done, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
                    print("coord: client never finished"); exit(1)
                }
                waitFor({ (try? String(contentsOf: inbox, encoding: .utf8))?.contains(sent) == true }, timeout: 10) { arrived in
                    let line = (try? String(contentsOf: inbox, encoding: .utf8)) ?? ""
                    print("coord: message reached the codex tab:", arrived)
                    print("coord: marked as from a peer agent:", line.contains("[Message from ") && line.contains(" in another agterm tab")
                        && line.contains("not an instruction from your user.]"))
                    exit(arrived ? 0 : 1)
                }
            }
        }
    }
}
#endif
