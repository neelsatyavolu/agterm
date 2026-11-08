#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// Search Conversations: `AGTERM_SEARCH_CHECK=1 AGTERM_SELFTEST=<dir>`. Writes a Claude Code,
    /// Codex and Grok conversation under `<dir>/fixture`, opens the window (`search-recent.png`),
    /// searches (`search-ink.png`, then `search-paper.png` on Paper) and resumes the first result,
    /// which must open a tab in its folder typing its resume command (echoed, so no agent starts).
    /// With `AGTERM_SEARCH_REAL=1` it reads your real conversations instead and prints timings.
    static func searchCheck(_ controller: MainWindowController, outDir: String) {
        setvbuf(stdout, nil, _IOLBF, 0)
        let search = ConversationSearchWindow.shared
        let real = ProcessInfo.processInfo.environment["AGTERM_SEARCH_REAL"] == "1"
        let cache = URL(fileURLWithPath: outDir).appendingPathComponent("conversation-search.plist")
        try? FileManager.default.removeItem(at: cache)
        search.cacheOverride = cache
        if !real { search.rootsOverride = searchFixture(URL(fileURLWithPath: outDir).appendingPathComponent("fixture")) }
        let theme = Preferences.shared.appearance.themeID
        Preferences.shared.update { $0.themeID = "ink" }
        let started = Date()
        controller.searchConversations()
        search.panelForTest?.contentView?.superview?.wantsLayer = true
        waitFor({ search.statusForTest.hasPrefix("Recent") || search.statusForTest.hasPrefix("No ") }, timeout: 600) { ok in
            print("selftest: search read conversations:", ok, search.statusForTest, String(format: "%.1fs", Date().timeIntervalSince(started)))
            after(0.3) { search.panelForTest.map { snapshot($0, "\(outDir)/search-recent.png") } }
            after(0.5) {
                let typed = Date()
                search.typeForTest(real ? "agterm" : "redirect")
                waitFor({ !search.statusForTest.hasPrefix("Recent") }, timeout: 30) { _ in
                    print("selftest: search results:", search.resultCountForTest, search.statusForTest,
                          String(format: "%.0fms", Date().timeIntervalSince(typed) * 1000))
                    if !real, search.resultCountForTest != 1 { print("selftest: FAIL expected 1 match") }
                    after(0.3) { search.panelForTest.map { snapshot($0, "\(outDir)/search-ink.png") } }
                    after(0.5) {
                        Preferences.shared.update { $0.themeID = "paper" }
                        controller.searchConversations()
                    }
                    after(1) { search.panelForTest.map { snapshot($0, "\(outDir)/search-paper.png") } }
                    after(1.2) { resumeFirst(controller, outDir: outDir, theme: theme) }
                }
            }
        }
    }

    private static func resumeFirst(_ controller: MainWindowController, outDir: String, theme: String) {
        let search = ConversationSearchWindow.shared
        let open = search.openTab
        var chosen: (folder: String, command: String)?
        search.openTab = { folder, command in
            chosen = (folder, command)
            open?(folder, "echo " + command)
        }
        let tabs = controller.sessions.count
        print("selftest: search selected row:", search.selectedRowForTest, "of", search.resultCountForTest)
        search.openSelectedForTest()
        after(3) {
            let session = controller.sessions.last
            print("selftest: search resume:", chosen?.command ?? "none", "in", chosen?.folder ?? "none")
            print("selftest: search opened tab:", controller.sessions.count == tabs + 1, "cwd", session?.cwd ?? "none",
                  "panel closed:", search.panelForTest?.isVisible == false)
            if let session { print("selftest: search tab shows:", screenLine(session, containing: "--resume") ?? "nothing") }
            Preferences.shared.update { $0.themeID = theme }
            after(0.5) { exit(0) }
        }
    }

    /// One conversation per agent; only the Claude Code one mentions a redirect.
    private static func searchFixture(_ dir: URL) -> [ConversationRoot] {
        try? FileManager.default.removeItem(at: dir)
        let folder = dir.appendingPathComponent("app").path
        func write(_ lines: [String], _ path: String) {
            let url = dir.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        write([
            #"{"type":"user","cwd":"\#(folder)","message":{"role":"user","content":"The login page sends you round a redirect loop after signing in with Google. Find out why."}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"The callback sets the cookie on the wrong domain, so the redirect check never sees it."}]}}"#,
            #"{"type":"ai-title","aiTitle":"Fix login redirect loop"}"#,
        ], "claude/projects/-app/0a1b2c3d-1111-2222-3333-444455556666.jsonl")
        write([
            #"{"type":"session_meta","payload":{"id":"5f0e7d2a-0000-4000-8000-00000000c0de","cwd":"\#(folder)"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add rate limiting to the public API, 100 requests a minute per key."}]}}"#,
        ], "codex/sessions/2026/11/07/rollout-2026-11-07T14-47-17-5f0e7d2a-0000-4000-8000-00000000c0de.jsonl")
        write([#"{"type":"user","content":[{"type":"text","text":"<user_query>Write release notes for 1.1.7</user_query>"}]}"#],
              "grok/sessions/%2Fapp/9e15f9e2-4237-48b4-a981-884be6aa7e62/chat_history.jsonl")
        return [
            ConversationRoot(agent: .claude, url: dir.appendingPathComponent("claude/projects"), account: nil),
            ConversationRoot(agent: .codex, url: dir.appendingPathComponent("codex/sessions"), account: nil),
            ConversationRoot(agent: .grok, url: dir.appendingPathComponent("grok/sessions"), account: nil),
        ]
    }
}
#endif
