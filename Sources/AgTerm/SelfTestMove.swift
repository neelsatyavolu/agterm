#if DEBUG
import AgTermCore
import AgTermSessionKit
import AppKit

extension SelfTest {
    /// Move to Cloud: `AGTERM_MOVE_CHECK=1 AGTERM_SELFTEST=<dir>` with `AGTERM_CLOUD` and
    /// `AGTERM_CLOUD_TOKEN` naming a Linux helper whose user's home is this Mac's home path, with
    /// rsync and a C compiler (AGENTS.md has the container). Starts a fake Claude
    /// (scripts/fake-claude.c) mid-turn in a repo under /tmp, moves the tab, and checks that the
    /// conversation continues in the cloud with its transcript and the "continue" prompt, that the
    /// repo was copied without node_modules, and that the agent is still running there after the
    /// app quits. Writes `moved-tab.png`.
    static func moveCheck(_ controller: MainWindowController, outDir: String) {
        var passed = true
        func report(_ name: String, _ ok: Bool) {
            print("move: \(name):", ok)
            passed = passed && ok
        }
        guard let window = controller.window, let cloud = CloudHost.configured,
              let fake = prepareMoveFixture(cloud) else {
            print("move: needs AGTERM_CLOUD and a cloud machine with rsync and cc")
            exit(1)
        }
        window.setContentSize(NSSize(width: 980, height: 420))
        controller.showWindow(nil)
        controller.newTab()
        let local = controller.sessions.last!
        local.view.send(txt: "cd \(moveRepo) && \(fake)\r")
        waitFor({ local.pollProcess(); return local.claudeSessionID != nil && screenLine(local, containing: "host=Darwin") != nil }) { started in
            report("fake claude running here", started)
            let id = local.claudeSessionID ?? "?"
            let localShell = local.view.link.shellPid
            let items = CloudMove.preflight([local])
            report("preflight: \(items.first?.summary ?? "nothing")", items.first?.agent == "claude" && items.first?.folder == moveRepo)
            let started = Date()
            // The tab says what the move is doing while it runs.
            after(2) {
                report("tab shows the move", controller.cloudState.moving[ObjectIdentifier(local)] != nil)
                snapshot(window, "\(outDir)/moving-tab.png")
            }
            controller.moveToCloud(items, cloud: cloud) { outcome in
                if case .failed(let reason) = outcome { print("move: failed:", reason) }
                report(String(format: "moved in %.0fs", Date().timeIntervalSince(started)), { if case .moved(1) = outcome { return true } else { return false } }())
                guard let moved = controller.sessions.first(where: { $0.tabID == local.tabID && $0.isCloud }) else {
                    report("cloud tab took its place", false)
                    exit(1)
                }
                let expected = "session=\(id) lines=2 prompt=[\(CloudMove.continuePrompt)] host=Linux"
                waitFor({ screenLine(moved, containing: expected) != nil }, timeout: 20) { resumed in
                    report("same conversation continues in the cloud, transcript and prompt included", resumed)
                    report("local shell ended", localShell > 0 && kill(localShell, 0) != 0)
                    report("repo copied", (try? cloud.run(["/usr/bin/env", "test", "-f", moveRepo + "/notes.txt"]))?.status == 0)
                    report("node_modules left out", (try? cloud.run(["/usr/bin/env", "test", "-e", moveRepo + "/node_modules"]))?.status == 1)
                    report("git-ignored folder left out", (try? cloud.run(["/usr/bin/env", "test", "-e", moveRepo + "/cache"]))?.status == 1)
                    report("ignored .env left on this Mac", (try? cloud.run(["/usr/bin/env", "test", "-e", moveRepo + "/.env"]))?.status == 1)
                    report("cloud setup ran before the agent", (try? cloud.run(["/usr/bin/env", "test", "-f", moveRepo + "/setup-ran"]))?.status == 0)
                    report("tab no longer shows the move", controller.cloudState.moving.isEmpty)
                    checkPhoneHandoff(cloud, tabID: moved.tabID, report: report)
                    snapshot(window, "\(outDir)/moved-tab.png")
                    let sessionID = moved.view.link.sessionID ?? "?"
                    // ⌘Q, minus the process exit: the cloud agent must keep going.
                    controller.quit(endingSessions: false)
                    controller.window?.orderOut(nil)
                    after(2) {
                        checkStillRunning(cloud, id: sessionID, report: report) {
                            _ = try? cloud.run(["/usr/bin/env", "sh", "-c", "rm -rf \(moveRoot) ~/.claude/projects/*agmove* ~/.agterm/setup"])
                            try? FileManager.default.removeItem(atPath: moveRoot)
                            for project in (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.claude/projects")) ?? []
                            where project.contains("agmove") {
                                try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.claude/projects/" + project)
                            }
                            exit(passed ? 0 : 1)
                        }
                    }
                }
            }
        }
    }

    /// realpath'd, as the shell reports it.
    static let moveRoot = "/private/tmp/agmove"
    static let moveRepo = moveRoot + "/proj"

    /// A git repo with a commit, a node_modules, a folder and a .env its .gitignore lists, and a
    /// cloud setup script that leaves `setup-ran` behind, and the fake Claude built here and on
    /// the machine.
    /// Returns the local fake's path.
    static func prepareMoveFixture(_ cloud: CloudHost) -> String? {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../scripts/fake-claude.c").standardized.path
        let fm = FileManager.default
        try? fm.removeItem(atPath: moveRoot)
        for dir in [moveRepo + "/node_modules/junk", moveRepo + "/cache", moveRepo + "/.agterm", moveRoot + "/bin"] {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        fm.createFile(atPath: moveRepo + "/notes.txt", contents: Data("from the Mac\n".utf8))
        fm.createFile(atPath: moveRepo + "/node_modules/junk/x.js", contents: Data("x\n".utf8))
        fm.createFile(atPath: moveRepo + "/.gitignore", contents: Data("cache/\n.env\nsetup-ran\n".utf8))
        fm.createFile(atPath: moveRepo + "/" + CloudSetup.customScript, contents: Data("echo ran >> setup-ran\n".utf8))
        fm.createFile(atPath: moveRepo + "/cache/big.bin", contents: Data("built\n".utf8))
        fm.createFile(atPath: moveRepo + "/.env", contents: Data("KEY=1\n".utf8))
        for arguments in [["init", "-q"], ["add", "-A"], ["-c", "user.name=agterm", "-c", "user.email=test@agterm", "commit", "-qm", "start"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-C", moveRepo] + arguments
            guard (try? git.run()) != nil else { return nil }
            git.waitUntilExit()
        }
        let fake = moveRoot + "/bin/claude"
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = ["-o", fake, source]
        guard (try? cc.run()) != nil else { return nil }
        cc.waitUntilExit()
        // On the machine: the same source at the same path, built into ~/bin (on its login PATH).
        guard cc.terminationStatus == 0, (try? CloudSync.push(folders: [], files: [source], to: cloud)) != nil,
              let built = try? cloud.run(["/usr/bin/env", "sh", "-c", "mkdir -p ~/bin && $(command -v cc || command -v clang) -o ~/bin/claude '\(source)'"]),
              built.status == 0 else { return nil }
        return fake
    }

    /// The phone handoff reaches the machine readable only by its owner, and goes away again.
    private static func checkPhoneHandoff(_ cloud: CloudHost, tabID: String, report: (String, Bool) -> Void) {
        let handoff = CloudPhoneHandoff(desktopId: "selftest", desktopSecret: String(repeating: "s", count: 40), relay: AgTermWire.defaultRelay,
                                        deviceName: "agterm Cloud for selftest", theme: "ink", home: NSHomeDirectory(),
                                        tabs: [.init(id: tabID, name: nil)])
        let path = "$HOME/" + CloudPhoneHandoff.path
        let written = (try? CloudSync.writePhoneHandoff(handoff, to: cloud)) != nil
        let read = try? cloud.run(["/usr/bin/env", "sh", "-c", "stat -c %a \"\(path)\" && cat \"\(path)\""])
        let lines = read?.stdout.split(separator: "\n", maxSplits: 1).map(String.init) ?? []
        let back = lines.count == 2 ? try? JSONDecoder().decode(CloudPhoneHandoff.self, from: Data(lines[1].utf8)) : nil
        report("phone handoff written to the machine, owner-only", written && lines.first == "600" && back == handoff)
        let removed = (try? CloudSync.writePhoneHandoff(nil, to: cloud)) != nil
        report("phone handoff removed", removed && (try? cloud.run(["/usr/bin/env", "sh", "-c", "test -e \"\(path)\""]))?.status == 1)
    }

    /// Attaches to the moved shell as a new app would, and asks what runs there.
    private static func checkStillRunning(_ cloud: CloudHost, id: String, report: @escaping (String, Bool) -> Void,
                                          then done: @escaping () -> Void) {
        guard let link = try? cloud.attach(id: id) else {
            report("cloud agent still running after the app quit", false)
            return done()
        }
        var answered = false
        link.onForeground = { info in
            guard !answered else { return }
            answered = true
            report("cloud agent still running after the app quit (\(info.name))", !info.isShell && info.name == "claude")
            link.end()
            after(1, done)
        }
        link.requestForeground()
        after(5) {
            guard !answered else { return }
            answered = true
            report("cloud agent still running after the app quit", false)
            done()
        }
    }
}
#endif
