#if DEBUG
import AgTermCore
import AppKit

extension SelfTest {
    /// The review toolbar, changes panel, commit sheet and worktrees:
    /// `AGTERM_REVIEW_CHECK=1 AGTERM_SELFTEST=<dir>`. Makes a throwaway repo with an edit, a new
    /// file and an ignored `.env`, opens the panel with tabs on top (`review-top-ink.png`) and on
    /// the left in both themes (`review-side-ink.png`, `review-side-paper.png`), shows the commit
    /// sheet (`review-commit.png`), commits, then makes and removes a worktree.
    static func reviewCheck(_ controller: MainWindowController, outDir: String) {
        guard let window = controller.window, let repo = makeRepo(outDir) else { exit(1) }
        CommitSheet.draftsMessages = false
        let wasLeft = controller.tabsOnLeft
        let wasOpen = controller.review.panelOpen
        UserDefaults.standard.set(false, forKey: MainWindowController.tabsOnLeftKey)
        controller.applyTabPlacement()
        if controller.review.panelOpen { controller.toggleChanges() }
        window.setContentSize(NSSize(width: 1280, height: 720))
        let tab = controller.addTab(cwd: repo, restoring: nil)
        controller.showWindow(nil)
        var failed = false
        func report(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("selftest: review: \(name):", ok ? "ok" : "FAIL", detail)
            if !ok { failed = true }
        }
        func finish() {
            if controller.review.panelOpen != wasOpen { controller.toggleChanges() }
            UserDefaults.standard.set(wasLeft, forKey: MainWindowController.tabsOnLeftKey)
            controller.applyTabPlacement()
            exit(failed ? 1 : 0)
        }
        controller.refreshGit(repo)
        after(2.0) {
            let state = controller.reviewToolbar.state
            report("toolbar sees the repo", state.isRepo && state.changedFiles == 2, "\(state)")
            report("commit enabled", controller.reviewToolbar.commit.isEnabled)
            report("hand off needs an agent", !controller.reviewToolbar.handOff.isEnabled)
            report("toolbar clear of the tabs", controller.tabBar.trailingReserve > controller.reviewToolbar.frame.width)
            let before = tab.view.frame.width
            controller.toggleChanges()
            after(1.5) {
                report("panel open", !controller.diffPanel.isHidden && controller.diffPanel.frame.width >= DiffPanelView.minWidth)
                report("terminal narrower", tab.view.frame.width < before, "\(before) → \(tab.view.frame.width)")
                report("lists the edit and the new file, not .env", controller.diffPanel.fileCountForTest == 2,
                       controller.diffPanel.summaryForTest)
                snapshot(window, "\(outDir)/review-top-ink.png")
                controller.toggleTabsOnLeft()
                after(0.8) {
                    report("toolbar in the title strip", controller.reviewToolbar.frame.midY > controller.container.frame.maxY)
                    snapshot(window, "\(outDir)/review-side-ink.png")
                    let theme = Preferences.shared.appearance.themeID
                    Preferences.shared.update { $0.themeID = "paper" }
                    after(0.5) {
                        snapshot(window, "\(outDir)/review-side-paper.png")
                        Preferences.shared.update { $0.themeID = theme }
                        commitAndWorktree(controller, repo: repo, outDir: outDir, report: report, done: finish)
                    }
                }
            }
        }
    }

