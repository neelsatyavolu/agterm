#if DEBUG
import AgTermCore
import AppKit

/// AGTERM_MEMORY_CHECK=1: Window → Project Memory for a fixture repo (its store written here,
/// removed after), snapshotted in Ink and Paper as `memory-ink.png` and `memory-paper.png`.
extension SelfTest {
    static func memoryCheck(outDir: String) {
        let repo = outDir + "/memory-repo"
        try? FileManager.default.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)
        guard let memory = AgentIntegration.projectMemory(repo) else { print("selftest: memory: no project"); exit(2) }
        try? FileManager.default.createDirectory(atPath: memory.dataDir, withIntermediateDirectories: true)
        let entries: [[String: Any]] = [
            ["kind": "decision", "title": "Release builds use scripts/zap.sh", "binding": true,
             "content": "Never run make release; it skips notarization. scripts/zap.sh --signed is the only supported release build.",
             "updatedAt": "2026-11-12T18:02:11.000Z"],
            ["kind": "fact", "title": "Date tests need TZ=UTC",
             "content": "tests/dates fails under local time zones; run it with TZ=UTC.", "updatedAt": "2026-11-11T09:40:00.000Z"],
            ["kind": "issue", "title": "zap.sh Linux leg fails on arm64", "content": "Open: the Linux step fails on arm64 runners.",
             "updatedAt": "2026-11-10T15:00:00.000Z"],
        ]
        let sessions: [[String: Any]] = [
            ["title": "Move release builds to zap.sh", "updatedAt": "2026-11-12T18:05:00.000Z",
             "summary": "Moved release builds to scripts/zap.sh and removed the make target. Left: the arm64 Linux leg."],
        ]
        func write(_ object: [String: Any], _ path: String) {
            (try? JSONSerialization.data(withJSONObject: object)).map { try? $0.write(to: URL(fileURLWithPath: path)) }
        }
        write(["entries": entries], memory.store)
        write(["sessions": sessions], memory.handoffStore)

        let controller = ProjectMemoryWindowController.shared
        controller.show(cwd: repo)
        controller.window?.orderOut(nil)
        let model = controller.model
        print("selftest: memory: repo:", model.repo == memory.project.repoPath, "| entries:", model.entries.count,
              "| binding first:", model.entries.first?.binding == true, "| handoffs:", model.handoffs.count)
        let saved = Preferences.shared.appearance
        func snap(_ themes: [String]) {
            guard let theme = themes.first else {
                Theme.apply(saved)
                try? FileManager.default.removeItem(atPath: memory.dataDir)
                print("selftest: memory: snapshots written:", FileManager.default.fileExists(atPath: outDir + "/memory-paper.png"))
                exit(model.entries.count == 3 && model.handoffs.count == 1 ? 0 : 2)
            }
            var look = saved
            look.themeID = theme
            Theme.apply(look)
            controller.applyAppearance()
            model.objectWillChange.send()
            after(0.5) {
                snapshotHosted(controller.window, "\(outDir)/memory-\(theme).png")
                snap(Array(themes.dropFirst()))
            }
        }
        after(0.5) { snap(["ink", "paper"]) }
    }
}
#endif
