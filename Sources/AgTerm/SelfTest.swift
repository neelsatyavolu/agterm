#if DEBUG
import AppKit

/// Debug-only visual check: `AGTERM_SELFTEST=<dir> AGTERM_FIXTURE=<git repo> .build/debug/AgTerm`.
/// Never shows or focuses the window. Scripts a few tabs, then writes PNGs of the window to <dir>.
enum SelfTest {
    static func run(_ controller: MainWindowController, outDir: String) {
        NSApp.setActivationPolicy(.accessory)
        guard let window = controller.window else { exit(1) }
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

        // One tab runs a long job in the foreground, like an agent would.
        after(11.3) { controller.sessions[0].view.send(txt: "sleep 777\r") }
        after(12) { controller.sessions.forEach { $0.terminate() } }
        // Closed shells must be reaped, not left as zombies.
        after(13) {
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