    private static func commitAndWorktree(_ controller: MainWindowController, repo: String, outDir: String,
                                          report: @escaping (String, Bool, String) -> Void, done: @escaping () -> Void) {
        GitRunner.reads.async {
            guard case let .success(context) = GitActions.context(cwd: repo) else {
                DispatchQueue.main.async { report("commit context", false, ""); done() }
                return
            }
            DispatchQueue.main.async {
                let sheet = CommitSheet(context: context)
                if let window = controller.window { sheet.begin(for: window) }
                after(0.6) {
                if let panel = sheet.window { snapshot(panel, "\(outDir)/review-commit.png") }
                report("commit sheet offers all three", sheet.buttonTitlesForTest == ["Commit", "Commit & Push", "Commit, Push & Open PR"],
                       sheet.buttonTitlesForTest.joined(separator: ", "))
                sheet.close()
                GitRunner.writes.async {
                    let committed = GitActions.publish([.commit], message: "test: commit from the self-test", context: context,
                                                           branches: ["main"]) { _ in }
                    let subject = GitRunner.git(["log", "-1", "--format=%s"], in: repo).trimmed
                    let retry = retryCheck(repo: repo, outDir: outDir)
                    let moved = movedBranchCheck(repo: repo)
                    let made = WorktreeActions.create(cwd: repo, branch: "agterm/selftest")
                    var worktreeOK = false, envCopied = false, baseRecorded = false, removed = false
                    if case let .success(tree) = made {
                        worktreeOK = FileManager.default.fileExists(atPath: tree.path + "/README.md")
                        envCopied = FileManager.default.fileExists(atPath: tree.path + "/.env")
                        baseRecorded = GitRunner.git(["config", "--get", "branch.agterm/selftest.agterm-base"], in: repo).trimmed == "main"
                        if let removal = WorktreeActions.removal(tree.path) {
                            removed = (try? WorktreeActions.remove(removal, deleteBranch: true).get()) != nil
                                && !FileManager.default.fileExists(atPath: tree.path)
                        }
                    }
                    DispatchQueue.main.async {
                        report("commit", (try? committed.get()) != nil && subject == "test: commit from the self-test", subject)
                        report("push retried after a failure, without a second commit", retry.ok, retry.detail)
                        report("refuses when the checkout moved", moved, "")
                        report("worktree made", worktreeOK, "\(made)")
                        report("worktree has .env", envCopied, "")
                        report("worktree remembers its base", baseRecorded, "")
                        report("worktree removed", removed, "")
                        done()
                    }
                }
                }
            }
        }
    }

    /// Commit & Push to a remote that isn't there yet fails at the push; once it exists, the same
    /// request pushes without committing again. Call off the main thread.
    private static func retryCheck(repo: String, outDir: String) -> (ok: Bool, detail: String) {
        let remote = outDir + "/review-remote.git"
        try? FileManager.default.removeItem(atPath: remote)
        _ = GitRunner.git(["remote", "add", "origin", remote], in: repo)
        FileManager.default.createFile(atPath: repo + "/retry.txt", contents: Data("retry\n".utf8))
        guard case let .success(context) = GitActions.context(cwd: repo) else { return (false, "no context") }
        let count = { Int(GitRunner.git(["rev-list", "--count", "HEAD"], in: repo).trimmed) ?? -1 }
        let before = count()
        let first = GitActions.publish([.commit, .push], message: "test: retry", context: context, branches: ["main"]) { _ in }
        guard case .failure = first else { return (false, "first push should fail") }
        _ = GitRunner.git(["init", "-q", "--bare", remote], in: outDir)
        let second = GitActions.publish([.commit, .push], message: "test: retry", context: context, branches: ["main"]) { _ in }
        let pushed = GitRunner.git(["rev-parse", "main"], in: remote).trimmed == GitRunner.git(["rev-parse", "HEAD"], in: repo).trimmed
        let ok = (try? second.get()) != nil && count() == before + 1 && pushed
        return (ok, "commits \(before) → \(count()), pushed \(pushed), \(second)")
    }

    /// Steps don't run on a branch the sheet didn't open on.
    private static func movedBranchCheck(repo: String) -> Bool {
        guard case let .success(context) = GitActions.context(cwd: repo),
              GitRunner.git(["switch", "-q", "-c", "elsewhere"], in: repo).ok else { return false }
        defer { _ = GitRunner.git(["switch", "-q", "main"], in: repo) }
        guard case .failure = GitActions.publish([.push], message: "", context: context, branches: ["main"], progress: { _ in }) else { return false }
        return true
    }

    /// A repo with one commit, then an edit, a new file and an ignored .env.
    private static func makeRepo(_ outDir: String) -> String? {
        let repo = outDir + "/review-repo"
        try? FileManager.default.removeItem(atPath: repo)
        try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        let fm = FileManager.default
        func write(_ name: String, _ text: String) { fm.createFile(atPath: repo + "/" + name, contents: Data(text.utf8)) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "selftest@agterm"], ["config", "user.name", "agterm"]] {
            guard GitRunner.git(args, in: repo).ok else { return nil }
        }
        write("README.md", "# Demo\n\nOne\nTwo\nThree\n")
        write(".gitignore", ".env\n")
        guard GitRunner.git(["add", "-A"], in: repo).ok, GitRunner.git(["commit", "-qm", "first"], in: repo).ok else { return nil }
        write("README.md", "# Demo\n\nOne\nTwo, changed\nThree\nFour\n")
        write("notes.txt", "a new file\nwith two lines\n")
        write(".env", "SECRET=1\n")
        // Worktrees made by the check go under the real ~/.agterm/worktrees; start clean.
        _ = GitRunner.git(["worktree", "prune"], in: repo)
        return (repo as NSString).resolvingSymlinksInPath
    }
}
#endif
