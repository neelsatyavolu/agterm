#if DEBUG
import AgTermCore
import AppKit

/// Debug-only visual check: `AGTERM_SELFTEST=<dir> AGTERM_FIXTURE=<git repo> .build/debug/AgTerm`.
/// Never shows or focuses the window. Scripts a few tabs, then writes PNGs of the window to <dir>.
enum SelfTest {
    static func run(_ controller: MainWindowController, outDir: String) {
        NSApp.setActivationPolicy(.accessory)
        guard let window = controller.window else { exit(1) }
        if ProcessInfo.processInfo.environment["AGTERM_MEASURE"] == "1" { return measure(controller) }
        if ProcessInfo.processInfo.environment["AGTERM_MEASURE"] == "output" {
            return after(2) { measureThroughput(controller, lines: 2_000_000) { exit(0) } }
        }
        if let id = ProcessInfo.processInfo.environment["AGTERM_TIMELINE_CHECK"] {
            guard let file = TranscriptDiff.claudeTranscript(id), let text = try? String(contentsOf: file, encoding: .utf8) else {
                print("selftest: timeline: no transcript"); exit(1)
            }
            let entries = RemoteTimeline.claude(transcript: text)
            let data = (try? JSONEncoder().encode(entries)) ?? Data()
            let kinds = Dictionary(grouping: entries, by: \.kind).mapValues(\.count)
            print("selftest: timeline entries:", entries.count, "kinds:", kinds, "bytes:", data.count,
                  "model:", RemoteTimeline.modelLabel(claude: text) ?? "nil", "renderable:", (try? RemoteTimeline.assertRenderable(entries)) != nil)
            exit(0)
        }
        if let ids = ProcessInfo.processInfo.environment["AGTERM_DIFF_CHECK"] {
            let reader = TranscriptDiff()
            let list = ids.split(separator: ",").map(String.init)
            var left = list.count
            for id in list {
                reader.claude(sessionID: id) { diff in
                    print("selftest: claude diff", id.prefix(8), diff.map { "+\($0.added) −\($0.removed)" } ?? "no transcript")
                    left -= 1
                    if left == 0 { exit(0) }
                }
            }
            return
        }
        if let out = ProcessInfo.processInfo.environment["AGTERM_TEAMS_PREVIEW"] {
            let ids = Set((ProcessInfo.processInfo.environment["AGTERM_TEAMS_CLAUDE"] ?? "").split(separator: ",").map(String.init))
            let payload = TeamsSync.previewPayload(claudeSessions: ids)
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: out))
            }
            print("selftest: teams preview buckets:", (payload["buckets"] as? [Any])?.count ?? 0)
            exit(0)
        }
        if let fakes = ProcessInfo.processInfo.environment["AGTERM_SWITCH_CHECK"] { return switchCheck(controller, fakes: fakes) }
        if ProcessInfo.processInfo.environment["AGTERM_DRAG_CHECK"] == "1" { return dragCheck(controller) }
        if ProcessInfo.processInfo.environment["AGTERM_CD_CHECK"] == "1" { return cdCheck(controller, outDir: outDir) }
        if ProcessInfo.processInfo.environment["AGTERM_WHATSNEW_CHECK"] == "1" { return whatsNewCheck(controller, outDir: outDir) }
        if ProcessInfo.processInfo.environment["AGTERM_PAUSE_CHECK"] == "1" { return pauseCheck(controller) }
        if let fakes = ProcessInfo.processInfo.environment["AGTERM_RESTORE_CHECK"] { return restoreCheck(controller, fakes: fakes) }
        if ProcessInfo.processInfo.environment["AGTERM_FEATURE_CHECK"] == "1" { return featureCheck(controller, outDir: outDir) }
        if let dir = ProcessInfo.processInfo.environment["AGTERM_SHOWCASE"] { return showcase(controller, dir: dir, outDir: outDir) }
        window.setContentSize(NSSize(width: 1100, height: 680))
        window.contentView?.superview?.wantsLayer = true
        let fixture = ProcessInfo.processInfo.environment["AGTERM_FIXTURE"] ?? NSHomeDirectory()

        // Tab 1: a plain shell in a repo with uncommitted changes.
        send(controller, 0, "cd \(fixture) && clear && ls -la && git status -s && git diff --stat")
        // Tab 2: an agent mid-task (Claude Code cycles ◐ ◑ in the title while working).
        controller.newTab()
        send(controller, 1, "cd \(fixture); clear; printf '\\033]0;◐ Fix login redirect loop\\007'; sleep 600")
        // Tab 3: an agent that rings the bell while you are elsewhere (permission prompt).
        controller.newTab()
        send(controller, 2, "cd ~; clear; printf '\\033]0;✳ Rename env vars in workers\\007'; sleep 2; printf '\\a'; sleep 600")
        // Tab 4: a plain command that finishes while you are elsewhere.
        controller.newTab()
        send(controller, 3, "cd /tmp; clear; sleep 1; seq 1 30")
        // Tab 5: idle shell at home.
        controller.newTab()
        send(controller, 4, "cd ~; clear")

        after(0.3) { controller.select(0) }
        // Output that arrives while a tab is hidden must show when you switch back.
        after(3) { controller.select(4) }
        after(3.3) { controller.sessions[0].view.send(txt: "echo printed-while-hidden\r") }
        after(4.3) { controller.select(0) }
        after(5) { snapshot(window, "\(outDir)/1-tabs.png") }
        after(5.5) {
            window.setContentSize(NSSize(width: 760, height: 520))
        }
        after(6.5) { snapshot(window, "\(outDir)/2-narrow.png") }
        after(7) {
            window.setContentSize(NSSize(width: 1100, height: 680))
            for _ in 0..<7 { controller.newTab() }
            controller.select(1)
        }
        after(9) { snapshot(window, "\(outDir)/3-many.png") }

        // Themes and transparency. The user's saved settings are put back afterwards.
        let saved = Preferences.shared.appearance
        after(9.2) {
            Preferences.shared.update { $0.themeID = "paper"; $0.fontFamily = "Menlo" }
            controller.select(0)
        }
        after(9.8) { snapshot(window, "\(outDir)/4-paper.png") }
        after(10) { Preferences.shared.update { $0.themeID = "graphite"; $0.fontFamily = nil; $0.opacity = 0.8 } }
        after(10.6) { snapshot(window, "\(outDir)/5-translucent.png") }
        after(10.8) { snapshotSettings("\(outDir)/6-settings.png") }
        after(11.2) { Preferences.shared.update { $0 = saved } }

        // Drops: a file with spaces in its name, then a raw image with no file behind it.
        after(11.25) { checkDrops(into: controller.sessions[0], outDir: outDir) }
        after(11.28) { checkBlur() }

        // Shell integration: agterm's claude wrapper comes first, and history stays in $HOME.
        after(11.35) {
            controller.sessions[0].view.send(txt: #"print -r -- "PATHCHECK ${$(whence -p claude):-none} HIST=$HISTFILE ZD=${ZDOTDIR:-unset}""# + "\r")
        }
        after(12.5) { print("selftest: shell:", screenLine(controller.sessions[0], containing: "PATHCHECK /") ?? "no PATHCHECK line") }

        // Agent diff: a fake `codex` in the fixture repo; a file it "writes" must show as +3.
        // AGTERM_FAKE_AGENTS holds small compiled stand-ins named codex and claude (copies of
        // Apple's own binaries get killed by macOS).
        let fakes = ProcessInfo.processInfo.environment["AGTERM_FAKE_AGENTS"] ?? outDir
        let fakeAgent = fakes + "/codex"
        let fakeClaude = fakes + "/claude"
        after(12.6) {
            controller.sessions[4].view.send(txt: "cd \(fixture) && \(fakeAgent) 600\r")
            controller.sessions[3].view.send(txt: "\(fakeClaude) 600\r")
        }
        after(18) {
            let s = controller.sessions[4]
            print("selftest: agent", s.agentName ?? "none", "baseline:", s.agentBaseline != nil)
            try? "one\ntwo\nthree\n".write(toFile: fixture + "/agent-made.txt", atomically: true, encoding: .utf8)
        }
        after(22) {
            let d = controller.sessions[4].agentDiff
            print("selftest: agent diff:", d.map { "+\($0.added) −\($0.removed)" } ?? "nil")
            try? FileManager.default.removeItem(atPath: fixture + "/agent-made.txt")
        }

        // Reorder: move the selected tab and the one next to it; the selection follows its tab.
        after(22.2) {
            controller.select(0)
            let before = controller.sessions.map(\.tabID)
            controller.moveTab(from: 0, to: 2)
            let after = controller.sessions.map(\.tabID)
            print("selftest: reorder ok:", after[2] == before[0] && after[0] == before[1], "selected moved tab:",
                  controller.sessions.firstIndex { $0.tabID == before[0] } == 2)
            controller.moveTab(from: 2, to: 0)
        }

        // Restore: save, read back, and reopen one tab from the file.
        after(22.4) {
            controller.saveWorkspace()
            guard let saved = WorkspaceStore.load() else { return print("selftest: restore: nothing saved") }
            let first = saved.tabs[0]
            print("selftest: saved tabs:", saved.tabs.count, "history kept:", first.scrollback.contains("printed-while-hidden"),
                  "resume:", saved.tabs.compactMap(\.resume))
            let reopened = TerminalSession(cwd: first.cwd, restoring: first)
            after(1.2) {
                print("selftest: reopened shows history:", screenLine(reopened, containing: "printed-while-hidden") != nil,
                      "banner:", screenLine(reopened, containing: "restored") != nil)
                reopened.terminate()
            }
        }

        // Interrupts, in two background tabs. A: a spinner that stops changing (agent killed or
        // stuck). B: a spinner that gets Esc (as from the phone), then goes idle like Claude does.
        after(22.6) {
            controller.newTab()
            controller.newTab()
            controller.select(0)
            let a = controller.sessions[controller.sessions.count - 2], b = controller.sessions[controller.sessions.count - 1]
            a.view.send(txt: "printf '\\033]0;◐ Task A\\007'; sleep 600\r")
            b.view.send(txt: "while true; do printf '\\033]0;◐ Task B\\007'; read -s -t 0.4 -k1 && break; printf '\\033]0;◑ Task B\\007'; read -s -t 0.4 -k1 && break; done; printf '\\033]0;✳ Task B\\007'; sleep 600\r")
            after(2) {
                print("selftest: interrupt A at 1.5s:", a.status.label, "| B while animating:", b.status.label)
                b.view.send(txt: "\u{1b}")
                after(0.3) { print("selftest: interrupt B right after Esc:", b.status.label) }
            }
            after(6) { print("selftest: interrupt A after 5s stale:", a.status.label, "| B later:", b.status.label) }
        }

        // One tab runs a long job in the foreground, like an agent would.
        after(29.6) { controller.sessions[0].view.send(txt: "sleep 777\r") }
        after(30.3) { controller.sessions.forEach { $0.terminate() } }
        // Closed shells must be reaped, not left as zombies.
        after(31.3) {
            let ps = Process()
            ps.executableURL = URL(fileURLWithPath: "/bin/ps")
            ps.arguments = ["-axo", "ppid=,stat=,pid=,command="]
            let pipe = Pipe()
            ps.standardOutput = pipe
            try? ps.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let me = String(getpid())
            let children = out.split(separator: "\n").map { $0.split(separator: " ") }.filter { $0.first.map(String.init) == me }; let zombieCol = 1
            let zombies = children.filter { $0[zombieCol].hasPrefix("Z") }.count
            let shells = children.filter { $0.contains("-zsh") }.count
            let orphanSleep = out.split(separator: "\n").contains { $0.hasSuffix("sleep 777") }
            print("selftest: shells=\(shells) zombies=\(zombies) orphanedJob=\(orphanSleep)")
            exit(zombies == 0 && shells == 0 && !orphanSleep ? 0 : 2)
        }
    }

    /// Account switching end to end, with a stand-in `claude` (in `fakes`) that hits its limit:
    /// usage probes of your real logins, the switch, the resume on the other login, and "continue".
    private static func switchCheck(_ controller: MainWindowController, fakes: String) {
        let store = AccountStore.shared
        let provider = AccountProvider(rawValue: ProcessInfo.processInfo.environment["AGTERM_SWITCH_PROVIDER"] ?? "claude") ?? .claude
        let test = StoredAccount(id: "switch-test", provider: provider, label: "test@example.com", email: "test@example.com",
                                 plan: nil, enabled: true)
        // "switch": your login runs out and a team login takes over; "route": your login is
        // already out, so the session starts on a team login and moves to another when it runs out.
        let teamMode = ProcessInfo.processInfo.environment["AGTERM_SWITCH_TEAM"]
        store.update { $0.autoSwitch = true; $0.continueAfterSwitch = true }
        if teamMode == nil { store.add(test) }
        AccountStore.saveRouting(AccountRouting())
        if teamMode != nil {
            TeamAccounts.shared.start()
            if teamMode == "route" {
                UsageMonitor.shared.stubs[UsageMonitor.key(provider, AccountStore.native)] = UsageReading(
                    windows: [UsageWindow(name: "5-hour", usedPercent: 100, resetsAt: Date().addingTimeInterval(10_800))], checkedAt: Date())
                UsageMonitor.shared.refresh(provider, AccountStore.native)
            }
        }
        // The stand-in account isn't really signed in; a signed-out login is never switched to.
        UsageMonitor.shared.stubs[UsageMonitor.key(provider, test.id)] = UsageReading(
            windows: [UsageWindow(name: "Weekly", usedPercent: 50, resetsAt: Date().addingTimeInterval(86_400))],
            email: test.email, checkedAt: Date())
        DispatchQueue.global().async {
            for provider in AccountProvider.allCases where ProcessInfo.processInfo.environment["AGTERM_SWITCH_PROVIDER"] == nil {
                let result = UsageProbe.read(provider, home: nil)
                let windows = result.reading?.windows.map { "\($0.name) \(Int($0.usedPercent))%" }.joined(separator: ", ") ?? "none"
                print("selftest: probe \(provider.rawValue) signedIn=\(result.signedIn) plan=\(result.reading?.plan ?? "?") windows=[\(windows)] error=\(result.error ?? "none")")
            }
        }
        let tab = controller.sessions[0]
        after(2) {
            tab.view.send(txt: "export PATH=\"$AGTERM_BIN:\(fakes):$PATH\"; clear; FAKE_HIT_AFTER=3 \(provider.rawValue)\r")
        }
        if teamMode == "switch" {
            // A suspended agent still holds its login: the loan must stay out until it exits.
            after(20) { tab.view.send(txt: "\u{1A}") }
            after(25) {
                print("selftest: switch: team homes while suspended:", ((try? FileManager.default.contentsOfDirectory(atPath: AccountStore.dir.path)) ?? []).filter(TeamPool.isLocalID))
                tab.view.send(txt: "fg\r")
            }
        }
        after(6) {
            print("selftest: switch: routing at start:", AccountStore.loadRouting().active)
            print("selftest: switch: before:", screenLine(tab, containing: "start resume=0") ?? "agent didn't start")
        }
        after(32) {
            let home = AccountStore.home(test.id).path
            print("selftest: switch: limit seen:", screenLine(tab, containing: "hit limit") != nil)
            print("selftest: switch: resumed:", screenLine(tab, containing: "resume=1") ?? "no")
            print("selftest: switch: on test account:", screenLine(tab, containing: teamMode == nil ? "accounts/switch" : "accounts/team-") != nil, home.suffix(30))
            if teamMode != nil {
                print("selftest: switch: team homes:", ((try? FileManager.default.contentsOfDirectory(atPath: AccountStore.dir.path)) ?? []).filter(TeamPool.isLocalID))
                print("selftest: switch: wrapper said:", screenLine(tab, containing: "borrowing") ?? "nothing")
                // Check Usage on the login nobody holds, and on the one this tab holds (refused).
                let team = TeamAccounts.shared
                for account in team.accounts { team.check(account) }
                after(15) { print("selftest: switch: team check:", team.readings.keys.sorted(), "errors:", team.checkErrors) }
            }
            let args = tab.screenText().split(separator: "\n").filter { $0.contains("FAKE-ARGS") }.last.map(String.init) ?? "no"
            print("selftest: switch: resumed with:", args.replacingOccurrences(of: "FAKE-ARGS:", with: "").prefix(160))
            print("selftest: switch: told to continue:", args.contains("Continue where you left off."))
            print("selftest: switch: launch record:", AccountStore.launch(tabID: tab.tabID, provider: provider).map { "\($0.account) args=\($0.args)" } ?? "none")
            print("selftest: switch: routing:", AccountStore.loadRouting())
            let fm = FileManager.default
            let items = ((try? fm.contentsOfDirectory(atPath: home)) ?? []).sorted().map { name -> String in
                (try? fm.destinationOfSymbolicLink(atPath: home + "/" + name)).map { "\(name)→\(($0 as NSString).lastPathComponent)" } ?? name
            }
            print("selftest: switch: home:", items.joined(separator: " "))
            if provider == .codex, let config = try? String(contentsOfFile: home + "/config.toml", encoding: .utf8) {
                print("selftest: switch: codex config head:", config.split(separator: "\n").prefix(3).joined(separator: " | "))
            }
            if provider == .claude, let data = fm.contents(atPath: home + "/.claude.json"),
               let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                print("selftest: switch: claude state keys:", state.keys.sorted().prefix(12).joined(separator: ","), "oauthAccount copied:", state["oauthAccount"] != nil)
            }
            if teamMode == "switch" {
                // Quitting with Codex still running on a team login: it's stopped, then the loan goes back.
                let started = Date()
                TeamAccounts.shared.giveBackAll()
                print("selftest: switch: quit returned loans in", String(format: "%.1fs", Date().timeIntervalSince(started)),
                      "| codex still running:", tab.isRunningProgram)
            }
            controller.sessions.forEach { $0.terminate() }
            if teamMode == nil { store.remove(test.id) }
            AccountStore.saveRouting(AccountRouting())
            try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.claude/projects/-agterm-switch-test")
            let sessions = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions")
            if let files = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil) {
                for case let file as URL in files where file.lastPathComponent.hasPrefix("rollout-agtermtest-") {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            // Loans go back once their agent has exited.
            after(teamMode == nil ? 3 : 25) {
                if teamMode != nil {
                    print("selftest: switch: team homes after exit:", ((try? FileManager.default.contentsOfDirectory(atPath: AccountStore.dir.path)) ?? []).filter(TeamPool.isLocalID))
                }
                exit(0)
            }
        }
    }

    /// Quits with Codex and another agent running, then reopens their tabs: each agent should
    /// come back on its own conversation.
    private static func restoreCheck(_ controller: MainWindowController, fakes: String) {
        controller.newTab()
        let tabs = Array(controller.sessions.suffix(2))
        after(2) {
            tabs[0].view.send(txt: "export PATH=\"$AGTERM_BIN:\(fakes):$PATH\"; cd /tmp; clear; codex -m gpt-test 'first prompt'\r")
            tabs[1].view.send(txt: "export PATH=\"$AGTERM_BIN:\(fakes):$PATH\"; cd /tmp; clear; grok --model fast\r")
        }
        after(6) {
            let saved = tabs.map { $0.snapshot() }
            for (tab, snapshot) in zip(tabs, saved) {
                print("selftest: restore: \(tab.agentName ?? "none") saves:", snapshot.resume ?? "nothing")
            }
            let before = screenLine(tabs[0], containing: "start resume=0") ?? ""
            tabs.forEach { $0.terminate() }
            // The reopened shells must find the stand-ins, not the real agents.
            for var tab in saved {
                tab.resume = tab.resume.map { "export PATH=\"$AGTERM_BIN:\(fakes):$PATH\"; clear; " + $0 }
                controller.restoreTabForTest(tab)
            }
            let restored = Array(controller.sessions.suffix(2))
            after(8) {
                let session = before.components(separatedBy: "session=").last?.components(separatedBy: " ").first ?? "?"
                print("selftest: restore: codex back:", screenLine(restored[0], containing: "resume=1") ?? "no", "| same session:",
                      screenLine(restored[0], containing: "session=\(session)") != nil)
                print("selftest: restore: grok back with:", restored[1].screenText().split(separator: "\n").last { $0.contains("FAKE-ARGS") } ?? "no")
                controller.sessions.forEach { $0.terminate() }
                let sessions = URL(fileURLWithPath: NSHomeDirectory() + "/.codex/sessions")
                for case let file as URL in FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: nil) ?? FileManager.default.enumerator(atPath: "/")!
                where file.lastPathComponent.hasPrefix("rollout-agtermtest-") { try? FileManager.default.removeItem(at: file) }
                after(1) { exit(0) }
            }
        }
    }

    /// Drags the first tab to the right with real mouse events: the tabs should reorder and
    /// the window stay put.
    private static func dragCheck(_ controller: MainWindowController) {
        guard let window = controller.window else { exit(1) }
        controller.newTab()
        controller.newTab()
        controller.showWindow(nil)
        after(1.5) {
            let first = controller.selectedTabIDForTest
            let before = controller.sessions.firstIndex { $0.tabID == first } ?? -1
            let card = controller.selectedTabCardForTest
            window.layoutIfNeeded()
            let center = card.convert(NSPoint(x: card.bounds.midX, y: card.bounds.midY), to: nil)
            print("selftest: drag: card", card.frame, "in", card.superview?.frame ?? .zero, "window?", card.window != nil)
            let frame = window.contentView?.superview
            let hit = frame?.hitTest(center)
            var chain: [String] = []
            var view = hit
            while let v = view { chain.append(String(describing: type(of: v))); view = v.superview }
            print("selftest: drag: click lands on:", chain.joined(separator: " < "), "at", center, "window", window.frame)
            let origin = window.frame.origin
            func event(_ type: NSEvent.EventType, _ dx: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: center.x + dx, y: center.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            // Queued first: a window drag would run its own loop and eat them.
            for dx in stride(from: -10, through: -400, by: -30) { NSApp.postEvent(event(.leftMouseDragged, CGFloat(dx)), atStart: false) }
            NSApp.postEvent(event(.leftMouseUp, -400), atStart: false)
            print("selftest: drag: key window:", window.isKeyWindow, "card takes first click:", card.acceptsFirstMouse(for: event(.leftMouseDown, 0)))
            window.sendEvent(event(.leftMouseDown, 0))
            after(1.5) {
                print("selftest: drag: window moved:", window.frame.origin != origin, "| dragged tab moved from", before, "to", controller.sessions.firstIndex { $0.tabID == first } ?? -1)
                exit(0)
            }
        }
    }

    /// Settings panes, ⌘K against the real model, and a new agent tab from the menu.
    private static func featureCheck(_ controller: MainWindowController, outDir: String) {
        guard let window = controller.window else { exit(1) }
        window.setContentSize(NSSize(width: 1000, height: 560))
        window.contentView?.superview?.wantsLayer = true
        let settings = SettingsWindowController.shared
        // One pane after another; the Appearance pane's first font scan can hold the main thread.
        func pane(_ i: Int) {
            guard i < settings.paneCount else { return }
            settings.selectPane(i)
            after(0.6) {
                let size = settings.window?.contentView?.bounds.size ?? .zero
                print("selftest: settings pane \(i) \(settings.window?.title ?? "?") \(Int(size.width))x\(Int(size.height))")
                let toolbar = settings.window?.toolbar
                print("selftest: settings toolbar shows \(toolbar?.visibleItems?.count ?? 0) of \(toolbar?.items.count ?? 0)")
                snapshotSettings("\(outDir)/settings-\(i).png")
                pane(i + 1)
            }
        }
        after(0.5) { pane(0) }
        // The new-agent-tab shortcut follows Settings, and a taken shortcut is caught.
        let agentAction = #selector(MainWindowController.newDefaultAgentTab)
        let menuItem = { NSApp.mainMenu?.items.compactMap { $0.submenu?.items.first { $0.action == agentAction } }.first }
        AgentIntegration.newAgentTabShortcut = KeyShortcut(key: "a", modifiers: [.control, .option])
        print("selftest: shortcut menu follows settings:", menuItem()?.keyEquivalent == "a" && menuItem()?.keyEquivalentModifierMask == [.control, .option],
              "| ⌘T taken by:", KeyShortcut(key: "t", modifiers: [.command]).conflict(in: NSApp.mainMenu, ignoring: agentAction) ?? "nothing")
        AgentIntegration.newAgentTabShortcut = .newAgentTabDefault
        let shell = controller.sessions[0]
        UserDefaults.standard.set(ProcessInfo.processInfo.environment["AGTERM_QUICK_MODEL"] ?? "auto", forKey: QuickCommandRunner.modelKey)
        after(3) { shell.view.send(txt: "cd /tmp && clear\r") }
        // Closing the bar mid-request cancels it: nothing typed, no model process left.
        after(3.2) {
            controller.toggleCommandBar()
            controller.commandBarForTest.selfTestSubmit("print the word CANCELLED-PROBE")
            after(1.5) { controller.toggleCommandBar() }
            after(4) {
                let ps = Process()
                ps.executableURL = URL(fileURLWithPath: "/bin/ps")
                ps.arguments = ["-o", "pid=,command=", "-g", String(getpgrp())]
                let pipe = Pipe()
                ps.standardOutput = pipe
                try? ps.run()
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let left = out.split(separator: "\n").filter { $0.contains("CANCELLED-PROBE") }.count
                print("selftest: ⌘K cancel: model processes left:", left, "| typed:", screenLine(shell, containing: "CANCELLED") != nil)
            }
        }
        after(8) {
            controller.toggleCommandBar()
            controller.commandBarForTest.selfTestSubmit("show the 3 biggest files in this folder")
            let start = Date()
            func wait() {
                let text = controller.commandBarForTest.selfTestResult
                if text.hasPrefix("Writing") { return after(0.2, wait) }
                print("selftest: ⌘K reply in \(String(format: "%.1f", Date().timeIntervalSince(start))) s:", text)
                print("selftest: ⌘K window width:", Int(window.frame.width), "| bar width:", Int(controller.commandBarForTest.frame.width))
                snapshot(window, "\(outDir)/command-bar.png")
                controller.commandBarForTest.selfTestSubmit(nil)
                after(0.8) {
                    print("selftest: ⌘K inserted at prompt:", screenLine(shell, containing: String(text.prefix(12))) ?? "not found",
                          "| bar closed:", controller.commandBarForTest.superview == nil)
                    controller.newAgentTab(.claude)
                    let agentTab = controller.sessions[controller.sessions.count - 1]
                    // A stand-in agent showing Claude Code's permission prompt, in the selected tab.
                    let fakes = ProcessInfo.processInfo.environment["AGTERM_FAKE_AGENTS"] ?? outDir
                    controller.select(0)
                    shell.view.send(txt: "\u{15}clear; printf 'Do you want to proceed?\\n\\xe2\\x9d\\xaf 1. Yes\\n  2. No\\nEsc to cancel\\n'; \(fakes)/claude 600\r")
                    after(5) {
                        print("selftest: agent tab foreground:", agentTab.agentName ?? "none", "folder:", agentTab.folder)
                        print("selftest: prompt on screen, selected tab:", shell.status.label, "agent:", shell.agentName ?? "none")
                        shell.view.send(txt: "\u{3}")
                        after(1.5) {
                            shell.view.send(txt: "clear\r")
                            after(1.5) {
                                print("selftest: after answering:", shell.status.label)
                                controller.sessions.forEach { $0.terminate() }
                                after(1) { exit(0) }
                            }
                        }
                    }
                }
            }
            after(0.5, wait)
        }
    }

    private static func checkDrops(into session: TerminalSession, outDir: String) {
        let file = URL(fileURLWithPath: outDir).appendingPathComponent("My Shot (1).png")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let files = NSPasteboard(name: .init("agterm.selftest.files"))
        files.clearContents()
        files.writeObjects([file as NSURL])
        DropReader.text(from: files) { text in
            print("selftest: file drop ->", text ?? "nil")
            session.view.send(txt: "echo " + (text ?? "") + "\r")
        }
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let images = NSPasteboard(name: .init("agterm.selftest.image"))
        images.clearContents()
        images.writeObjects([image])
        DropReader.text(from: images) { text in
            let path = text?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\", with: "") ?? ""
            print("selftest: image drop ->", text ?? "nil", "exists:", FileManager.default.fileExists(atPath: path))
        }
        after(0.6) {
            let screen = (0..<session.view.getTerminal().rows).compactMap { session.view.getTerminal().getLine(row: $0)?.translateToString(trimRight: true) }
            print("selftest: shell echoed:", screen.first { $0.hasPrefix("My Shot") || $0.contains("/My Shot (1).png") } ?? "not found")
        }
    }

    /// A tiny borderless window far off screen, so the window server has a real window to blur.
    private static func checkBlur() {
        let probe = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1, height: 1),
                             styleMask: .borderless, backing: .buffered, defer: false)
        probe.isOpaque = false
        probe.backgroundColor = .clear
        probe.orderBack(nil)
        print("selftest: blur api available:", BackgroundBlur.isAvailable, "applied:", BackgroundBlur.set(probe, radius: 20))
        probe.orderOut(nil)
    }

    /// The website screenshot: real tabs with stand-in agents (AGTERM_FAKE_AGENTS) in small git
    /// repos under `dir`, and real file edits so agterm measures the diffs itself.
    private static func showcase(_ controller: MainWindowController, dir: String, outDir: String) {
        guard let window = controller.window else { return }
        window.setContentSize(NSSize(width: 1240, height: 740))
        window.contentView?.superview?.wantsLayer = true
        let agent = (ProcessInfo.processInfo.environment["AGTERM_FAKE_AGENTS"] ?? dir) + "/claude"
        let neutral = "PROMPT='%1~ %# '; clear"
        let scripts = [
            "cd \(dir)/web; \(neutral); printf '\\033]0;◐ Fix login redirect loop\\007'; cat \(dir)/demo.ans; \(agent) 600",
            "cd \(dir)/api; \(neutral); printf '\\033]0;✳ Rename env vars in workers\\007'; sleep 3; printf '\\a'; \(agent) 600",
            "cd \(dir)/design; \(neutral); printf '\\033]0;◐ Add dark mode tokens\\007'; \(agent) 7; printf '\\033]0;✳ Add dark mode tokens\\007'; \(agent) 600",
            "cd \(dir)/docs; \(neutral)",
        ]
        for _ in 1..<scripts.count { controller.newTab() }
        for (i, script) in scripts.enumerated() { send(controller, i, script) }
        after(0.3) { controller.select(0) }
        // Edits after the agents have started (baselines are taken within ~4 s of each start).
        after(9) {
            func edit(_ repo: String, keep: Int, add: Int) {
                let lines = (0..<60).map { "export const line\($0) = \($0)" }
                let kept = Array(lines.prefix(keep)) + (0..<add).map { "export const added\($0) = \"\($0)\"" }
                try? (kept.joined(separator: "\n") + "\n").write(toFile: "\(dir)/\(repo)/src/base.ts", atomically: true, encoding: .utf8)
            }
            edit("web", keep: 59, add: 4)
            edit("api", keep: 42, add: 18)
            let tokens = (0..<142).map { "  --token-\($0): #\(String(format: "%06x", $0 * 9973 % 0xffffff));" }
            try? (tokens.joined(separator: "\n") + "\n").write(toFile: "\(dir)/design/src/dark.css", atomically: true, encoding: .utf8)
            edit("design", keep: 51, add: 0)
        }
        after(15) {
            snapshot(window, "\(outDir)/showcase.png")
            controller.sessions.forEach { $0.terminate() }
            after(1) { exit(0) }
        }
    }

    /// Numbers for the website: memory with 1 and 10 tabs, launch to first prompt, new-tab time.
    private static func measure(_ controller: MainWindowController) {
        let launched = processStart()
        var firstPrompt: Double?
        func poll() {
            if firstPrompt == nil, screenLine(controller.sessions[0], containing: "%") != nil {
                firstPrompt = Date().timeIntervalSince(launched)
            }
            if firstPrompt == nil { return after(0.01, poll) }
            after(1.5) {
                let oneTab = residentMB()
                let start = Date()
                for _ in 0..<9 { controller.newTab() }
                let tabMs = Date().timeIntervalSince(start) / 9 * 1000
                after(3) {
                    print(String(format: "measure: first prompt %.0f ms | new tab %.1f ms | memory 1 tab %.0f MB | 10 tabs %.0f MB",
                                 firstPrompt! * 1000, tabMs, oneTab, residentMB()))
                    measureSwitch(controller)
                    measurePolling(controller)
                    measureIdleCPU(controller) { measureEcho(controller) { measureThroughput(controller) {
                        controller.sessions.forEach { $0.terminate() }
                        after(1) { exit(0) }
                    } } }
                }
            }
        }
        poll()
    }

    private static func ms(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    private static func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    private static func measureSwitch(_ controller: MainWindowController) {
        let times = (0..<40).map { i in ms { controller.select(i % controller.sessions.count); controller.window?.displayIfNeeded() } }
        controller.select(0)
        print(String(format: "measure: tab switch median %.2f ms max %.2f ms", median(times), times.max()!))
    }

    /// Main-thread cost of the background timers with 10 tabs open.
    private static func measurePolling(_ controller: MainWindowController) {
        let now = Date()
        let process = (0..<20).map { _ in ms { controller.sessions.forEach { $0.pollProcess() } } }
        let tick = (0..<20).map { _ in ms { controller.sessions.forEach { $0.tick(now: now) } } }
        let render = (0..<20).map { _ in ms { controller.renderForTest(); controller.window?.displayIfNeeded() } }
        print(String(format: "measure: pollProcess×10 %.2f ms | tick×10 %.3f ms | render %.2f ms", median(process), median(tick), median(render)))
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }

    private static func measureIdleCPU(_ controller: MainWindowController, then next: @escaping () -> Void) {
        let cpu = cpuSeconds(), wall = Date()
        after(10) {
            print(String(format: "measure: idle CPU with 10 tabs %.2f%%", (cpuSeconds() - cpu) / Date().timeIntervalSince(wall) * 100))
            next()
        }
    }

    /// Keystroke sent to the shell until its echo is on screen.
    private static func measureEcho(_ controller: MainWindowController, then next: @escaping () -> Void) {
        let session = controller.sessions[0]
        var times: [Double] = []
        func one(_ n: Int) {
            guard n < 20 else {
                session.view.send(txt: "\u{15}")
                print(String(format: "measure: keystroke echo median %.2f ms max %.2f ms", median(times), times.max()!))
                return after(0.3, next)
            }
            let terminal = session.view.getTerminal()
            let before = terminal.getCursorLocation().x
            let start = DispatchTime.now().uptimeNanoseconds
            session.view.send(txt: "x")
            func wait() {
                if terminal.getCursorLocation().x != before {
                    times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                    return after(0.05) { one(n + 1) }
                }
                DispatchQueue.main.async(execute: wait)
            }
            wait()
        }
        one(0)
    }

    /// A command printing lots of lines, until the shell is back.
    private static func measureThroughput(_ controller: MainWindowController, lines: Int = 200_000, then next: @escaping () -> Void) {
        let session = controller.sessions[0]
        let start = Date()
        session.view.send(txt: "seq 1 \(lines); echo THRU-$((6*7))\r")
        func wait() {
            if screenLine(session, containing: "THRU-42") != nil {
                print(String(format: "measure: %dk lines of output %.0f ms", lines / 1000, Date().timeIntervalSince(start) * 1000))
                return next()
            }
            after(0.005, wait)
        }
        wait()
    }

    private static func processStart() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6)
    }

    /// Physical footprint, what Activity Monitor shows as Memory.
    private static func residentMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// A background command with quiet spells (like `brew upgrade` between casks) finishes once.
    private static func pauseCheck(_ controller: MainWindowController) {
        controller.newTab()
        let session = controller.sessions[1]
        var done = 0
        let notify = session.onStatusChange
        session.onStatusChange = { status in
            if status == .done { done += 1 }
            notify?(status)
        }
        send(controller, 1, "for i in 1 2 3; do echo upgrading cask $i; sleep 3; done")
        after(0.5) { controller.select(0) }
        after(14) {
            print("selftest: pause done count:", done, "final:", session.status.label)
            exit(0)
        }
    }

    /// `cd agter` lists ~/…/agterm under the cursor, and ⇥ (a real key event) puts its path on the line.
    private static func cdCheck(_ controller: MainWindowController, outDir: String) {
        guard let window = controller.window else { exit(1) }
        window.setContentSize(NSSize(width: 900, height: 520))
        window.contentView?.superview?.wantsLayer = true
        let session = controller.sessions[0]
        send(controller, 0, "cd ~ && clear")
        after(2.5) { session.view.send(txt: "cd agter") }
        after(3.5) {
            print("selftest: cd shown:", controller.cdSuggestionsForTest.shownForTest)
            snapshot(window, "\(outDir)/cd-suggestions.png")
            let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: "\t",
                                       charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)
            tab.map { NSApp.postEvent($0, atStart: false) }
        }
        after(4.5) {
            print("selftest: cd line:", screenLine(session, containing: "cd ") ?? "none")
            print("selftest: cd hidden after accept:", controller.cdSuggestionsForTest.shownForTest.isEmpty)
            session.view.send(txt: "\u{15}")
        }
        after(5) { exit(0) }
    }

    /// What's New with every release plays into a new tab, prompt below, in Ink and then Paper.
    private static func whatsNewCheck(_ controller: MainWindowController, outDir: String) {
        guard let window = controller.window else { exit(1) }
        window.setContentSize(NSSize(width: 900, height: 820))
        window.contentView?.superview?.wantsLayer = true
        let render = WhatsNew.allLines()
        var shown = 0
        controller.showWhatsNew { columns in
            let lines = render(columns)
            shown = lines.count
            return lines
        }
        after(4) {
            let session = controller.sessions[controller.sessions.count - 1]
            let terminal = session.view.getTerminal()
            let rows = (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            let history = rows.lastIndex { $0.contains("full history:") }
            let prompt = rows.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            print("selftest: whatsnew: lines shown: \(shown)")
            print("selftest: whatsnew: prompt below:", history.map { h in prompt.map { $0 > h } ?? false } ?? false)
            snapshot(window, "\(outDir)/whats-new.png")
            let theme = Preferences.shared.appearance.themeID
            Preferences.shared.update { $0.themeID = "paper" }
            after(1) {
                snapshot(window, "\(outDir)/whats-new-paper.png")
                Preferences.shared.update { $0.themeID = theme }
                after(0.5) { exit(0) }
            }
        }
    }

    private static func screenLine(_ session: TerminalSession, containing text: String) -> String? {
        let terminal = session.view.getTerminal()
        return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true) }
            .first { $0.contains(text) }
    }

    private static func send(_ controller: MainWindowController, _ index: Int, _ line: String) {
        let view = controller.sessions[index].view
        after(0.6) { view.send(txt: line + "\r") }
    }

    private static func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func snapshotSettings(_ path: String) {
        guard let view = SettingsWindowController.shared.window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Renders the window's layer tree (title bar included) without it being on screen.
    /// Layer rendering, unlike cacheDisplay, includes layer background colors.
    private static func snapshot(_ window: NSWindow, _ path: String) {
        guard let frameView = window.contentView?.superview, let layer = frameView.layer else { return }
        frameView.displayIfNeeded()
        let scale: CGFloat = 2
        let size = frameView.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        // A stand-in desktop, then the terminal color: SwiftTerm clears its cells to transparent
        // and lets its layer color show through, which layer rendering doesn't reproduce.
        let full = CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))
        context.cgContext.setFillColor(NSColor(srgbRed: 0.29, green: 0.44, blue: 0.65, alpha: 1).cgColor)
        context.cgContext.fill(full)
        context.cgContext.setFillColor(Theme.bg.cgColor)
        context.cgContext.fill(full)
        context.cgContext.scaleBy(x: scale, y: scale)
        context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        layer.render(in: context.cgContext)
        context.cgContext.endTransparencyLayer()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
#endif
