# Changelog

## 1.0.7 — 2026-10-26
- Fixed: Force quitting a browser or other app that an agent opened from a tab no longer ends every tab's shell. Force quitting agterm itself leaves them running too. Tabs already open keep the old behavior until you choose agterm → Quit and End Sessions.

## 1.0.6 — 2026-10-26
- Fixed: A tab shows "needs you" when Claude Code asks you a question with choices (such as a list of questions to answer), instead of "done" or no status.
- Fixed: The tab bar stays visible when the window is in full screen.

## 1.0.5 — 2026-10-26
- Added: agmux Teams cost estimates price GPT-6.1 Terra at OpenAI's list rates.

## 1.0.4 — 2026-10-26
- Fixed: Text stays readable in light themes such as Paper when a program colors it for a dark background. Claude Code's default theme wrote white and pale gray text that was hard to see.
- Added: Programs that follow the terminal's light or dark mode, like Claude Code with its theme set to Auto (`/theme`), switch along with agterm's theme.
- Added: Grok accounts in Settings → Accounts, with their weekly usage and automatic switching. While Grok runs, agterm checks its usage every minute; when the account runs out, the same conversation continues on the account with the most left.
- Added: Grok logins shared in agmux Teams are borrowed once all of yours are out, like Codex ones.
- Added: Team owners and managers can add Codex and Grok accounts to their agmux Teams pool from Settings → Accounts → Add Team Account….

## 1.0.3 — 2026-10-26
- Changed: ⌘K sends the model the tab's last 150 lines, scrollback included, so requests like "fix that error" or "run that again" work on commands that have scrolled off the screen.
- Fixed: The cd folder list also shows up for names of several words, like `cd show resources` for a folder named Show Resources.

## 1.0.2 — 2026-10-26
- Added: Tabs keep running when agterm quits (⌘Q), updates or crashes, and come back live next time. Closing the window ends its tabs, and agterm → Quit and End Sessions ends them all and quits. Tabs stay running through updates from this version on; this update still restarts them.
- Added: After an update, a new tab shows what changed since your last version; agterm → What's New… shows every release.
- Added: The New Agent Tab shortcut can be changed in Settings → Agents.
- Fixed: The Settings toolbar now fits all seven panes.
- Fixed: Picking a theme such as Paper applies right away.
- Fixed: The cd folder list shows Tab to pick and takes clicks.
- Fixed: ⌘K opens under the line you're typing on and no longer shrinks the window.
- Fixed: Tabs restored after a quit keep their emoji and the spacing of text drawn with gaps.

## 1.0.1 — 2026-10-25
- Added: Memory and consult work without agmux installed.

## 1.0.0 — 2026-10-25
- Added: agterm Remote, an iPhone app made for agterm.
- Added: Folder suggestions while you type cd.
- Fixed: Claude tabs get their name from the transcript when the session started with a slash command.
- Changed: Faster bulk output, and one notification when a command with pauses finishes.

## 0.6.0 — 2026-10-25
- Added: Borrow Codex logins from agmux Teams when yours are out.
- Added: Codex and other agent CLIs are restored on relaunch.
- Fixed: Tabs drag without moving the window.

## 0.5.0 — 2026-10-25
- Added: Automatic account switching for Claude Code and Codex.
- Added: Status shows when Claude is busy.

## 0.4.0 — 2026-10-25
- Added: Settings panes, agent quick launch, permission bypass, and a ⌘K command bar.
- Added: Quick launch for 20 agent CLIs.
- Added: On-screen permission prompts.
