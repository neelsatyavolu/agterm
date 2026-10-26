# agterm Remote

The iPhone app for agterm. It shows the Mac's tabs as agterm draws them, each tab's live screen in the Mac's colors, and the prompts agents are waiting on as buttons. You can type replies, press keys a phone keyboard lacks (Esc, arrows, Tab, ⇧Tab, ^C) and stop an agent. Claude Code and Codex tabs also have a Chat view built from their transcripts.

It talks to the Mac through the [agmux](https://agmux.dev) remote relay, unchanged. agterm is its own desktop on the relay, with its own identity.

## Pairing

On the Mac: agterm Settings → Teams & Phone → turn the phone on → Pair a Phone. Scan the QR code with the iPhone's Camera app (it opens agterm Remote), or use Scan Code in the app. The code is an `agterm-remote://pair#pair=…&desktopId=…` link; the app also accepts agmux's `https://remote.agmux.dev#pair=…` links and pasted links. The phone's token is kept in the Keychain.

## How it uses the relay

The relay forwards a fixed list of message types, so agterm's additions ride inside them as extra fields that the agmux phone app ignores. `Sources/AgTermCore/Remote/AgTermWire.swift` is the reference:

| What | Message | Extra fields |
|---|---|---|
| Tab details: status, folder, branch, the prompt on screen | `threads.snapshot` rows | `agterm` (`TabInfo`) |
| Live screen | phone sends `thread.subscribe` | `screen: true` (a 45 s lease, renewed every 20 s) |
| | Mac sends `timeline.snapshot` on thread `screen:<tab id>` | `screen` (`ScreenSnapshot`: colored runs, cursor, theme) |
| Keys | `message.send` | `raw: true`, `keys` (`TerminalKey` names) |
| Conversation | `thread.subscribe` | `lease: true` (same lease terms as the screen) |
| New tab | `threads.snapshot` | `agterm` (`NewTabOptions`: installed agents, folders) |
| | phone sends `thread.create` | `provider` (agent id or `shell`), `projectId` (folder); the Mac answers `thread.created` |
| Notifications | phone sends `push.register` | `topic: co.xanom.agterm.remote`, which the relay must list in `APNS_TOPICS` |

Plain `message.send` (clear the line, type, Enter), `turn.interrupt`, `approval.*` and the Chat timeline work as they do for agmux.

The Mac sends a screen only while a phone holds its lease and only when the screen changed, at most about three times a second.

## Build

Needs Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The project file is generated and not committed.

```sh
cd Mobile
xcodegen generate
open AgTermRemote.xcodeproj
```

iPhone, iOS 18 or later. Bundle id `co.xanom.agterm.remote`, team `VTQW687WBQ`.

## End-to-end test

`AgTermRemoteUITests` drives the app against a real agterm and relay: it pairs from a link, runs `echo` in the first tab and waits for the output, then answers a permission prompt from a stand-in `claude`. Without the variables below the tests are skipped.

1. Run agmux's relay locally: `cd ../agmux/remote-relay && PORT=8791 node server.mjs`.
2. Run a dev agterm against it: `swift build && AGTERM_RELAY_URL=ws://127.0.0.1:8791/ws AGTERM_STATE_DIR=/tmp/agterm-state .build/debug/AgTerm`. It has its own settings domain, so turn the phone on in its Settings (or `defaults write AgTerm remoteEnabled -bool YES` before launching).
3. Pair a Phone in its Settings and build the link from the code and the desktop id in `~/Library/Application Support/agterm-dev/remote-credentials.json`.
4. Compile a stand-in `claude` that prints a Claude Code permission prompt, reads one key and prints `answered-<key>`.
5. Run:

```sh
TEST_RUNNER_PAIR_URL='agterm-remote://pair#pair=CODE&desktopId=ID&relay=ws://127.0.0.1:8791/ws' \
TEST_RUNNER_FAKE_CLAUDE=/path/to/claude \
xcodebuild test -project AgTermRemote.xcodeproj -scheme AgTermRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### Agents tested from the phone (October 2026)

`testRealAgents` starts each agent in a tab from the phone, answers its first-run screens with the key bar, asks a question in the reply box and waits for the answer on the live screen (and in Chat for Claude Code and Codex).

| Agent | Result |
|---|---|
| Claude Code, Codex | Answered on the live screen and in Chat |
| Grok, Antigravity (`agy`) | Answered on the live screen |
| OpenCode, Pi, Qodo, Aider | The question arrived and the agent's own error came back (expired token, rate limit, discontinued service, retired model) |
| Gemini CLI, Cursor Agent, Factory Droid, Kimi Code | Stopped at a login screen |
| Auggie | Reached its prompt but didn't answer, also when run outside agterm |
| Kilo Code, Cline | Crashed or were killed by macOS at launch, before any input |

First-run screens: Claude Code and Codex folder trust (Codex's shows as a prompt card), Codex's security notice (`esc`), Kimi's trust dialog (`up enter`), Aider's `.gitignore` question (`--no-gitignore`), Auggie's onboarding and indexing screens (`esc esc`).

## Release to TestFlight

```sh
OP_ACCOUNT=<1Password account> scripts/release-ios.sh              # archive, sign, upload
OP_ACCOUNT=<1Password account> scripts/release-ios.sh --no-upload  # signed build/agterm-remote.ipa only
```

The same signing setup as agmux's iPhone app: the Apple Distribution certificate and the team's App Store Connect API key come from 1Password (items "Apple Distribution Certificate" and "Xanom Apple Dev Creds" in the Private vault). `scripts/asc-profile.mjs` registers the App ID and keeps the "agterm Remote App Store" profile current. Build with the release Xcode; App Store Connect rejects beta-Xcode builds. The build number is the UTC time. The app record is "agterm Remote" (Apple ID 6826934308).

## Notifications

The relay (not the Mac) sends "Approval needed" and "Agent finished" alerts to phones that aren't showing the app, with the team's APNs key. A phone registers under its app's bundle id, so `co.xanom.agterm.remote` is listed in `APNS_TOPICS` in `agmux/remote-relay/wrangler.toml`. Tapping an alert opens its tab. `testPushWhenClosed` checks this against the deployed relay.
