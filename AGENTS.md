# Agent Instructions

agterm is a macOS terminal for coding agents (SwiftPM, AppKit), plus agterm Remote, its iPhone app.

## Layout
| Path | What |
|------|------|
| `Sources/AgTerm/` | The Mac app (AppKit, SwiftTerm) |
| `Sources/AgTermCore/` | Logic shared with the iPhone app: no AppKit, no SwiftTerm imports |
| `Vendor/SwiftTerm/` | SwiftTerm with local changes; edit in place, keep the comments explaining each change |
| `Mobile/` | agterm Remote (iOS); see `Mobile/README.md` |
| `Tests/AgTermCoreTests/` | XCTest for `AgTermCore` |
| `site/` | agterm.xanom.co landing page (Vercel) |

## Commands
| Task | Command |
|------|---------|
| Build | `swift build` |
| One test class | `swift test --filter ChangelogTests` |
| All tests | `swift test` |
| Off-screen UI self-test | `AGTERM_SELFTEST=<dir> AGTERM_FEATURE_CHECK=1 .build/debug/AgTerm` |
| Install locally | `./install.sh --adhoc` |
| Release build | `scripts/bundle.sh` |
| Publish a release | `scripts/release.sh` (maintainer only) |

## Self-tests
- `Sources/AgTerm/SelfTest.swift` holds them; each `AGTERM_*_CHECK=1` picks one check and prints `selftest:` lines.
- PNG snapshots land in the `AGTERM_SELFTEST` directory; look at them after UI changes.
- Add a check there for any UI change you can't cover with a unit test.
- Debug builds keep their own state (`agterm-dev`); `AGTERM_STATE_DIR` overrides it, so tests never touch the installed app's tabs.

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
