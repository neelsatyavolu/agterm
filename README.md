# agterm

A small macOS terminal for running AI coding agents. It works like Terminal.app, but each tab shows what the agent in it is doing.

Each tab has two lines:

```
● Fix login redirect loop
  WORKING  agmux  main                  +75 −12
```

- **Topic.** Claude Code names the task in the terminal title; agterm shows it. Other programs show their name.
- **Status.** `WORKING` while the agent runs, `DONE` when it finished while you were in another tab, `NEEDS YOU` when it rang the bell (usually a permission prompt), `EXITED` when the shell ended.
- **Folder, branch and diff.** The folder the tab is in, its git branch, and the uncommitted line count from `git diff HEAD`.

It is a real terminal (the [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) emulator in a native AppKit window), not a wrapper around agent APIs. Nothing is installed into your agents.

## Install

Download the latest `agterm.zip` from [Releases](https://github.com/neelsatyavolu/agterm/releases/latest) or [agterm.xanom.co](https://agterm.xanom.co), unzip it and move `agterm.app` to Applications. It is signed and notarized, and updates itself through [Sparkle](https://sparkle-project.org) (Settings → Updates).

macOS 14 or later.

On first launch agterm asks for Full Disk Access. Programs you run in a terminal get the terminal's permissions, so without it macOS blocks agents from Desktop, Documents, Mail and other apps' data, or keeps asking.

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
| ⌘= ⌘- ⌘0 | Font size |
| ⌘, | Settings: theme, font, background opacity and blur, updates |

Closing a tab or quitting asks first if a program is still running.

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
