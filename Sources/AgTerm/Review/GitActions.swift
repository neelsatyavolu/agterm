import AgTermCore
import Foundation

/// What a repository looks like when you open Commit: enough to word the sheet and draft a message.
struct CommitContext {
    let root: String
    let upstream: UpstreamState
    /// The branch pull requests go into, without the remote (`main`).
    let defaultBranch: String?
    /// `git status --short` lines, for the sheet's file list.
    let changes: [String]
    let stat: String
    let patch: String
    let recentSubjects: [String]
    let pullRequest: PullRequest?

    var branch: String? { upstream.branch }
    var onDefaultBranch: Bool { branch == nil || branch == defaultBranch }
}

/// Commit, push and open a pull request, in that order, each step only if asked for.
struct PublishSteps: OptionSet {
    let rawValue: Int
    static let commit = PublishSteps(rawValue: 1)
    static let push = PublishSteps(rawValue: 2)
    static let pullRequest = PublishSteps(rawValue: 4)
}

struct PublishOutcome {
    var commit: String?
    var createdBranch: String?
    var pullRequest: PullRequest?
}

/// Runs the git and gh steps. Every function blocks; call them on `GitRunner.writes`.
enum GitActions {
    static func context(cwd: String) -> Result<CommitContext, GitFailure> {
        let top = GitRunner.git(["rev-parse", "--show-toplevel"], in: cwd)
        guard top.ok else { return .failure("This folder isn't in a git repository.") }
        let root = top.trimmed
        let status = GitRunner.git(["status", "--porcelain", "-b", "-uall"], in: root)
        guard status.ok else { return .failure(status.failure) }
        let lines = status.out.split(separator: "\n").map(String.init)
        let header = lines.first { $0.hasPrefix("## ") } ?? ""
        let head = GitRunner.git(["rev-parse", "--verify", "-q", "HEAD"], in: root).ok ? "HEAD" : "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        let untracked = lines.filter { $0.hasPrefix("?? ") }.map { " " + $0.dropFirst(3) + " (new file)" }
        let stat = GitRunner.git(["diff", head, "--stat=100"], in: root).out + untracked.joined(separator: "\n")
        let patch = GitRunner.git(["diff", head, "--no-color", "--no-ext-diff"], in: root).out
        let subjects = GitRunner.git(["log", "-8", "--format=%s"], in: root).out.split(separator: "\n").map(String.init)
        let pr = GitRunner.ghPath == nil ? nil : pullRequest(root)
        return .success(CommitContext(root: root, upstream: GitPublish.upstream(statusHeader: header),
                                      defaultBranch: defaultBranch(root), changes: lines.filter { !$0.hasPrefix("## ") },
                                      stat: stat, patch: patch, recentSubjects: subjects, pullRequest: pr))
    }

    /// The open pull request for the checked-out branch, if any.
    static func pullRequest(_ dir: String) -> PullRequest? {
        let out = GitRunner.gh(["pr", "view", "--json", "number,url,state"], in: dir, timeout: 20)
        return out.ok ? GitPublish.pullRequest(json: Data(out.out.utf8)) : nil
    }

