# Agent Instructions

agterm is a macOS terminal for coding agents (SwiftPM, AppKit), plus agterm Remote, its iPhone app.

## Layout
| Path | What |
|------|------|
| `Sources/AgTerm/` | The Mac app (AppKit, SwiftTerm) |
| `Sources/AgTermCore/` | Logic shared with the iPhone app: no AppKit, no SwiftTerm imports |
| `Sources/AgTermSessionKit/` | The session helper's server, socket code and entry point (shells live here, not in the app). The helper is the app's own executable run as `agterm --sessions-helper`, so it keeps agterm's code identity and privacy permissions; don't split it back into a separate binary |
| `Sources/agterm-sessions/` | The sessions helper alone, built only on Linux, for cloud sessions (`docs/cloud-sessions-plan.md`). Keep `AgTermCore` and `AgTermSessionKit` building on Linux |
| `Vendor/SwiftTerm/` | SwiftTerm with local changes; edit in place, keep the comments explaining each change |
| `Mobile/` | agterm Remote (iOS); see `Mobile/README.md` |
| `Tests/AgTermCoreTests/` | XCTest for `AgTermCore` |
| `Tests/AgTermSessionKitTests/` | XCTest for the session helper (runs a server in-process) |
| `site/` | agterm.xanom.co landing page (Vercel) |

## Commands
| Task | Command |
|------|---------|
| Build | `swift build` |
| One test class | `swift test --filter ChangelogTests` |
| All tests | `swift test` |
| Linux tests (OrbStack/Docker) | `docker run --rm -v "$PWD":/src -v agterm-linux-build:/build -w /src swift:6.4-noble swift test --scratch-path /build` |
| Cloud tabs against a Linux helper | Build `agterm-sessions` as above, run it in a container with `-p 127.0.0.1:7600:7600 -e AGTERM_GATEWAY_TOKEN` and `--sessions-helper --socket /tmp/agterm/s.sock --build linux --listen 0.0.0.0:7600`, then start the app with `AGTERM_CLOUD=127.0.0.1:7600 AGTERM_CLOUD_TOKEN=<same>` (add `AGTERM_CLOUD_CHECK=1 AGTERM_SELFTEST=<dir>` for the self-test) |
| Off-screen UI self-test | `AGTERM_SELFTEST=<dir> AGTERM_FEATURE_CHECK=1 .build/debug/AgTerm` (without `AGTERM_STATE_DIR` it uses a private temp state folder and sessions helper) |
| Install locally | `./install.sh --adhoc` |
| Release build | `scripts/bundle.sh` |
| Publish a release | `scripts/release.sh` (maintainer only) |

## Self-tests
- `Sources/AgTerm/SelfTest.swift` holds them; each `AGTERM_*_CHECK=1` picks one check and prints `selftest:` lines. The quit-and-relaunch check (`AGTERM_PERSIST_CHECK=1`, `persist:` lines) is in `SelfTestPersist.swift`.
- Quitting leaves tab shells running in the sessions helper (`agterm --sessions-helper`), so self-tests end the helper's sessions when they exit.
- PNG snapshots land in the `AGTERM_SELFTEST` directory; look at them after UI changes.
- Add a check there for any UI change you can't cover with a unit test.
- Debug builds keep their own state (`agterm-dev`); `AGTERM_STATE_DIR` overrides it, so tests never touch the installed app's tabs.

## Session helper compatibility
The sessions helper outlives app updates: someone who keeps tabs open keeps the helper from the version they started it with, possibly several releases back, and a helper bug can't be fixed by an update until they choose Quit and End Sessions. So:
- Every app version must keep working with every helper version already shipped, and every helper with newer apps.
- Wire changes (`Sources/AgTermCore/SessionWire.swift`) only add: new tags and new optional JSON fields (`decodeIfPresent` with a default). Never renumber or reuse a tag, rename or retype a field, or change what an existing message means.
- Receivers skip frames with unknown tags, so an old peer ignores a new message: never rely on it being answered without checking the helper's build first. A new message that passes a descriptor goes only to a peer that asked for it.
- Bump `SessionWire.protocolVersion` only together with a fallback that keeps talking to helpers of the old version.
- Test helper changes over long runs (memory, CPU) before shipping; see `HeadlessTerminalTests` and `SessionServerTests`.

## Changelog and releases
- `CHANGELOG.md` holds user-facing release notes. The app shows them in its What's New tab, and `scripts/release.sh` publishes the same text as the GitHub release notes.
- Every user-visible change adds a bullet under the next version's `## <version> — <YYYY-MM-DD>` section, in the same commit as the change.
- Bullets start with `- Added:`, `- Fixed:` or `- Changed:` and describe what the user sees, not the code.
- To release: bump `VERSION`, date the section, commit, then run `scripts/release.sh`. It stops if `CHANGELOG.md` has no section for `VERSION`.

## Conventions
- Match the existing style: short doc comments on types and non-obvious functions, small files, no speculative abstractions.
- Colors come from `Theme` / `ThemePalette`; never hard-code RGB in views. Every UI change must read well in the light Paper theme as well as Ink.
- User-facing copy is plain and specific; no hype words.
- Commits: `<type>: <description>` with type feat, fix, refactor, docs, test, chore or perf.

## External References
| Need | File |
|------|------|
| Features, shortcuts, build from source | `README.md` |
| Phone relay protocol | `Mobile/README.md`, `Sources/AgTermCore/Remote/AgTermWire.swift` |
| Signing setup | `scripts/maintainer.local.example` |
