# Changelog

## 1.2.3 — 2026-11-08
- Changed: agl looks cleaner. A new conversation opens with a short welcome showing the model, where it runs and the folder. Tool calls read as Read, Edit (with the lines changed), Write and Run (with the first lines of output). A spinner line shows what's running and for how long, and the footer shows how much of the model's context is used. Typing `/` lists every command with what it does.
- Fixed: Closing an agl tab, or switching models in agl, unloads the model agl made Ollama or LM Studio load, so it stops using memory. Models you loaded yourself, or that another agl tab is using, stay loaded. agl's own model server also stops when its tab closes, even if agl is killed.

## 1.2.2 — 2026-11-08
- Added: The Chat view shows subagents and Claude Code workflows as rows of their own: what each was asked to do, its kind of agent or workflow name, and whether it's still running. Background agents and workflows stay running until they finish, then show how long they took; click the row to read what they came back with. Works for Claude Code's agents and workflows, Codex's spawned agents and Grok's subagents, and agterm Remote shows background ones as running too.
- Added: agterm now comes with agl, the coding agent for local models. Type `agl` in any tab, or pick it in Shell → New Tab With Agent; it uses models from Ollama, LM Studio or its own library (`agl models`).
- Fixed: The Usage window opens in seconds instead of a minute or more on a Mac with a lot of Claude Code history. It now reads transcripts on every core and skips the tool output lines, which never hold token counts.
- Fixed: The buttons at the top right (worktrees, hand off, commit, usage, changes, session timeline) and the tab bar's buttons show their tooltips when you hover over them.

## 1.2.1 — 2026-11-08
- Fixed: Tabs kept running across an update or reinstall no longer lose Full Disk Access and agterm's other privacy permissions. The sessions helper now runs from its own copy of agterm, which updates don't replace. Tabs started before this version still need agterm → Quit and End Sessions once.

## 1.2.0 — 2026-11-08
- Added: The first launch after updating to 1.2 opens a welcome window: what's new since 1.1.7 by group, with switches for keeping the Mac awake while agents run, letting agents coordinate, and anonymous usage counts, a Set Up… button for your other Macs, and each feature's shortcut. Reopen it any time from agterm → Welcome to agterm 1.2….
- Added: Run agents' heavy commands on another Mac. On the Mac that should do the work, turn on Settings → Macs → "Let my other Macs run tasks on this Mac" and copy its pairing code; paste it in Settings → Macs on your main Mac. Agents in agterm tabs are then told to run builds, test suites and other heavy commands there with `agterm-remote run -- <command>`: it copies the project over (git-ignored files such as node_modules and .env stay put), runs the command there, shows its output in the tab as it runs and exits with its status. Add `--back` to copy the results back. Ctrl-C stops it on the other Mac too. The connection is encrypted with a key from the pairing code, and the other Mac keeps accepting tasks after agterm quits there.
- Added: agl, the local-model coding agent, is a known agent. Start it from Shell → New Tab With Agent, read its conversation in the Chat view and on agterm Remote, and a tab running agl comes back with its conversation after a restart.

