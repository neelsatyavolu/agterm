# agterm

A small macOS terminal for running AI coding agents. It works like Terminal.app, but each tab shows what the agent in it is doing.

Each tab has two lines:

```
● Fix login redirect loop
  WORKING  agmux  main                  +75 −12
```

- **Topic.** Claude Code names the task in the terminal title; agterm shows it. Other programs show their name.
- **Status.** `WORKING` while the agent runs, `DONE` when it finished while you were in another tab, `NEEDS YOU` when it rang the bell (usually a permission prompt), `EXITED` when the shell ended.
- **Folder, diff and branch.** For an agent tab, the lines it changed since it started (from a `git stash create` snapshot taken at launch, plus files it created). For other tabs, the folder's uncommitted changes.

It is a real terminal (the [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) emulator in a native AppKit window), not a wrapper around agent APIs. Nothing is installed into your agents.

## Install

Download the latest `agterm.zip` from [Releases](https://github.com/neelsatyavolu/agterm/releases/latest) or [agterm.xanom.co](https://agterm.xanom.co), unzip it and move `agterm.app` to Applications. It is signed and notarized, and updates itself through [Sparkle](https://sparkle-project.org) (Settings → Updates).

macOS 14 or later.

On first launch agterm asks for Full Disk Access. Programs you run in a terminal get the terminal's permissions, so without it macOS blocks agents from Desktop, Documents, Mail and other apps' data, or keeps asking.

## agmux memory and consult

Claude Code and Codex started in an agterm tab get the two MCP servers [agmux](https://agmux.dev) gives its own agents:

- **agmux-memory**, for folders agmux knows, using agmux's project ids so both apps share one memory.
- **consult**, for second opinions and diff reviews from other agents on your Mac.

agterm puts small `claude` and `codex` wrappers first on PATH in its own shells (zsh through `ZDOTDIR`, which still loads your startup files). They add `--mcp-config` for Claude or `-c mcp_servers.…` for Codex, skip servers you already configured, and edit no config files. Start an agent with `AGTERM_MCP=0` to skip them once, or turn them off in Settings → Agents. Needs agmux installed (the servers ship inside agmux.app) and Node on PATH.

## Tabs come back

Quit with tabs open and the next launch reopens them: folder, history with colors, and the selected tab. A tab that was running Claude Code types `claude --resume <its session>` with the original flags, so you're back in the same conversation. Other programs aren't rerun. Saved state lives in `~/Library/Application Support/co.xanom.agterm/workspace.json`, readable only by you.

## How status works

agterm reads signals the terminal already has, so it needs no hooks or plugins:

| Signal | Source |
|---|---|
| Working / idle | Claude Code's title prefix: `◐`/`◑` while working, `✳` when idle (braille spinners also count). Programs without one count as working while they print output that isn't an echo of your typing. |
| Needs you | The bell character, while the tab is in the background |
| Folder | The foreground process's working directory (`proc_pidinfo`) |
| Diff | `git status --porcelain -b` and `git diff HEAD --shortstat`, every 3 seconds, off the main thread |

## Shortcuts

| Keys | Action |
|---|---|
| ⌘T / ⌘W | New tab (in the current tab's folder) / close tab |
| ⌘1–⌘9, ⌘⇧[ ⌘⇧], ⌃Tab | Switch tabs |
| Drag a tab, ⌘⇧← ⌘⇧→ | Reorder tabs |
| ⌘= ⌘- ⌘0 | Font size |
| ⌘, | Settings: theme, font, opacity and blur, notifications, agents, updates |
| Drag onto a tab | Files and folders type their escaped paths, as in Terminal.app. Images from a browser or screenshot tool are saved to a temp file first, so Claude Code can attach them. |

Closing a tab or quitting asks first if a program is still running. When an agent finishes or needs you in a tab you aren't looking at, agterm can post a notification and play a sound; clicking it opens that tab.

A see-through background blurs what's behind it, more strongly the more transparent it is, so text in other windows doesn't show through sharp. Full screen is always solid.

## Build from source

Needs Xcode 16 or later (Swift 6) and the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`).

```sh
swift test               # unit tests for the status, title, git and settings logic
./install.sh --adhoc     # build, sign ad hoc and install to /Applications
```

`swift run AgTerm` also works for quick checks. `AGTERM_SELFTEST=<dir> .build/debug/AgTerm` renders the window off screen into PNGs and checks that closed tabs leave no processes behind.

Maintainers: `./install.sh` and `scripts/release.sh` sign with a Developer ID certificate and notarize; copy `scripts/maintainer.local.example` to `scripts/maintainer.local` first.

## License

[MIT](LICENSE)
