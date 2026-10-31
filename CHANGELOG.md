# Changelog

## 1.1.0-beta.7 — 2026-10-31
- Added: In Settings → Accounts, Use for New Sessions in an account's ⋯ menu makes new Claude Code, Codex or Grok sessions start on that account instead of your own login. Tabs already running stay where they are, and automatic switching still moves off it when it runs out.

## 1.1.0-beta.6 — 2026-10-30
- Added: A tab moved to the cloud installs its project's dependencies there before the agent continues (npm, pnpm, yarn, bun, or pip with requirements.txt), and skips that on later moves until the lockfile changes. A repo can give its own steps in .agterm/cloud-setup.sh.
- Added: Moving more than 1 GB to the cloud asks first, with how long the copy will take, before any agent stops.
- Changed: If a repo changes on this Mac while its tab is in the cloud, Bring Back keeps this Mac's files and saves the cloud's changes as a patch in the repo's .git folder, with a notification saying where, instead of mixing the two.

## 1.1.0-beta.5 — 2026-10-30
- Changed: Move to Cloud copies only what git keeps track of, plus new files git doesn't ignore. Build output, caches and anything else your .gitignore lists stay on this Mac, so a repo with gigabytes of build files moves in seconds. Ignored .env files stay here too, and Bring Back leaves the cloud's own build files behind.

## 1.1.0-beta.4 — 2026-10-30
- Fixed: Installing an update while agents are working no longer asks whether to move them to the cloud; they keep running through the relaunch.

## 1.1.0-beta.3 — 2026-10-30
- Added: A tab moving to or from the cloud says so on the tab, with a bar showing how much of its folder has been copied.
- Changed: Move to Cloud copies much faster, and leaves out build caches (.next, .turbo, .nuxt, .svelte-kit, __pycache__) as well as node_modules.
- Fixed: Moving a tab no longer stops partway through when the copy finishes reading its input.
- Fixed: In Settings → Cloud, the hours limit field no longer has a squeezed "hours" label beside it.

## 1.1.0-beta.2 — 2026-10-30
- Added: Right-click a tab and choose Move to Cloud to move just that tab, or Bring Back from Cloud to bring it home. Tabs in the cloud show a cloud next to their folder.
- Fixed: Opening agterm from inside one of its tabs no longer stops Claude from saving conversations, and tab status no longer flips between working and done afterwards.

## 1.1.0-beta.1 — 2026-10-30
- Added: agterm Cloud (beta). The cloud button beside + moves every tab to a cloud machine, so agents keep working while this Mac is off, and brings them back when you return. Set it up in Settings → Cloud ($12 a month for 100 hours).
- Added: Beta updates. Paste a beta key in Settings → General → Updates and agterm installs beta builds as well as stable releases, whichever is newer. Leave Beta goes back to stable releases.
- Fixed: A Grok tab no longer flips back to working after Grok finishes, such as when Grok names the conversation a few seconds later or while you type your next message. Its title also drops the trailing "- grok".
- Fixed: Dropping a dragged tab leaves it where you dropped it, instead of the tabs appearing to swap a second time.
- Fixed: While you drag a tab, the tabs it passes over no longer light up as if the mouse were over them.

## 1.0.9 — 2026-10-30
- Fixed: Grok tabs show only the conversation's topic, without Grok's status ("- Thinking -", "- Waiting for response... -") in front of it.

## 1.0.8 — 2026-10-29
- Added: Right-click a tab (or Control-click it) to rename it, open a new tab in its folder, copy the folder's path, show the folder in Finder, or close the tab. Shell → Rename Tab… renames the current tab.
- Added: A renamed tab keeps its name after agterm quits and reopens. Clear the name to go back to the program's own title.

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