## 1.1.8 — 2026-11-08
- Added: Pin tabs. Right-click a tab and choose Pin Tab: it moves to the top of the sidebar (or the start of the tab bar), shows a pin, and stays above the other tabs when you drag or open new ones, including after a relaunch. Unpin Tab puts it back below the pinned ones.
- Added: Claude Code and Codex agents started in agterm are told that the consult tools let them see every other agent running in agterm on this Mac, ask one about its work and leave it a message, and are encouraged to check before editing, committing or switching branches in a repo another agent is using. A Codex config that sets its own `developer_instructions` is left alone.
- Added: Chat view for Claude Code, Codex and Grok tabs. Press ⌃` (View → Chat), or click Chat in the strip above the tab, to read the conversation as a transcript: replies with formatting, folded file reads, edits as diffs, commands with their results and errors. Type in the box at the bottom to message the agent; Esc interrupts it. Approval prompts show as buttons; menus Chat can't read show the bottom of the screen, and ⌃` takes you back to the terminal. The agent keeps running in its terminal either way, and each pane of a split keeps its own view.
- Changed: agterm Remote reads Claude Code and Codex transcripts only as far as they grew since the last read.
- Changed: agterm uses much less memory with many agents running. Teams usage sync and tab titles read only what was added to each transcript instead of whole files, and agterm Remote forgets a conversation once you close it on your phone.
- Changed: Git status for busy tabs that aren't on screen is checked every 15 seconds instead of every 3, so agterm starts far fewer git processes. Tabs you can see still update every 3 seconds.
- Added: agterm sends anonymous usage counts so we can see how many people use it and which features matter: a random ID made on your Mac, agterm's and macOS's versions, the processor type, which agents start in your tabs, and how often you split a tab, open the command bar, open a cloud tab, pair a phone or install an update. Never files, folders, commands, what you type, repository names or account details. Turn it off in Settings → General → Privacy.
- Added: Window → Team Dashboard shows your agterm Teams team without agmux: tokens, estimated cost, active time and sessions over 7 to 90 days, daily usage, the monthly budget, providers and models, every member's usage and spend, and projects. Click a member to see their numbers and which Claude or Codex login did the work. Employees see their own numbers. It loads when you open it or press Refresh, and shows the last numbers it got while you're offline. Settings → Teams & Phone has a Team Dashboard… button too.
- Added: Team owners, and managers for the logins they added, can rename, pause and remove the team's shared Codex and Grok logins in the Team Dashboard.
- Added: Session Timeline (View → Session Timeline, ⇧⌘L, or the list button at the top right). It lists every prompt you sent in the tab with Claude Code, Codex or Grok, newest first, with whether it's running, done, failed or cancelled and how long ago. Click one to scroll the terminal to where that turn starts; it flashes briefly. In a plain shell tab it lists the commands you ran.
- Added: Install agterm with Homebrew: `brew install --cask neel-xanom/agmux/agterm`.
- Added: View → Command Palette (⇧⌘P). Type a few letters of any menu command or open tab, then press Return to run it or switch to that tab. Each command shows its menu and shortcut.
- Added: Keep Mac Awake While Agents Run, in the agterm menu and Settings → Agents. While an agent tab is working, your Mac doesn't sleep on its own; it sleeps normally again once no agent is working. Turn on "Also when the lid is closed" to keep it awake with the lid shut too. That asks for an administrator's password once, to install a small helper, and agterm shows a notification when it's keeping the Mac awake on battery.
- Changed: agterm runs its own project memory and consult servers for every agent, even with agmux installed, so you can uninstall agmux without losing memory. Repos agmux knows keep reading and writing agmux's memory where it is; nothing is copied or moved.
- Added: OpenCode, Kilo Code, Cursor Agent and Amp started in agterm get project memory and consult too, for that run only, without changes to their settings files. OpenCode, Kilo Code and Cursor Agent are also told how to use the memory.
- Changed: Git repos agmux doesn't know get their own memory even when agmux is installed.
- Added: Shell → Search Conversations… (⇧⌘F) finds past Claude Code, Codex and Grok conversations by what you or the agent wrote in them, across every login agterm manages. Each result shows the agent, the conversation's title, its folder, when it last ran and the text around the match. Pick one with the arrow keys and press Return to reopen it in a new tab in its folder.
- Changed: agmux Teams is now agterm Teams, at teams.agterm.dev. You stay signed in, your team, usage history and shared logins are unchanged, and agmux keeps working with the same team. Links to teams.agmux.dev open the new address.
- Added: Buttons at the top right of the window, each explained in its tooltip: show changes, commit, worktrees, hand off, usage, and the branch's pull request once there is one.
- Added: Show Changes (⇧⌘E) opens a panel beside the terminal with every changed file and its diff. Pick Agent (what the agent in the tab changed since it started), Uncommitted, or Branch (everything since the branch left main). It updates as the agent edits and reads nothing while it's closed. Drag its edge to resize it.
- Added: Commit (⌥⌘C) drafts a commit message with the same fast model as ⌘K, then commits, commits and pushes, or commits, pushes and opens a pull request with a written title and description, in one step. On main, opening a pull request first moves your work to a new branch and leaves main as it was. Pull requests need the GitHub CLI (gh).
- Added: New Worktree Tab (⇧⌘N) starts an agent on a new branch in a folder of its own under ~/.agterm/worktrees, with your .env files copied in and an optional first task. A repo can add .agterm/worktree-setup.sh to install dependencies first. Remove This Worktree asks before deleting anything and says what would be lost.
- Added: Hand Off continues an agent's conversation in Claude Code, Codex, Grok or Gemini CLI, in a new tab beside it.
- Added: Usage (⇧⌘U) shows tokens and estimated cost by day, model and project for Claude Code and Codex on this Mac, and how much of each login's limits is left.

