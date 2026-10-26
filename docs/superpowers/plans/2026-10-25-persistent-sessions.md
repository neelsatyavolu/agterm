# Persistent Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tabs' shells and the programs in them (agents included) keep running through an agterm update, quit or crash, and agterm reattaches to them on the next launch.

**Architecture:** A small helper, `agterm-sessions`, owns every tab's pty, the way iTerm2's server process does. It reads each pty all the time, so programs never block. It feeds a headless SwiftTerm `Terminal` so it always knows the screen, and it forwards output to the app when the app is attached. The app connects over a Unix socket. On attach it receives a replay of the screen and terminal modes, then live output, plus a dup of the pty master fd (`SCM_RIGHTS`) that it uses for writing input, resizing and `tcgetpgrp`. When the helper can't be reached, tabs fall back to today's in-process `LocalProcess`.

**Tech Stack:** Swift 5.10 SwiftPM, AppKit, vendored SwiftTerm (`Vendor/SwiftTerm`), POSIX ptys and Unix domain sockets, XCTest.

**Spec:** the user's request ("update agterm without your sessions being killed; they continue in the background") and their answer "Helper owns shells": sessions survive updates, ⌘Q and crashes.

## Global Constraints

- macOS 14+ (Package.swift `platforms: [.macOS(.v14), .iOS(.v17)]`). `AgTermCore` must stay free of AppKit and SwiftTerm because the iPhone app uses it.
- Socket path: `/tmp/agterm-<uid>/<8 hex of FNV-1a of the state dir>.sock`. The directory is mode 0700. sun_path is limited to 104 bytes, so it can't live under Application Support with long self-test state dirs.
- State dir = `WorkspaceStore.fileURL`'s directory (honours `AGTERM_STATE_DIR`), so debug builds and self-tests never touch the installed app's helper.
- The wire protocol carries `protocolVersion: Int = 1`. The app only uses a helper that reports the same version.
- Never write secrets or terminal contents to logs.
- No new third-party dependencies.

## Review Focus

