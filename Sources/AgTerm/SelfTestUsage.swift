#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// The Usage window: `AGTERM_USAGE_CHECK=1 AGTERM_SELFTEST=<dir>`. Stands in fixture events and
    /// stubbed limits (no transcripts read, no CLI asked), then snapshots the window in Ink and
    /// Paper as `usage-ink.png` and `usage-paper.png` without putting it on screen.
    static func usageCheck(outDir: String) {
        let monitor = UsageMonitor.shared
        UsageScanner.shared.stubEvents = usageFixture(now: Date())
        for provider in AccountProvider.allCases {
            monitor.stubs[UsageMonitor.key(provider, AccountStore.native)] = UsageReading(
                windows: [UsageWindow(name: "5-hour", usedPercent: provider == .claude ? 64 : 18, resetsAt: Date().addingTimeInterval(7_500)),
                          UsageWindow(name: "Weekly", usedPercent: provider == .codex ? 100 : 41, resetsAt: Date().addingTimeInterval(300_000))],
                plan: provider == .claude ? "Claude Max" : nil, email: "you@example.com", checkedAt: Date())
        }
        let controller = UsageWindowController.shared
        controller.model.period = .month
        controller.model.refresh()
        let saved = Preferences.shared.appearance

        after(1.5) {
            let report = controller.model.report
            let month = report.summary(.month)
            let built = report.days.count == UsageReport.dayCount && month.totals.costUSD > 0
            print("selftest: usage: 30 days built with cost:", built, String(format: "$%.2f", month.totals.costUSD))
            let ranked = month.models.first?.name == "claude-opus-5-5" && month.projects.first?.name == "agterm"
            print("selftest: usage: models and projects ranked by cost:", ranked)
            let limits = monitor.reading(.claude, AccountStore.native)?.windows.count == 2
            print("selftest: usage: limits read:", limits)
            // SwiftUI redraws on the next pass after a theme change, so each snapshot waits a moment.
            func snap(_ themes: [String], written: Bool) {
                guard let theme = themes.first else {
                    print("selftest: usage: snapshots written:", written)
                    Theme.apply(saved)
                    exit(built && ranked && limits && written ? 0 : 2)
                }
                var look = saved
                look.themeID = theme
                Theme.apply(look)
                controller.applyAppearance()
                controller.model.objectWillChange.send()
                after(0.5) {
                    let path = "\(outDir)/usage-\(theme).png"
                    snapshotHosted(controller.window, path)
                    snap(Array(themes.dropFirst()), written: written && FileManager.default.fileExists(atPath: path))
                }
            }
            snap(["ink", "paper"], written: true)
        }
    }

    /// The window's SwiftUI content, drawn without being on screen.
    private static func snapshotHosted(_ window: NSWindow?, _ path: String) {
        guard let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// A month of Claude and Codex turns across two projects.
    private static func usageFixture(now: Date) -> [UsageEvent] {
        (0..<30).flatMap { day -> [UsageEvent] in
            let at = now.addingTimeInterval(-Double(day) * 86400 - 600)
            var opus = UsageEvent(at: at, provider: "ClaudeCode", model: "claude-opus-5-5", projectKey: "agterm", sessionID: "c\(day / 3)")
            opus.tokensIn = 4_000 + day * 300
            opus.tokensOut = 2_000
            opus.cacheRead = 180_000
            opus.costUSD = 1.5 + Double((day * 7) % 5)
            var codex = UsageEvent(at: at.addingTimeInterval(-1800), provider: "Codex", model: "gpt-5.5-codex", projectKey: "site", sessionID: "x\(day / 2)")
            codex.tokensIn = 20_000
            codex.tokensOut = 3_000
            codex.costUSD = 0.4 + Double(day % 3) * 0.3
            return day % 6 == 5 ? [codex] : [opus, codex]
        }
    }
}
#endif
