# Cloud sessions: Move All to Cloud

Draft plan, 2026-10-30. Goal: one button before closing the laptop moves every tab to a cloud machine. Agents keep working, the phone keeps working, and the tabs come back to the Mac later.

## What moves and what doesn't

A process can't be moved from macOS to Linux, so "move" means **sync the files, copy the conversation, and resume the agent in the cloud**. agterm already does this between logins (`AccountSwitcher`): stop the agent, then run `claude --resume <id> "Continue where you left off."` in the same tab.

| Tab | In the cloud |
|---|---|
| Claude Code / Codex / Grok | Same conversation, resumed; a turn that was in progress continues |
| Idle shell | Same folder and scrollback, new shell |
| Running command (dev server, `npm test`) | Listed before the move; restarted or left stopped (your choice per tab) |
| macOS-only work (`.xcodeproj`, `xcodebuild`, simulators) | Flagged; can't run on Linux |

## The trick that keeps paths working

Create the **same absolute paths on the VM** (`/Users/neel/...`, with a Linux user whose home is `/Users/neel`). Claude Code keys transcripts by cwd (`~/.claude/projects/<cwd with non-alphanumerics as ->/<id>.jsonl`), and transcripts contain absolute paths on every line. Mirroring the paths means nothing has to be rewritten, and `AgentResume`, `SavedTab.cwd` and `PathDisplay` work unchanged.

## Flow: Move All to Cloud

1. **Preflight sheet** (a few seconds): each tab with what will happen, how much needs uploading, and warnings (macOS-only project, local stdio MCP servers, running commands).
2. **Freeze agents**: wait up to ~20 s for a turn boundary, otherwise interrupt. Same code path as `AccountSwitcher.switchTab`.
3. **Sync files** for each distinct git root / folder: rsync-style deltas into the VM's volume. Include untracked and ignored files such as `.env`. Exclude rebuildable, OS-specific folders (`node_modules`, `.build`, `target`, `.venv`, `DerivedData`), since Mac-native binaries don't run on Linux anyway. The volume keeps the last copy, so only the first move is slow. Optional "keep a warm copy" syncs in the background, which brings the button down to seconds.
4. **Copy agent state**: the Claude transcript plus its `<session-id>/` sidecar folder, the Codex rollout file, and user config (`~/.claude/CLAUDE.md`, settings, skills, agents, commands; `~/.codex/config.toml`, `AGENTS.md`). Never copy credential files.
5. **Start in the cloud**: send the `SavedWorkspace` (tabs, scrollback, resume commands, tab ids) to the cloud helper. It spawns each shell and types the resume command.
6. **Switch the Mac's tabs to the cloud host** (attached over the network), then stop the local shells. The Mac says "Safe to close."

Hooks: menu item + shortcut, and in `applicationShouldTerminate`, "Agents are working. Move them to the cloud instead?" Sleep notifications give too little time to sync, so lid-close can't be the trigger.

## Flow: Bring back

When the Mac starts and the cloud has tabs: **Keep in cloud** (just attach) or **Bring back**. Bring back runs the same steps in reverse: freeze, sync cloud→Mac (warn if local files changed since the move), copy transcripts back, resume locally, stop the VM.

## Architecture

```
Mac agterm ──wss (Fly proxy)──► gateway ──unix socket──► sessions helper   (one process: agterm-sessions --listen)
iPhone ─────agmux relay─────► cloud desktop (same tab ids)
control plane: accounts, Stripe, VM create/start/stop
```

