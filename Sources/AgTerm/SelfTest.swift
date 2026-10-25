#if DEBUG
import AppKit

/// Debug-only visual check: `AGTERM_SELFTEST=<dir> AGTERM_FIXTURE=<git repo> .build/debug/AgTerm`.
/// Never shows or focuses the window. Scripts a few tabs, then writes PNGs of the window to <dir>.
enum SelfTest {
    static func run(_ controller: MainWindowController, outDir: String) {
        NSApp.setActivationPolicy(.accessory)
        guard let window = controller.window else { exit(1) }
        if ProcessInfo.processInfo.environment["AGTERM_MEASURE"] == "1" { return measure(controller) }
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

        // One tab runs a long job in the foreground, like an agent would.
        after(23.6) { controller.sessions[0].view.send(txt: "sleep 777\r") }
        after(24.3) { controller.sessions.forEach { $0.terminate() } }
        // Closed shells must be reaped, not left as zombies.
        after(25.3) {
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
                    controller.sessions.forEach { $0.terminate() }
                    after(1) { exit(0) }
                }
            }
        }
        poll()
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