    static func defaultBranch(_ root: String) -> String? {
        let originHead = GitRunner.git(["symbolic-ref", "-q", "refs/remotes/origin/HEAD"], in: root)
        let locals = GitRunner.git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: root).out
            .split(separator: "\n").map(String.init)
        guard let ref = GitDiff.defaultBranch(originHead: originHead.ok ? originHead.out : nil, localBranches: locals) else { return nil }
        return ref.hasPrefix("origin/") ? String(ref.dropFirst(7)) : ref
    }

    /// Runs `steps` against the repository as it is now, not as it was when the sheet opened, so a
    /// retry after a failed push or hook picks up where the last attempt stopped. `branches` are
    /// the branches this sheet may work on (the one it opened on, plus any it made); if another tab
    /// switched the checkout elsewhere, nothing runs. `progress` is called on the main queue.
    static func publish(_ steps: PublishSteps, message: String, context: CommitContext, branches: Set<String>,
                        onBranch: @escaping (String) -> Void = { _ in },
                        progress: @escaping (String) -> Void) -> Result<PublishOutcome, GitFailure> {
        func say(_ text: String) { DispatchQueue.main.async { progress(text) } }
        let root = context.root
        var outcome = PublishOutcome()
        let live = GitRunner.git(["rev-parse", "--abbrev-ref", "HEAD"], in: root).trimmed
        guard !live.isEmpty, live != "HEAD" else { return .failure("No branch is checked out, so there's nothing to commit to.") }
        guard branches.contains(live) else {
            return .failure(GitFailure("The checkout moved to \(live) since this opened. Close this and open Commit again."))
        }
        var branch = live
        let openPR = context.pullRequest?.isOpen == true && live == context.branch

        // A pull request needs a branch of its own; the default branch stays where it was.
        if steps.contains(.pullRequest), live == context.defaultBranch, !openPR {
            let subject = message.split(separator: "\n").first.map(String.init) ?? "changes"
            let name = uniqueBranch(GitPublish.branchName(forSubject: steps.contains(.commit) ? subject : context.recentSubjects.first ?? subject), root)
            say("Making branch \(name)…")
            let switched = GitRunner.git(["switch", "-c", name], in: root)
            guard switched.ok else { return .failure(switched.failure) }
            if let base = context.defaultBranch { _ = GitRunner.git(["config", "branch.\(name).agterm-base", base], in: root) }
            outcome.createdBranch = name
            branch = name
            DispatchQueue.main.async { onBranch(name) }
        }

        if steps.contains(.commit) {
            say("Committing…")
            if let failure = commit(message, root: root) {
                // Put things back as they were: the new branch has no commits of its own yet.
                if let made = outcome.createdBranch, GitRunner.git(["switch", live], in: root).ok {
                    _ = GitRunner.git(["branch", "-D", made], in: root)
                }
                return .failure(failure)
            }
            outcome.commit = GitRunner.git(["rev-parse", "--short", "HEAD"], in: root).trimmed
        }

        if steps.contains(.push) {
            say("Pushing \(branch)…")
            let remotes = GitRunner.git(["remote"], in: root).out.split(separator: "\n").map(String.init)
            guard let remote = remotes.contains("origin") ? "origin" : remotes.first else {
                return .failure("This repository has no remote to push to.")
            }
            // Always this branch by name, whatever push.default says.
            let pushed = GitRunner.git(["push", "-u", remote, "\(branch):\(branch)"], in: root, timeout: 180)
            guard pushed.ok else { return .failure(pushed.failure) }
        }

        if steps.contains(.pullRequest) {
            if let existing = pullRequest(root), existing.isOpen {
                outcome.pullRequest = existing
                return .success(outcome)
            }
            say("Writing the pull request…")
            let base = GitRunner.git(["config", "--get", "branch.\(branch).agterm-base"], in: root).trimmed
            let target = base.isEmpty ? context.defaultBranch ?? "main" : base
            let text = pullRequestText(root: root, base: target)
            say("Opening the pull request…")
            let created = GitRunner.gh(["pr", "create", "--title", text.title, "--body", text.body, "--base", target, "--head", branch],
                                       in: root, timeout: 90)
            guard created.ok else { return .failure(created.failure) }
            outcome.pullRequest = pullRequest(root)
                ?? created.trimmed.split(separator: "\n").last.flatMap { url in
                    Int(url.split(separator: "/").last ?? "").map { PullRequest(number: $0, url: String(url), state: "OPEN") }
                }
        }
        return .success(outcome)
    }

    /// Stages everything and commits; nil on success. Nothing left to commit (an earlier attempt
    /// already did) counts as done.
    private static func commit(_ message: String, root: String) -> GitFailure? {
        let added = GitRunner.git(["add", "-A"], in: root)
        guard added.ok else { return added.failure }
        if GitRunner.git(["diff", "--cached", "--quiet"], in: root).ok { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agterm-commit-\(UUID().uuidString).txt")
        do { try message.write(to: file, atomically: true, encoding: .utf8) } catch { return GitFailure(error.localizedDescription) }
        defer { try? FileManager.default.removeItem(at: file) }
        // Hooks can take a while (lint, tests); give them time.
        let committed = GitRunner.git(["commit", "-F", file.path], in: root, timeout: 300)
        return committed.ok ? nil : committed.failure
    }

    /// A title and body from the fast model, or from the commit subjects if it isn't available.
    private static func pullRequestText(root: String, base: String) -> (title: String, body: String) {
        let ref = GitRunner.git(["rev-parse", "--verify", "-q", "origin/\(base)"], in: root).ok ? "origin/\(base)" : base
        let commits = GitRunner.git(["log", "--format=%s", "\(ref)..HEAD"], in: root).out.split(separator: "\n").map(String.init)
        let stat = GitRunner.git(["diff", "--stat=100", "\(ref)...HEAD"], in: root).out
        let patch = GitRunner.git(["diff", "--no-color", "--no-ext-diff", "\(ref)...HEAD"], in: root).out
        let fallback = (title: commits.last ?? "Changes", body: "## Summary\n" + commits.reversed().map { "- " + $0 }.joined(separator: "\n"))
        let done = DispatchSemaphore(value: 0)
        var reply: String?
        QuickCommandRunner.shared.ask(system: GitPublish.pullRequestInstructions,
                                      message: GitPublish.pullRequestRequest(commits: commits, stat: stat, patch: patch)) { result in
            reply = try? result.get()
            done.signal()
        }
        done.wait()
        guard let reply, let parsed = GitPublish.parsePullRequest(reply), !parsed.title.isEmpty else { return fallback }
        return parsed
    }

    private static func uniqueBranch(_ name: String, _ root: String) -> String {
        var candidate = name, n = 2
        while GitRunner.git(["rev-parse", "--verify", "-q", "refs/heads/\(candidate)"], in: root).ok {
            candidate = "\(name)-\(n)"
            n += 1
        }
        return candidate
    }
}