- **Linux helper**: `AgTermSessionKit` + `AgTermCore` have no AppKit. Swap `Darwin.*` for `Glibc` under `#if`, fix the `CMSG` layout in `SocketIO.swift`, drop the launchd bits in `SessionPaths`. Run `SessionServerTests` / `HeadlessTerminalTests` on Linux in CI.
- **Gateway** (`SessionGateway`, built): `SessionWire` frames inside a WebSocket (`WebSocketTransport`, hand-written, no SwiftNIO), in the helper's own process. Fly's shared IPv4 and its per-machine routing (`fly-force-instance-id`) work only for HTTP services, so one Fly app with a free shared address serves every user's machine; Fly terminates TLS, and the Mac connects with URLSession. The first frame must be `auth` with the machine's token (`AGTERM_GATEWAY_TOKEN`). Then the gateway opens its own connection to the helper's socket and passes frames both ways, closing the pty descriptors the helper passes. Clients type with the new `input` message and resize with `resize`, both added tags. Spawns get the machine's login shell, home and PATH; of the Mac's environment only the terminal variables and the tab id arrive.
- **Status in the cloud**: `StatusRules` lives in Core, so the cloud side knows working / needs you / done. It pushes "needs you" and "all done" to the phone and decides when to stop the VM.
- **Phone**: the cloud registers on the relay so agterm Remote works with the Mac off.
- **Cloud helper updates**: only applied while the VM is stopped (you control both sides, but must not kill running tabs).

## Hosting: Fly.io Machines (recommended)

- One Machine + one volume per user, created by the control plane. You decide when it stops; nothing pauses mid-task.
- Oct 2026 prices: shared-cpu-4x + 4 GB ≈ $0.037/hour running; stopped = rootfs only ($0.15/GB-month); volume $0.15/GB-month.
- Auto-stop when every agent has been idle/done for N minutes and no client is attached.
- Alternative: **Fly Sprites** (usage-billed, sleep when idle). Cheaper when agents mostly wait, but a Sprite pauses on its own unless a Task holds it active, and processes die on a cold sleep. More moving parts for v1.
- E2B / Daytona work too, but cost more per hour and give less control.

## Agent logins on the VM (one-time setup)

- **Claude Code**: `claude setup-token` makes a long-lived token for your own subscription; it's stored as an encrypted per-user secret and set as `CLAUDE_CODE_OAUTH_TOKEN`. (claude.ai connectors don't work with that token.)
- **Codex**: `codex login --device-auth` inside a cloud tab. Copying `auth.json` is documented but its refresh token rotates, so Mac and cloud would log each other out.
- Multiple accounts (`AGTERM_ACCOUNT`, team pool): open question below.

## Cost and price

| | Per user / month |
|---|---|
| 100 running hours (4 GB) | ~$3.70 |
| 20 GB volume | $3.00 |
| Stripe on $12 | ~$0.65 |
| **Cost** | **~$7.35** |

Suggested plan: **$12/month: 100 cloud hours, 20 GB, 4 GB RAM; $0.10/hour after.** Larger 8 GB tier for heavy dev servers. Hard monthly cap the user sets.

## Security

- Per-user microVM, never shared; volumes encrypted; delete everything within N days of cancelling.
- Tokens only in the per-user secret store, never in images or logs.
- Gateway is the only open port; the helper's socket stays local to the VM.

## Phases

1. Linux helper + tests in CI. Verify: `SessionServerTests` pass on Linux. **Done 2026-10-30**: `agterm-sessions` (Linux only), all 455 Core + SessionKit tests pass on Linux (Swift 6.4, Ubuntu 24.04) and macOS; `.github/workflows/linux.yml`.
2. Gateway + "cloud host" tabs in the Mac app (a hand-made VM). Verify: a self-test attaches a tab over the network and replays its screen. **Done 2026-10-30**:
   - `agterm-sessions --listen`, and Shell → New Cloud Tab when `AGTERM_CLOUD` and `AGTERM_CLOUD_TOKEN` are set. Loopback only until the client has TLS.
   - `AGTERM_CLOUD_CHECK=1` passes against an in-process gateway and against the Linux helper in a container.
   - Left for phase 3: TLS in the client; cloud tabs coming back after a relaunch; a cloud marker on the tab; and agent and folder info for cloud tabs, which today come from local process lookups that a cloud tab skips.
