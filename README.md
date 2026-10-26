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

Download the latest `agterm.zip` from [Releases](https://github.com/neelsatyavolu/agterm/releases/latest) or [agterm.xanom.co](https://agterm.xanom.co), unzip it and move `agterm.app` to Applications. It is signed and notarized, and updates itself through [Sparkle](https://sparkle-project.org) (Settings → General).

macOS 14 or later.

On first launch agterm asks for Full Disk Access. Programs you run in a terminal get the terminal's permissions, so without it macOS blocks agents from Desktop, Documents, Mail and other apps' data, or keeps asking.

## agmux memory and consult

Claude Code and Codex started in an agterm tab get the two MCP servers [agmux](https://agmux.dev) gives its own agents:

- **agmux-memory**, for folders agmux knows, using agmux's project ids so both apps share one memory.
- **consult**, for second opinions and diff reviews from other agents on your Mac.

agterm puts small `claude`, `codex` and `grok` wrappers first on PATH in its own shells (zsh through `ZDOTDIR`, which still loads your startup files). They add `--mcp-config` for Claude or `-c mcp_servers.…` for Codex, skip servers you already configured, and edit no config files. Start an agent with `AGTERM_MCP=0` to skip them once, or turn them off in Settings → Agents. Needs agmux installed (the servers ship inside agmux.app) and Node on PATH.

## Starting agents and ⌘K

- **About 20 agent CLIs.** Claude Code, Codex, Grok, Gemini CLI, Antigravity, Cursor Agent, OpenCode, Kimi Code, Aider, Amp, Qwen Code, Crush, GitHub Copilot CLI, Factory Droid, Kilo Code, Cline, Goose, Auggie, Qodo, Kiro CLI, Continue and Pi all get tab status, "needs you" and lines changed.
- **New agent tab.** ⌥⌘T opens a tab in the current folder and starts your usual agent (Settings → Agents). ⌥⌘1, ⌥⌘2 and ⌥⌘3 start Claude Code, Codex and Grok; Shell → New Tab With Agent and right-clicking + list every agent you have installed. The agent is typed at the new shell's prompt, so the shell stays when the agent quits and the tab restores like any other.
- **Skip permission prompts.** Settings → Permissions can start each installed agent with its own bypass flag, such as `--dangerously-skip-permissions` (Claude Code, Antigravity), `--dangerously-bypass-approvals-and-sandbox` (Codex, which also turns off its sandbox), `--permission-mode bypassPermissions` (Grok), `--yolo` (Gemini, Kimi, Qwen, Crush), `--force` (Cursor), `--auto` (OpenCode) or `--yes-always` (Aider). Off by default. Runs where you pass a permission flag yourself, and subcommands like `mcp` or `login`, are left alone.
- **⌘K writes a command.** Describe what you want; ⏎ puts the command at your prompt to check, ⌘⏎ runs it. It goes through the CLI you're already signed in to, at its fastest setting: Claude Haiku (about 2.5 s), Codex's Luna model at its lowest effort (about 4 s) or Grok at low effort (about 5 s). Automatic uses the first one installed. The model gets your request, the tab's folder, your shell and the last 20 lines on screen. It has no tools, and the run isn't kept in the CLI's history.

## Switching accounts when an agent runs out

Add more Claude Code or Codex logins in Settings → Accounts. Each one signs in through the CLI's own login, in a tab, into its own folder (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`). Conversations, settings, skills and MCP servers are shared with your own login through symlinks, so any login can resume any conversation.

- **Sees the limit at once.** Claude Code writes a 429 record into the conversation when it stops at a limit, and Codex logs a usage-limit event. agterm follows each agent tab's transcript and reacts within a second, instead of waiting for a usage poll.
- **Picks a login that has room.** It checks every login's usage through its own CLI (Claude Code's `get_usage`, Codex's app-server `account/rateLimits/read`; no Keychain reads, no model calls) and takes the one with the most left.
- **Resumes the same conversation.** It stops the agent, runs `claude --resume <id>` or `codex resume <id>` with your original options on the new login in the same tab, and tells it to continue, so the turn that hit the limit finishes. You get a notification saying which account it moved to.
- **New sessions** start on your own login while it has usage, and on the login with the most left while it doesn't. At most 3 switches per tab in 30 minutes, so two empty logins can't loop.
- **Team accounts.** If you're signed in to agmux Teams and your team shares Codex logins there, agterm borrows one once every Codex login of yours is out, for a running session or a new one. It works like agmux: the login is lent to one tab at a time, renewed every minute with the tokens Codex refreshed, and handed back (tokens included) as soon as Codex exits, or when you quit. A login that runs out is reported to the team so nobody else gets it, and the tab moves to another. The borrowed copy lives only in its own folder and is deleted on return. Settings → Accounts lists the team's logins with their usage and who is using them. Your team adds and manages them in agmux. Claude logins can't be shared, as in agmux.

Grok isn't supported yet.

## agmux Teams and the phone app

- **Teams.** Settings → Teams & Phone links agterm as its own device (a browser sign-in, like agmux) and reports hourly totals for Claude Code and Codex sessions started in agterm: tokens, estimated cost, active time, turns, tool calls by kind, and lines changed as counts. Never prompts, replies, code, diffs, paths or terminal output, and never sessions started elsewhere. Codex sessions are marked with `originator: agterm`; Claude sessions are the ones agterm saw in its tabs. The counting is a port of agmux's own, with its tests.
- **Phone.** agterm Remote, agterm's own iPhone app ([`Mobile/`](Mobile/README.md); on TestFlight for now), pairs from Settings → Teams & Phone with a QR code. Your tabs show up as agterm draws them; open one to see its live screen in your theme's colors, answer an agent's prompt with a tap, type a reply, press keys a phone keyboard lacks (Esc, arrows, Tab, ^C) or stop it. Claude Code and Codex tabs also read as a conversation. The + button opens a new tab on the Mac running any agent you have installed, in one of your folders. "Needs you" and "finished" arrive as notifications while the app is closed. The agmux phone app still works with agterm too, but keeps one paired Mac, so pairing agterm replaces agmux on that phone. Traffic goes through the agmux relay over TLS.

## Tabs come back

Quit with tabs open and the next launch reopens them: folder, history with colors, and the selected tab. A tab that was running Claude Code or Codex types `claude --resume <its session>` or `codex resume <its session>` with the original flags, so you're back in the same conversation. Other agents come back on their latest conversation in that folder, with each CLI's own option (`grok --continue`, `gemini --resume latest`, `opencode --continue`, and so on for Antigravity, Cursor, Kimi, Aider, Droid, Kilo, Auggie, Pi, Copilot and Goose). Other programs aren't rerun. Saved state lives in `~/Library/Application Support/co.xanom.agterm/workspace.json`, readable only by you.

## How status works

agterm reads signals the terminal already has, so it needs no hooks or plugins:

| Signal | Source |
|---|---|
| Working / idle | Claude Code's title prefix: `◐`/`◑` while working, `✳` when idle (braille spinners also count). Programs without one count as working while they print output that isn't an echo of your typing. |
| Needs you | An agent's permission prompt on screen (a numbered choice under a `❯` or `›` cursor, as Claude Code and Codex draw them), in any tab including the one you're looking at; or the bell, while the tab is in the background |
| Folder | The foreground process's working directory (`proc_pidinfo`) |
| Diff | `git status --porcelain -b` and `git diff HEAD --shortstat`, every 3 seconds, off the main thread |

## Shortcuts

| Keys | Action |
|---|---|
| ⌘T / ⌘W | New tab (in the current tab's folder) / close tab |
| ⌥⌘T, ⌥⌘1–3 | New tab running your usual agent, or Claude Code, Codex, Grok |
| ⌘K | Describe a command and have a fast model write it |
| ⌘1–⌘9, ⌘⇧[ ⌘⇧], ⌃Tab | Switch tabs |
| Drag a tab, ⌘⇧← ⌘⇧→ | Reorder tabs |
| ⌘= ⌘- ⌘0 | Font size |
| ⌘, | Settings: General, Appearance, Agents, Permissions, Accounts, Command (⌘K), Teams & Phone |
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