1. **Update while an agent is streaming output.** Expected: the agent keeps running and never blocks on a full pty. After relaunch the tab shows its current screen and continues. → Task 2 test `testReadsWhileNoClientAttached`.
2. **Old helper, new app (after an update).** Expected: same protocol version → reattach. Different version → new tabs use the in-process fallback, and the old helper's sessions are still adopted if possible, else left alone and never killed silently. → Task 4 test `testVersionMismatchFallsBackToLocal`.
3. **App crashes before saving the workspace.** Expected: helper sessions not in `workspace.json` still come back as tabs at the end. → Task 5 self-test `persist: orphan adopted`.
4. **Full-screen program (vim/less/codex alt screen) at reattach.** Expected: the alt screen, cursor, bracketed paste, mouse and cursor-key modes are restored, and a resize nudge makes the TUI redraw. → Task 3 tests.
5. **Shell exits while the app is away.** Expected: the session is gone on relaunch, and the tab falls back to the saved scrollback + resume command (today's restore). → Task 5 self-test `persist: exited session restored from save`.

---

## File Structure

- `Sources/AgTermCore/SessionWire.swift` (new): message enum and length-prefixed framing; pure and testable.
- `Sources/AgTermSessionKit/` (new library target, depends on AgTermCore + SwiftTerm; macOS only):
  - `ScreenReplay.swift`: turns a headless `Terminal` into the bytes that rebuild it in a fresh one. `Scrollback.capture` moves here, and the app's `Scrollback.swift` keeps calling it.
  - `SocketIO.swift`: connect/listen on the Unix socket, send/receive frames, and send/receive an fd with `SCM_RIGHTS`.
  - `SessionPaths.swift`: the socket path rule above.
- `Sources/AgTermSessions/main.swift` + `SessionServer.swift` + `HostedSession.swift` (new executable target `agterm-sessions`): the helper.
- `Sources/AgTerm/PtyLink.swift` (new): `protocol PtyLink` with `HelperLink` (the helper) and `LocalLink` (wraps SwiftTerm `LocalProcess`).
- `Sources/AgTerm/SessionHelper.swift` (new): finds or launches the helper, handshakes, lists, spawns and attaches.
- Modify `Sources/AgTerm/AgentTerminalView.swift`: subclass `TerminalView` instead of `LocalProcessTerminalView`, and drive a `PtyLink`.
- Modify `Sources/AgTerm/TerminalSession.swift`: use `view.link` in place of `view.process` (`shellPid`, `ptyFd`), and add `sessionID` plus `init(attaching:)`.
- Modify `Sources/AgTermCore/Restore.swift`: `SavedTab.sessionID: String?` (optional, so old files still decode).
- Modify `Sources/AgTerm/MainWindowController.swift`, `AppDelegate.swift`: reattach on launch, detach on quit, and a "Quit and End Sessions" menu item.
- Modify `scripts/bundle.sh`: copy and sign `agterm-sessions` into `Contents/MacOS/`.
- Tests: `Tests/AgTermCoreTests/SessionWireTests.swift`, new target `Tests/AgTermSessionKitTests/` (`ScreenReplayTests.swift`, `SessionServerTests.swift`).

---

### Task 1: Wire protocol

**Files:**
- Create: `Sources/AgTermCore/SessionWire.swift`
- Test: `Tests/AgTermCoreTests/SessionWireTests.swift`

**Interfaces:**
- Produces:
  - `public enum SessionWire { public static let protocolVersion = 1 }`
  - `public struct SpawnRequest: Codable, Equatable { executable: String; argv: [String]; env: [String]; cwd: String; cols: UInt16; rows: UInt16 }`
  - `public struct SessionInfo: Codable, Equatable { id: String; pid: Int32; cwd: String; startedAt: Date }`
  - `public enum WireMessage: Equatable` with cases `hello(version: Int, build: String)`, `list`, `sessions([SessionInfo])`, `spawn(SpawnRequest)`, `attach(id: String)`, `attached(SessionInfo)`, `replay(Data)`, `output(Data)`, `exited(id: String, status: Int32)`, `kill(id: String, signal: Int32)`, `shutdownIfIdle`, `error(String)`
  - `public enum WireFrame { static func encode(_ m: WireMessage) -> Data; static func decode(_ buffer: inout Data) throws -> WireMessage? }`: frame = 4-byte big-endian length + 1-byte tag + payload. `output`/`replay` payloads are raw bytes, the rest JSON. `decode` consumes one complete frame from the front of `buffer`, returns nil when incomplete, and throws on a length over 16 MiB or an unknown tag.

- [ ] **Step 1: Write failing tests**: `testEveryMessageRoundTrips` (each case encode→decode equal), `testPartialFrameReturnsNilAndKeepsBytes` (feed first 3 bytes → nil, buffer unchanged; feed rest → message), `testTwoFramesInOneBuffer`, `testOversizedLengthThrows` (length 16 MiB + 1), `testUnknownTagThrows`.
- [ ] **Step 2:** `swift test --filter SessionWireTests` → fails to compile (`WireFrame` missing).
- [ ] **Step 3:** Implement as specified.
- [ ] **Step 4:** `swift test --filter SessionWireTests` → all pass.

### Task 2: Helper (`agterm-sessions`)

**Files:**
- Modify: `Package.swift`: add targets `AgTermSessionKit` (deps AgTermCore, SwiftTerm), executable `AgTermSessions` (product name `agterm-sessions`, deps AgTermSessionKit), test target `AgTermSessionKitTests`; `AgTerm` gains dep `AgTermSessionKit`.
- Create: `Sources/AgTermSessionKit/SessionPaths.swift`, `Sources/AgTermSessionKit/SocketIO.swift`, `Sources/AgTermSessions/{main,SessionServer,HostedSession}.swift`
- Test: `Tests/AgTermSessionKitTests/SessionServerTests.swift`

**Interfaces:**
- Consumes: Task 1 `WireMessage`, `WireFrame`, `SpawnRequest`, `SessionInfo`.
- Produces:
  - `public enum SessionPaths { static func socket(stateDir: String) -> String }`
  - `public final class WireConnection { init(fd: Int32); static func connect(path: String) throws -> WireConnection; func send(_ m: WireMessage) throws; func send(fd: Int32) throws; func receive() throws -> WireMessage /* blocking */; func receiveFD() throws -> Int32; var onMessage: ((WireMessage) -> Void)?; func startReading(queue: DispatchQueue); func close() }`
  - `public final class SessionServer { init(socketPath: String, build: String); func run() /* blocks */; var idleExitAfter: TimeInterval /* 10 */ }`: also usable in-process from tests on a background thread.
- Behaviour: each connection starts with `hello` from the client, and the server answers `hello`. Then one of: `list` → `sessions`; `spawn` → forkpty (`PseudoTerminalHelpers.fork(andExec:)` as SwiftTerm does, with `setsid`), reply `attached`, send the master fd dup, then `replay`, then stream `output`; `attach(id)` → same minus the spawn (a second attach to a session replaces and closes the first client); `kill` → `kill(pid, signal)` plus SIGHUP to the foreground group (as `TerminalSession.terminate`); `shutdownIfIdle` → exit if no sessions. Each session reads its pty with a `DispatchSourceRead` and feeds a headless `Terminal(delegate:options:)` with scrollback `10_000` and the spawn's cols/rows. The helper never stops reading. A `DispatchSourceProcess` exit handler reaps with `waitpid`, sends `exited` to the attached client if any, and drops the session. `main.swift`: args `--socket <path> --build <id>`; `setsid()`, `signal(SIGHUP, SIG_IGN)`, `signal(SIGPIPE, SIG_IGN)`, `chdir("/")`; unlink a stale socket only if connecting to it fails; exit after `idleExitAfter` with no sessions and no clients.

- [ ] **Step 1: Write failing tests** (server in-process on a temp socket path under `/tmp`):
  - `testSpawnRunsCommandAndStreamsOutput`: spawn `/bin/sh -c 'echo HELLO; sleep 5'`, expect `attached`, an fd ≥ 0, then `output` containing `HELLO` within 2 s.
  - `testReattachReplaysScreen`: spawn `printf 'MARK\n'; sleep 5`, close the client, attach by id on a new connection → `replay` contains `MARK` and the pid is unchanged.
  - `testReadsWhileNoClientAttached`: spawn `/bin/sh -c 'yes | head -c 2000000; echo DONE; sleep 5'`, disconnect right away, wait 2 s, attach → replay contains `DONE` (the writer was never blocked).
  - `testExitIsReportedAndSessionDropped`: spawn `/bin/sh -c 'exit 3'` → `exited(status: 3)`; `list` no longer contains it.
  - `testKillEndsSession`: spawn `sleep 30`, `kill(SIGHUP)` → `exited` within 2 s; `kill(pid, 0)` fails afterwards.
- [ ] **Step 2:** `swift test --filter SessionServerTests` → fails to compile.
- [ ] **Step 3:** Implement the targets above.
- [ ] **Step 4:** `swift test --filter SessionServerTests` → pass. `swift build` also produces `.build/debug/agterm-sessions`.

### Task 3: Screen replay

**Files:**
- Create: `Sources/AgTermSessionKit/ScreenReplay.swift` (move the body of `Sources/AgTerm/Scrollback.swift` here as `ScreenReplay.history(_:)`; `Scrollback.capture` becomes a one-line call so restore keeps working)
- Test: `Tests/AgTermSessionKitTests/ScreenReplayTests.swift`

**Interfaces:**
- Produces: `public enum ScreenReplay { static func bytes(_ t: Terminal) -> Data; static func history(_ t: Terminal) -> String }`. `bytes` = `ESC c` (reset) + normal-buffer history and screen (as `history`) + if the alt buffer is active: `ESC[?1049h` + alt screen rows positioned with `ESC[r;1H` + modes (`?1h` app cursor keys, `?2004h` bracketed paste, mouse `?1000h`/`?1002h`/`?1003h` + `?1006h` when set, `?25l` if the cursor is hidden) + `ESC[row;colH` cursor + OSC 0 title if set. Task 2's server sends `bytes` as `replay`.

- [ ] **Step 1: Write failing tests**: each feeds a source `Terminal`, replays `bytes` into a fresh `Terminal` of the same size, and compares: `testPlainScreenAndCursorMatch` (text rows + cursor x/y equal), `testColorsSurvive` (SGR 31 cell's fg equal), `testAltScreenRestored` (`?1049h` + text → fresh terminal `isCurrentBufferAlternate` and same rows; normal-buffer history still above), `testModesRestored` (`?1h ?2004h ?1002h ?1006h ?25l` → `applicationCursor`, `bracketedPasteMode`, `mouseMode`, cursor hidden all equal), `testTitleRestored`.
- [ ] **Step 2:** run → fail. **Step 3:** implement. **Step 4:** `swift test --filter ScreenReplayTests` → pass, and the existing `swift test` stays green (restore uses the moved code).

### Task 4: App talks to the helper

**Files:**
- Create: `Sources/AgTerm/PtyLink.swift`, `Sources/AgTerm/SessionHelper.swift`
- Modify: `Sources/AgTerm/AgentTerminalView.swift` (subclass `TerminalView`, become its own `TerminalViewDelegate`, forward `send`/`sizeChanged` to `link`, keep the `onOutput`/`onInput`/`onBell` hooks), `Sources/AgTerm/TerminalSession.swift` (replace every `view.process.shellPid` / `view.process.childfd` with `view.link.shellPid` / `view.link.ptyFd`; `terminate()` calls `link.end()`)
- Test: `Tests/AgTermSessionKitTests/SessionServerTests.swift` gains `testVersionMismatchFallsBackToLocal` (via `SessionHelper.connect(socket:build:expectVersion: 2)` → nil)

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces:
  - `protocol PtyLink: AnyObject { var shellPid: pid_t { get }; var ptyFd: Int32 { get }; var sessionID: String? { get }; var onData: (([UInt8]) -> Void)? { get set }; var onExit: ((Int32?) -> Void)? { get set }; func write(_ bytes: ArraySlice<UInt8>); func resize(cols: Int, rows: Int); func end() /* HUP + SIGKILL after 2 s, as terminate() today */; func detach() }`
  - `final class HelperLink: PtyLink`: input and resize go straight to the passed fd (`write`, `ioctl(TIOCSWINSZ)`); output arrives as `output`/`replay` frames, delivered on the main queue through the same 4 MiB/1 MiB backpressure idea as `LocalProcess` (stop reading the socket past the high-water mark).
  - `final class LocalLink: PtyLink`: wraps SwiftTerm `LocalProcess`; `sessionID == nil`; `detach()` == `end()`.
  - `enum SessionHelper { static func shared() -> SessionHelper.Client?; }` where `Client` has `func list() -> [SessionInfo]`, `func spawn(_ r: SpawnRequest) throws -> HelperLink`, `func attach(id: String) throws -> HelperLink`. It finds the binary at `Bundle.main.executableURL!.deletingLastPathComponent()/agterm-sessions`, connects, and if refused, launches it detached (`posix_spawn` with `POSIX_SPAWN_SETSID`) with `--socket` and `--build <CFBundleVersion or "dev">`, then retries for 2 s. It returns nil on failure or version mismatch. When the helper reports a different build and `list()` is empty, it sends `shutdownIfIdle` and relaunches once.
  - `TerminalSession.init(cwd:restoring:command:)` spawns through `SessionHelper.shared()?.spawn` else `LocalLink`. New `TerminalSession.init(attaching info: SessionInfo, saved: SavedTab?)` attaches without feeding saved scrollback (the replay is authoritative) and without a pending resume command.

- [ ] **Step 1:** add the failing `testVersionMismatchFallsBackToLocal`; run → fail.
- [ ] **Step 2:** implement; run all tests → pass.
- [ ] **Step 3:** `swift build` then the existing self-tests unchanged: `AGTERM_FEATURE_CHECK=1 AGTERM_SELFTEST=<dir> .build/debug/AgTerm` (⌘K insert, agent tab, "closed tabs leave no processes behind") and `AGTERM_CD_CHECK=1` → same output as before this task.

### Task 5: Detach on quit, reattach on launch, packaging

**Files:**
- Modify: `Sources/AgTermCore/Restore.swift` (`SavedTab.sessionID: String?`, `decodeIfPresent`), `Sources/AgTerm/TerminalSession.swift` (`snapshot()` records `view.link.sessionID`), `Sources/AgTerm/MainWindowController.swift` (launch: `helper.list()`; saved tabs whose `sessionID` is listed → `init(attaching:)`, others → today's restore; listed sessions not in the save → appended tabs; quit: `detach()` every link instead of `terminate()`; closing a tab or the window still ends sessions), `Sources/AgTerm/AppDelegate.swift` (no "Still running" alert when every tab is helper-backed; add "Quit and End Sessions" ⌥⌘Q under the agterm menu that ends every link then quits), `Sources/AgTerm/SelfTest.swift` (new `AGTERM_PERSIST_CHECK`), `scripts/bundle.sh` (copy `"$BIN/agterm-sessions"` to `Contents/MacOS/agterm-sessions` and codesign it with the same identity/options before the app), `README.md` (one paragraph: tabs keep running when agterm quits or updates; ⌥⌘Q ends them).
- Test: `Tests/AgTermCoreTests/RestoreTests.swift` gains `testOldSaveWithoutSessionIDDecodes` and `testSessionIDRoundTrips`.

**Interfaces:**
- Consumes: Task 4's `PtyLink`, `SessionHelper`, `TerminalSession.init(attaching:saved:)`.

- [ ] **Step 1:** write the two failing Restore tests; run → fail; implement; run → pass.
- [ ] **Step 2:** write `AGTERM_PERSIST_CHECK` self-test, which prints these lines:
  - `persist: same shell after reattach: true` (open a tab, `echo PERSIST-$$`, simulate quit = save + `detach()` all + drop controller, build a new `MainWindowController`, compare shell pid, and find `PERSIST-<pid>` on screen)
  - `persist: typing works after reattach: true` (send `echo AFTER\r`, find `AFTER`)
  - `persist: orphan adopted: true` (spawn a session through the helper that isn't in the save → it appears as a tab)
  - `persist: exited session restored from save: true` (kill a session's shell while detached → the tab comes back from saved scrollback)
  - `persist: quit-and-end leaves no shells: true`
- [ ] **Step 3:** run `AGTERM_PERSIST_CHECK=1 AGTERM_SELFTEST=<dir> .build/debug/AgTerm` → all five lines `true`.
- [ ] **Step 4:** `scripts/bundle.sh` → `codesign --verify --deep --strict` passes. Manually: open the bundled app, start `claude` in a tab, quit with ⌘Q, `pgrep -f claude` still shows it, relaunch → same conversation on screen, still running.
