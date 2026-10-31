import Foundation

/// What Move to Cloud copies for a tab (docs/cloud-sessions-plan.md). Paths are the same on the
/// cloud machine, so transcripts and saved folders keep working there unchanged.
public enum CloudMovePlan {
    /// Rebuildable, OS-specific folders: Mac builds of them don't run on Linux anyway.
    public static let excluded = ["node_modules", ".build", "target", ".venv", "DerivedData", ".next", ".turbo", ".nuxt", ".svelte-kit", "__pycache__"]

    /// Your agent setup that goes with the agents; never their logins or settings files, which
    /// hold machine paths and sometimes keys.
    public static func userConfig(home: String) -> [String] {
        [".claude/CLAUDE.md", ".claude/skills", ".claude/agents", ".claude/commands", ".codex/AGENTS.md"]
            .map { home + "/" + $0 }
    }

    /// The folder to copy for a tab: its git repository, else the folder an agent runs in.
    /// Never your whole home folder or anything above it, as written or once `resolve` (realpath)
    /// has followed links: a home reached through a link must not be copied with its keys.
    /// Nil for a plain shell outside a repo.
    public static func folder(cwd: String, gitRoot: String?, hasAgent: Bool, home: String,
                              resolve: (String) -> String = { $0 }) -> String? {
        guard let candidate = gitRoot ?? (hasAgent ? cwd : nil) else { return nil }
        let folder = standardized(candidate)
        for (path, home) in [(folder, standardized(home)), (standardized(resolve(folder)), standardized(resolve(home)))] {
            guard path != "/", path != home, !(home + "/").hasPrefix(path + "/") else { return nil }
        }
        return folder
    }

    /// Each folder once, leaving out any inside another (one rsync covers both).
    public static func roots(_ folders: [String]) -> [String] {
        let unique = Array(Set(folders.map(standardized))).sorted()
        return unique.filter { folder in !unique.contains { $0 != folder && folder.hasPrefix($0 + "/") } }
    }

    /// Claude Code keeps a conversation as `<id>.jsonl` plus a `<id>/` folder in its project's
    /// folder under ~/.claude/projects; `projects` lists those folders' names.
    public static func claudeProject(sessionID: String, home: String, projects: [String],
                                     exists: (String) -> Bool) -> String? {
        let base = home + "/.claude/projects/"
        return projects.sorted().map { base + $0 }.first { exists($0 + "/" + sessionID + ".jsonl") }
    }

    /// What git ignores in a repo, as rsync rules anchored to the repo: build output, caches and
    /// agent worktrees stay behind, wherever the project puts them. `ignored` is the output of
    /// `git ls-files -o -i --exclude-standard --directory -z` run in the repo (folders end in "/").
    /// Ignored `.env` files and keys stay on the Mac too, as with Claude Code's cloud sessions.
    public static func ignoreRules(gitIgnored ignored: String) -> [String] {
        ignored.split(separator: "\0").map(String.init).filter { !$0.isEmpty }.map { "/" + escaped($0) }
    }

    /// A name rsync takes literally: `*`, `?`, `[` and `\` are pattern characters to it.
    private static func escaped(_ path: String) -> String {
        path.reduce(into: "") { out, c in
            if "*?[\\".contains(c) { out.append("\\") }
            out.append(c)
        }
    }

    /// Drops empty, `.` and `..` parts. Unlike `standardizingPath` it never looks at the disk,
    /// which would turn /private/tmp into /tmp on a Mac: the cloud machine must get the same path.
    private static func standardized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }
}