3. Move All to Cloud for agent tabs (sync, transcripts, resume). Verify: a Claude tab mid-turn keeps going after the Mac app quits. **Done 2026-10-30**:
   - Shell → Move All Tabs to Cloud…, and a "Move to Cloud, Then Quit" button when quitting with agents running.
   - Files go with macOS's rsync through the gateway: the gateway's `exec` message, and `agterm --cloud-pipe` as rsync's remote shell. Nothing on the cloud machine is deleted.
   - The cloud helper reports what runs in each tab (`inspect`), so cloud tabs get status, agent detection and resume commands. Cloud tabs come back after a relaunch.
   - `AGTERM_MOVE_CHECK=1` passes against `scripts/cloud-dev.sh`: a fake Claude (`scripts/fake-claude.c`) stopped mid-turn resumes in Linux with its transcript and the "continue" prompt, and is still running after the app quits.
   - Not done yet: restarting running commands in the cloud (the preflight is a plain list, and they are left stopped); copying `~/.claude/settings.json` and `~/.codex/config.toml`, which hold Mac paths and sometimes keys; TLS in the client.
4. Control plane, Fly VMs, auto-stop, Stripe, sign-up. Verify: hours metered match Fly's bill. **Deployed 2026-10-30** (Fly app `agterm-cloud-machines`; Worker at `cloud.agterm.xanom.co` with D1 `agterm-cloud`; Stripe product `prod_VXTeB14MuxIAnz`, price `price_1UWOhTBPM9ZAoURpxHnL4wJe` and webhook `we_1UWOiaBPM9ZAoURpyxIPyGOT` on the live agmux account). Tested end to end with a real machine in sjc: the cloud and move self-tests passed over wss, the machine stopped itself when idle (exit 0), Fly's proxy woke it in 2 s, and it was then removed. Comparing metered hours with Fly's bill waits for a month of use.
   - `cloud/Dockerfile` + `entrypoint.sh`: the user at the Mac's home path on their volume, `/tmp` → `/private/tmp`, git, rsync, build tools, Python, Node. The helper runs with `--idle-stop 900`: with no client and no output for 15 minutes it exits, so the machine stops; Fly's proxy starts it on the next connection.
   - `cloud/control`: a Worker with D1. It checks the agmux Teams token (`/api/auth/me`), runs Stripe Checkout, the billing portal and the webhook, creates a volume and machine per user on first use, meters running hours hourly from Fly's machine events, stops a machine at the user's limit (autostart off until the next period), and deletes it 30 days after cancelling.
   - The app: Settings → Cloud (subscribe, set up the machine, limit, billing); the connection lives in the Keychain. Hidden until launch (`defaults write … agtermCloud -bool true`).
   - Not yet: overage billing at $0.10/hour (v1 stops at the included hours); resuming agents on a machine that stopped while tabs were open (they come back from history); moving existing machines to a new image (the control plane should update each one while it is stopped). New Fly orgs allow 2 cores a machine, so machines are shared-cpu-2x with 4 GB.
5. Phone on the cloud desktop; Bring back. Verify: phone answers a prompt with the Mac off; bring back leaves no file differences.
6. Warm copy (background sync), preflight polish, 8 GB tier.

## Decisions (2026-10-30)

- **Coming back**: ask each time, Keep in cloud or Bring back.
- **Logins**: one-time setup in the cloud (`claude setup-token`, `codex login --device-auth`); never copy credentials from the Mac.
- **Running commands**: the preflight sheet asks per tab, restart in cloud or leave stopped.
- **Billing**: $12/month, 100 hours, 20 GB, 4 GB RAM; $0.10/hour after, with a user-set cap.

## Still open

- Multiple logins per agent (`AGTERM_ACCOUNT`, team pool): set up each one in the cloud, or only the default?
- Phone: does agterm Remote need to show two desktops (Mac and cloud), or should the cloud take over the Mac's desktop id while the Mac is off?
- Base image: which toolchains come preinstalled, and whether to honor a repo's `.devcontainer`. Required either way: the user's home at the Mac's home path, `/tmp` as a link to `/private/tmp` (agents key conversations by the real path of their folder), and rsync.
