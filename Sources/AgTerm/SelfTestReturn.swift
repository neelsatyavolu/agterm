#if DEBUG
import AgTermCore
import AgTermSessionKit
import AppKit

extension SelfTest {
    /// One tab at a time: `AGTERM_TABCLOUD_CHECK=1 AGTERM_SELFTEST=<dir>` with a cloud machine set.
    /// Right-click → Move to Cloud moves only that tab, which shows the cloud mark
    /// (`one-tab-in-cloud.png`); Bring Back from Cloud brings it home.
    static func tabCloudCheck(_ controller: MainWindowController, outDir: String) {
        var passed = true
        func report(_ name: String, _ ok: Bool) {
            print("tabcloud: \(name):", ok)
            passed = passed && ok
        }
        guard let window = controller.window, CloudHost.configured != nil else {
            print("tabcloud: needs AGTERM_CLOUD")
            exit(1)
        }
        window.setContentSize(NSSize(width: 980, height: 360))
        controller.showWindow(nil)
        controller.newTab()
        let first = controller.sessions[0]
        func act(_ index: Int, _ title: String) {
            guard let item = controller.tabMenuItemForTest(index, title), let action = item.action else {
                return report("menu has \(title)", false)
            }
            NSApp.sendAction(action, to: item.target, from: item)
        }
        after(1.5) {
            act(1, "Move to Cloud")
            waitFor({ controller.sessions.count == 2 && controller.sessions[1].isCloud }, timeout: 30) { moved in
                report("only that tab moved", moved && !first.isCloud && controller.sessions[0] === first)
                report("the rest stay here, so the button still offers the move", controller.tabBar.cloud == .moveUp)
                report("no automatic return for a tab you chose to move", !CloudReturn.movedAway)
                report("its menu offers the way back", controller.tabMenuItemForTest(1, "Bring Back from Cloud") != nil)
                controller.select(1)
                after(1) {
                    snapshot(window, "\(outDir)/one-tab-in-cloud.png")
                    act(1, "Bring Back from Cloud")
                    waitFor({ controller.sessions.count == 2 && !controller.sessions[1].isCloud }, timeout: 60) { back in
                        report("brought back", back)
                        controller.sessions.forEach { $0.terminate() }
                        after(1) { exit(passed ? 0 : 1) }
                    }
                }
            }
        }
    }

    /// Away and back: `AGTERM_RETURN_CHECK=1 AGTERM_SELFTEST=<dir>` with a cloud machine set, as for
    /// `moveCheck`. A fake Claude whose turn is done moves with the cloud button; the cloud machine
    /// adds a file to the repo; then, as when the Mac wakes, the tab comes home by itself, resumes
    /// the same conversation with the cloud's part of the transcript, and the file comes with it.
    /// (Here `claude` is your real one, in a fresh login shell, so only the command is checked.)
    /// With `AGTERM_RETURN_CONFLICT=1` the repo also changes on this Mac meanwhile: that change
    /// stays, and the cloud's comes back as a patch in the repo's git folder instead.
    /// Writes `returned-tab.png`.
    static func returnCheck(_ controller: MainWindowController, outDir: String) {
        let conflict = ProcessInfo.processInfo.environment["AGTERM_RETURN_CONFLICT"] == "1"
        var passed = true
        func report(_ name: String, _ ok: Bool) {
            print("return: \(name):", ok)
            passed = passed && ok
        }
        guard let window = controller.window, let cloud = CloudHost.configured, let fake = prepareMoveFixture(cloud) else {
            print("return: needs AGTERM_CLOUD and a cloud machine with rsync and cc")
            exit(1)
        }
        window.setContentSize(NSSize(width: 980, height: 420))
        controller.showWindow(nil)
        let local = controller.sessions[0]
        local.view.send(txt: "cd \(moveRepo) && \(fake) --idle\r")
        waitFor({ local.pollProcess(); return local.claudeSessionID != nil && screenLine(local, containing: "host=Darwin") != nil }) { started in
            report("fake claude running here, its turn done", started)
            let id = local.claudeSessionID ?? "?"
            report("cloud button offers the move", controller.tabBar.cloud == .moveUp)
            controller.tabBarDidRequestCloud(controller.tabBar)
            waitFor({ controller.sessions.first?.isCloud == true && screenLine(controller.sessions[0], containing: "host=Linux") != nil },
                    timeout: 60) { moved in
                report("moved with one click", moved)
                waitFor({ controller.tabBar.cloud == .bringBack }) { report("cloud button offers the way back", $0) }
                let made = try? cloud.run(["/usr/bin/env", "sh", "-c", "echo from-the-cloud > '\(moveRepo)/made-in-cloud.txt'"])
                report("cloud machine changed the repo", made?.status == 0)
                if conflict { try? "changed on the Mac\n".write(toFile: moveRepo + "/notes.txt", atomically: true, encoding: .utf8) }
                // As when the Mac wakes.
                controller.returnFromCloud()
                let transcript = NSHomeDirectory() + "/.claude/projects/" + moveRepo.replacingOccurrences(of: "/", with: "-") + "/\(id).jsonl"
                waitFor({ controller.sessions.first.map { !$0.isCloud && screenLine($0, containing: "--resume \(id)") != nil } == true },
                        timeout: 90) { back in
                    report("came home by itself, resuming the same conversation", back)
                    let lines = (try? String(contentsOfFile: transcript, encoding: .utf8))?.split(separator: "\n").count ?? 0
                    report("with the cloud's part of the transcript (\(lines) lines)", lines == 2)
                    if conflict {
                        let notes = try? String(contentsOfFile: moveRepo + "/notes.txt", encoding: .utf8)
                        report("this Mac's change kept", notes == "changed on the Mac\n")
                        report("the cloud's change not copied over it", !FileManager.default.fileExists(atPath: moveRepo + "/made-in-cloud.txt"))
                        let patches = ((try? FileManager.default.contentsOfDirectory(atPath: moveRepo + "/.git")) ?? []).filter { $0.hasSuffix(".patch") }
                        let patch = patches.first.flatMap { try? String(contentsOfFile: moveRepo + "/.git/" + $0, encoding: .utf8) } ?? ""
                        report("the cloud's change saved as a patch", patch.contains("made-in-cloud.txt") && patch.contains("+from-the-cloud"))
                    } else {
                        report("the cloud's change came too", FileManager.default.fileExists(atPath: moveRepo + "/made-in-cloud.txt"))
                    }
                    snapshot(window, "\(outDir)/returned-tab.png")
                    // The return waits up to 30 s for the agent to start, which the real one won't here.
                    waitFor({ controller.tabBar.cloud == .moveUp }, timeout: 45) { report("cloud button offers the move again", $0) }
                    waitFor({ !CloudReturn.movedAway }, timeout: 50) { report("nothing left to bring back", $0) }
                    controller.sessions.first?.terminate()
                    _ = try? cloud.run(["/usr/bin/env", "sh", "-c", "rm -rf \(moveRoot) ~/.claude/projects/*agmove*"])
                    try? FileManager.default.removeItem(atPath: moveRoot)
                    for project in (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.claude/projects")) ?? []
                    where project.contains("agmove") {
                        try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.claude/projects/" + project)
                    }
                    after(52) { exit(passed ? 0 : 1) }
                }
            }
        }
    }
}
#endif
