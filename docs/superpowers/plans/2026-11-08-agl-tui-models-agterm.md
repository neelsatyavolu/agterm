# agl phase 2: full-screen interface, model library, agterm integration

> Executed inline (superpowers:executing-plans). Tuning (phase 3) is on hold.

**Goal:** agl opens full screen by default, can download and run models itself while still
using what Ollama and LM Studio already have, and agterm treats agl like Claude, Codex and Grok:
it starts it from the menu, shows its conversation in the Chat view and on the phone, and resumes it.

**Spec:** `docs/superpowers/specs/2026-11-08-agl-design.md` (phase 2), plus the calls below
(the user skipped the questions).

## Calls made (user skipped questions)
- TUI: ratatui + crossterm. Full screen when stdin and stdout are terminals and `-p` isn't given;
  `--plain` keeps the line chat. Binary must stay under 5 MB.
- Keys: Enter sends, Alt+Enter / Shift+Enter newline, Esc or Ctrl-C stops a turn, Ctrl-C at an
  idle prompt or Ctrl-D quits, PgUp/PgDn/mouse wheel scroll, `/models` picker, `/clear`, `/exit`.
- The agent runs on a worker thread; it talks to the UI over channels.
- Model library: `~/.agl/models/*.gguf`. A built-in catalog of five coding models (Hugging Face
  files checked to exist on 2026-11-08). `agl models`, `agl pull NAME|hf:owner/repo/file.gguf`, `agl rm NAME`.
- Installed models: Ollama (server `/api/tags`), LM Studio (`~/.lmstudio/models/**.gguf`), agl's own.
  A model a running server lists is used through that server; a GGUF file (agl's or LM Studio's)
  with no server gets a private `llama-server --jinja` agl starts and stops.
- Downloads are the only network calls besides the model endpoint, and only when asked for.
- agterm integration: agl writes `~/.agl/run/<pid>.json` (`{"session": path}`), updated on
  `/clear`, removed on exit. agterm reads it for the tab's foreground process group to find the
  transcript: exact, handles `/clear` and two tabs in one folder. Events gain `ts` (ms).
- agterm: `AgentKind` "agl", `TimelineFeed.Agent.agl`, `AglTimeline` parser, `TranscriptFollower`
  locate, `--resume` to bring a tab back, a CHANGELOG bullet. Work in an agterm worktree on branch
  `agl-integration`. Session Timeline (the turns side panel) is out of scope.

## Tasks
1. **Session extras** (agl): `ts` on every event, `model` event on switch, run pointer file
   written/updated/removed. Tests: event has ts; pointer written, updated by clear, removed.
2. **Model library** (agl): `src/models/{mod,catalog,store,discover,serve}.rs`; `agl models|pull|rm`;
   `--model` resolution (server list → local GGUF via llama-server → catalog hint). Tests: catalog
   lookup, store list/rm, HTTP download with resume against a local test server, Ollama/LM Studio
   discovery from fixture dirs/servers, resolution order, llama-server argv.
3. **TUI** (agl): `src/tui/{app,view,worker,mod}.rs`. Pure state (`App::apply(Event)`,
   `App::key(KeyEvent) -> Action`) and rendering tested with ratatui `TestBackend`; worker tested
   with the scripted `Chat`. Model picker (installed + catalog), download progress.
4. **agterm** (Swift): parser + wiring + tests (`AglTimelineTests`), CHANGELOG.
5. Real-model check: TUI driven in a pty against LM Studio; agterm parser fed a real agl session.

## Review Focus
- Terminal left in raw mode / alternate screen after a panic or error exit.
- Ctrl-C in raw mode is a key, not SIGINT: it must still stop bash and the stream.
- A download interrupted midway resumes, and a partial file is never listed as a model.
- llama-server child killed on every exit path (quit, error, Ctrl-C).
- Two agl tabs in one folder each show their own conversation in agterm.