## 1.1.7 — 2026-11-08
- Fixed: Starting claude in a folder that was deleted or that macOS blocks agterm from reading no longer hangs and uses up tens of gigabytes of memory; claude starts normally.
- Changed: agterm uses far less CPU while Claude Code and Codex run. It reads only the new part of each session's transcript, not the whole file every few seconds, checks git only in folders where something happened, and agterm Remote loads a conversation only while you have it open on your phone.

## 1.1.6 — 2026-11-07
- Changed: Split Right (⌘D) and Split Down (⇧⌘D) open an empty pane that lists your other tabs. Pick one, or click a tab in the tab bar or sidebar, to show it there, or choose New Shell. Every tab in a split keeps its own place in the tabs and is highlighted while the split is on screen; the one you're typing in has the accent bar.
- Added: Right-click a tab that isn't on screen and choose Show to the Right or Show Below to put it beside the current tab. Shell → Unsplit, or Unsplit on a split tab's menu, puts every pane back in a tab of its own; Move to Own Tab does it for one. Nothing closes.
- Changed: ⌘W closes the tab you're typing in, including one in a split; Close Pane and ⇧⌘W are gone.
- Added: The sidebar and the title above the terminal show each agent's logo.
- Changed: With more tabs than fit, sidebar tabs drop the spend and run time line, then the agent line, so more fit on screen.
- Changed: The sidebar is the terminal's color and its first tab sits right under the window buttons.
- Fixed: In a see-through window, a strip between the sidebar and the terminal showed what was behind the window.
- Fixed: An agent's run time counts from when it started, not from when agterm last opened.
- Fixed: Tabs in your home folder show ~ in the sidebar.

## 1.1.5 — 2026-11-07
- Added: Split a tab into panes, as in Warp. Shell → Split Right (⌘D) or Split Down (⇧⌘D) opens a new shell beside or below the one you're typing in, in the same folder. Drag the line between panes to resize them, and move between panes with ⌘[ and ⌘] or ⌥⌘ and the arrow keys. Panes you aren't typing in are dimmed. ⌘W closes the pane you're in and ⇧⌘W closes the whole tab. Your panes and their sizes come back the next time you open agterm.
- Added: View → Tabs on the Left (⌃⌘S) moves your tabs to a sidebar with more room for each one. A Claude Code or Codex tab shows its model (such as Opus 4.5), what it has spent so far in dollars and tokens, and how long it has been running, next to its status, folder and lines changed. A tab split into panes shows how many it has, and its dot shows whichever pane most needs you.

## 1.1.4 — 2026-11-06
- Added: When Claude Code stops because it couldn't reach Anthropic (no internet, Wi-Fi changing, the Mac sleeping mid-response), agterm types "Continue where you left off." as soon as the connection is back, unless you've typed in the tab since. Turn it off in Settings → Agents.
- Added: Click in the command you're typing at a zsh prompt to move the cursor there, instead of using the arrow keys.
- Fixed: cd suggestions find folders four levels inside your home folder, such as ~/Downloads/InFocus/Show Resources/InFocus 2026 Package. They used to stop at three.

## 1.1.3 — 2026-11-06
- Added: agmux Teams can split your usage by login. agterm now notes which Claude Code or Codex login each session runs on, including after an automatic account switch, and sends that with the hourly totals, so the Teams dashboard shows how many tokens went through each login. Logins appear as an opaque ID; a Claude login's email is sent only when your team's owner turns on Shared Claude accounts. Sessions started before this update stay unsplit.

## 1.1.2 — 2026-11-06
- Fixed: Teams cost estimates price Claude Haiku 5.5, including its higher rate for prompts over 100,000 tokens, which were left out before. Claude Sonnet 5.5 cache reads are counted at $0.10 per million tokens, not $0.20.

