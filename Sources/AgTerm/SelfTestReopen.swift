#if DEBUG
import AgTermCore
import AppKit

/// AGTERM_REOPEN_CHECK=1: closes a tab running an agent (a stand-in `grok` that prints its
/// arguments), then Reopen Closed Tab: the tab should come back with its history and the agent
/// started again with its continue flag.
extension SelfTest {
    static func reopenCheck(_ controller: MainWindowController, outDir: String) {
        let fakes = outDir + "/reopen-fakes"
        try? FileManager.default.createDirectory(atPath: fakes, withIntermediateDirectories: true)
        // A compiled stand-in: agterm knows agents by their executable's name, and a script runs as sh.
        let source = fakes + "/grok.c"
        try? """
            #include <stdio.h>
            #include <unistd.h>
            int main(int c, char **v) { printf("FAKE-ARGS"); for (int i = 1; i < c; i++) printf(" %s", v[i]);
              printf("\\n"); fflush(stdout); sleep(600); return 0; }
            """.write(toFile: source, atomically: true, encoding: .utf8)
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        cc.arguments = ["-o", fakes + "/grok", source]
        guard (try? cc.run()) != nil else { print("selftest: reopen: no clang"); exit(1) }
        cc.waitUntilExit()
        controller.newTab()
        guard let tab = controller.sessions.last else { exit(1) }
        after(2) {
            tab.view.send(txt: "export PATH=\"\(fakes):$PATH\"; echo before-close-marker; grok --model fast\r")
        }
        after(5) {
            print("selftest: reopen: menu enabled before close:", controller.validateMenuItem(menuItem(controller)))
            let count = controller.sessions.count
            controller.removePane(tab)
            print("selftest: reopen: closed:", controller.sessions.count == count - 1,
                  "| menu enabled:", controller.validateMenuItem(menuItem(controller)))
            // The reopened shell must find the stand-in, not a real grok.
            if var saved = controller.closedTabs.popLast() {
                print("selftest: reopen: saved resume:", saved.resume ?? "nothing")
                saved.resume = saved.resume.map { "export PATH=\"\(fakes):$PATH\"; " + $0 }
                controller.closedTabs.push(saved)
            }
            let recent = NSMenu()
            RecentlyClosedMenu { controller.closedTabs }.menuNeedsUpdate(recent)
            print("selftest: reopen: recently closed lists:", recent.items.map(\.title))
            controller.reopenClosedTab()
            let reopened = controller.sessions.last
            after(5) {
                guard let reopened else { return print("selftest: reopen: no tab") }
                print("selftest: reopen: same tab id:", reopened.tabID == tab.tabID, "| agent:", reopened.agentName ?? "none",
                      "| history:", screenLine(reopened, containing: "before-close-marker") != nil,
                      "| agent back with:", reopened.screenText().split(separator: "\n").last { $0.contains("FAKE-ARGS") } ?? "no")
                controller.sessions.forEach { $0.terminate() }
                after(1) { exit(0) }
            }
        }
    }

    private static func menuItem(_ controller: MainWindowController) -> NSMenuItem {
        NSMenuItem(title: "Reopen Closed Tab", action: #selector(MainWindowController.reopenClosedTab), keyEquivalent: "")
    }
}
#endif
