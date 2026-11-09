#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// The website's feature shots, taken after the showcase (`scripts/site-shots.sh`): the tabs on
    /// the left (`showcase-side.png`), the Chat view on the first tab (`showcase-chat.png`, and
    /// `showcase-chat-paper.png`) and the changes panel beside its terminal (`showcase-changes.png`).
    static func siteShots(_ controller: MainWindowController, outDir: String, done: @escaping () -> Void) {
        guard let window = controller.window else { return done() }
        let theme = Preferences.shared.appearance.themeID
        let wasLeft = controller.tabsOnLeft
        let web = controller.sessions[0]
        if !wasLeft { controller.toggleTabsOnLeft() }
        controller.select(0)
        after(0.8) {
            snapshot(window, "\(outDir)/showcase-side.png")
            controller.setChat(true, for: web)
            after(1.5) {
                snapshot(window, "\(outDir)/showcase-chat.png")
                Preferences.shared.update { $0.themeID = "paper" }
                after(0.6) {
                    snapshot(window, "\(outDir)/showcase-chat-paper.png")
                    Preferences.shared.update { $0.themeID = theme }
                    controller.setChat(false, for: web)
                    window.setContentSize(NSSize(width: 1480, height: 740))
                    controller.toggleChanges()
                    after(1.5) {
                        snapshot(window, "\(outDir)/showcase-changes.png")
                        controller.toggleChanges()
                        if !wasLeft { controller.toggleTabsOnLeft() }
                        done()
                    }
                }
            }
        }
    }
}

/// Claude Code transcripts for the showcase tabs, so their cards show a model, spend and lines
/// changed and the first tab's Chat view has a conversation. `write` puts them under
/// ~/.claude/projects (where agterm looks them up by session id); `remove` takes them out again.
enum SiteFixtures {
    static let ids = ["web": "517e0000-0000-4000-8000-000000000001",
                      "api": "517e0000-0000-4000-8000-000000000002",
                      "design": "517e0000-0000-4000-8000-000000000003"]
    static var folder: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects/agterm-site-shots")
    }

    static func write() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (repo, lines) in ["web": web, "api": api, "design": design] {
            let file = folder.appendingPathComponent("\(ids[repo]!).jsonl")
            try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    static func remove() { try? FileManager.default.removeItem(at: folder) }

    /// An assistant line with token usage, which is what agterm counts edits and spend from.
    private static func turn(_ uuid: String, _ content: [[String: Any]], minute: Int, output: Int = 420) -> String {
        ChatFixtures.json(["type": "assistant", "uuid": uuid, "timestamp": String(format: "2026-11-08T10:%02d:00.000Z", minute),
                           "message": ["content": content, "model": "claude-opus-5-5",
                                       "usage": ["input_tokens": 1800, "output_tokens": output, "cache_read_input_tokens": 52000]]])
    }

    private static func user(_ uuid: String, _ content: Any, minute: Int) -> String {
        ChatFixtures.claudeLine("user", uuid, content, minute: minute)
    }

    private static var web: [String] {
        typealias F = ChatFixtures
        let reply = """
            Fixed. `afterSignIn` passed `?to=` straight to `next()`, so a link like \
            `/login?to=/login` sent a signed-in user back to the form.

            - Falls back to `/` when `to` is missing
            - Ignores `to` when it points at `/login`

            All 14 auth tests pass, including two new ones for the loop.
            """
        return [
            user("u1", [["type": "text", "text": "the login page bounces back to /login after sign-in"]], minute: 1),
            turn("a1", [["type": "thinking", "thinking": "Trace where the redirect target comes from."],
                        ["type": "text", "text": "I'll trace the redirect. Reading the session middleware first."]], minute: 2),
            turn("a2", [F.use("t1", "Read", ["file_path": "/w/web/src/auth/session.ts"]),
                        F.use("t2", "Grep", ["pattern": "next\\(", "path": "src/auth"])], minute: 2),
            user("r1", [F.result("t1", "84 lines"), F.result("t2", "Found 3 files")], minute: 2),
            turn("a3", [["type": "text", "text": "The callback trusts the `?to=` parameter even when it points back at /login. Fixing the guard:"],
                        F.use("t3", "Edit", ["file_path": "/w/web/src/auth/redirect.ts",
                                             "old_string": "  return next(url.searchParams.get(\"to\"))",
                                             "new_string": "  // Never send a signed-in user back to the form.\n  const to = url.searchParams.get(\"to\") ?? \"/\"\n  if (to.startsWith(\"/login\")) return next(\"/\")\n  return next(to)"])],
                 minute: 3, output: 900),
            user("r3", [F.result("t3", "ok")], minute: 3),
            turn("a4", [F.use("t4", "Bash", ["command": "npm test -- auth"])], minute: 4),
            user("r4", [F.result("t4", "✓ redirect after sign-in (12 ms)\n✓ keeps ?to= for other pages (3 ms)\nTests  14 passed (14)")], minute: 4),
            turn("a5", [F.use("t5", "Agent", ["description": "Check the sign-out path", "subagent_type": "Explore", "prompt": "look"])], minute: 5),
            user("r5", [F.result("t5", "Sign-out clears the session and redirects to /; no loop there.")], minute: 6),
            turn("a6", [["type": "text", "text": reply]], minute: 7, output: 1200),
        ]
    }

    private static var api: [String] {
        let old = (1...18).map { "export const v\($0) = process.env.WORKER_SETTING_\($0)" }.joined(separator: "\n")
        return [
            user("u1", [["type": "text", "text": "rename the WORKER_ env vars to APP_"]], minute: 1),
            turn("a1", [ChatFixtures.use("t1", "Edit", ["file_path": "/w/api/src/env.ts", "old_string": old,
                                                        "new_string": old.replacingOccurrences(of: "WORKER_", with: "APP_")])],
                 minute: 2, output: 2600),
        ]
    }

    private static var design: [String] {
        let tokens = (0..<142).map { "  --token-\($0): #\(String(format: "%06x", $0 * 9973 % 0xffffff));" }.joined(separator: "\n")
        let old = (51..<60).map { "export const line\($0) = \($0)" }.joined(separator: "\n")
        return [
            user("u1", [["type": "text", "text": "add dark mode tokens"]], minute: 1),
            turn("a1", [ChatFixtures.use("t1", "Write", ["file_path": "/w/design/src/dark.css", "content": tokens])], minute: 2, output: 5200),
            turn("a2", [ChatFixtures.use("t2", "Edit", ["file_path": "/w/design/src/base.ts", "old_string": old, "new_string": ""])], minute: 3),
        ]
    }
}
#endif