## 1.1.1 — 2026-11-04
- Added: Agents in agterm tabs coordinate with each other. consult tells every Claude Code, Codex and Grok agent how: a board per repo where they claim what they take on (a migration number, a file, a branch), ask everyone ("is anyone changing auth.ts?"), reply, and record decisions, and direct messages to one agent. They check the board when they start, before taking anything shared, and before finishing; claims expire after 4 hours unless renewed. With team sessions on, the board and the agents are shared with your teammates' agents; otherwise it covers the agents on this Mac.
- Added: A teammate's agent can ask a Codex or Grok tab a question, as well as a Claude Code one. The read-only copy that answers has no tools, so it answers from the conversation alone.
- Changed: Settings → Teams & Phone → Team Sessions is now "Let my agents coordinate with my team's agents".
- Fixed: consult's list_sessions and send_message work in agterm tabs without agmux running. They list this Mac's agent tabs and type the message into the agent, marked as coming from another agent.

## 1.1.0 — 2026-11-04
- Added: Team sessions. In Settings → Teams & Phone, members of an agmux team can share their agent tabs with teammates who also turn it on. Their agents then see your tabs' titles, folders, branches and status, and can ask a read-only copy of a Claude Code tab a question; the copy runs on your Mac and reads only that tab's conversation and the files in its folder. If you also allow messages, a teammate's agent can type a short note into your agent, marked as coming from them. Your agents get the same tools: list_team_sessions, ask_team_session and message_team_session in consult.
- Added: In Settings → Accounts, Use for New Sessions in an account's ⋯ menu makes new Claude Code, Codex or Grok sessions start on that account instead of your own login. Tabs already running stay where they are, and automatic switching still moves off it when it runs out.
- Added: Beta updates. Paste a beta key in Settings → General → Updates and agterm installs beta builds as well as stable releases, whichever is newer. Leave Beta goes back to stable releases.
- Fixed: An agent asking a copy of another Claude Code session with consult gets an answer when that session was started without permission prompts. It used to get an error.
- Fixed: A Grok tab that finishes while you're in another tab shows done instead of needs you. It shows needs you when Grok is waiting for your answer.
- Fixed: A Grok tab keeps showing working while Grok runs a long command or waits on a subagent, including right after agterm reopens. Before, it could look finished while Grok was still going.
- Fixed: A Grok tab no longer flips back to working after Grok finishes, such as when Grok names the conversation a few seconds later or while you type your next message. Its title also drops the trailing "- grok".
- Fixed: Opening agterm from inside one of its tabs no longer stops Claude from saving conversations, and tab status no longer flips between working and done afterwards.
- Fixed: Dropping a dragged tab leaves it where you dropped it, instead of the tabs appearing to swap a second time.
- Fixed: While you drag a tab, the tabs it passes over no longer light up as if the mouse were over them.

## 1.1.0-beta.9 — 2026-11-04
- Fixed: A Claude Code or Codex tab moved to the cloud opens its agent there again. The cloud machine didn't have them installed, so the tab was left at a shell prompt.
- Changed: A tab moved to the cloud shows its agent right away, and installs the project's dependencies in the background (logs in ~/.agterm/setup on the cloud machine). An agent stopped mid-turn is told the install may still be running.
- Changed: The cloud machine has Node 24 instead of Node 18, which many current packages no longer install on, and the 1Password CLI (op).
- Added: Settings → Cloud → 1Password takes a 1Password service account token and saves it only on your cloud machine, so agents in cloud tabs can use op.
- Added: Team sessions. In Settings → Teams & Phone, members of an agmux team can share their agent tabs with teammates who also turn it on. Their agents then see your tabs' titles, folders, branches and status, and can ask a read-only copy of a Claude Code tab a question; the copy runs on your Mac and reads only that tab's conversation and the files in its folder. If you also allow messages, a teammate's agent can type a short note into your agent, marked as coming from them. Your agents get the same tools: list_team_sessions, ask_team_session and message_team_session in consult.
- Fixed: An agent asking a copy of another Claude Code session with consult gets an answer when that session was started without permission prompts. It used to get an error.

## 1.1.0-beta.8 — 2026-10-31
- Fixed: A Grok tab that finishes while you're in another tab shows done instead of needs you. It shows needs you when Grok is waiting for your answer.
- Fixed: A Grok tab keeps showing working while Grok runs a long command or waits on a subagent, including right after agterm reopens. Before, it could look finished while Grok was still going.

## 1.1.0-beta.7 — 2026-10-31
- Added: agterm Remote keeps working while your Mac is off. Tabs you moved to the cloud stay on your phone with the same pairing: you can watch them, read the agent's conversation, type, answer its prompts, and get notified when it finishes or needs you. Once your Mac is back, it takes the phone over again. New tabs still open only from the Mac. This needs the phone remote turned on in Settings.
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
