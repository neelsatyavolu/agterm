# agl: a coding agent CLI for local models

Working name `agl` ("agterm local"). Repo: `~/Documents/GitHub/agterm-local`. Rename freely.

## Why

Existing agent CLIs (Claude Code, Codex, Grok Build, Pi) are built around frontier hosted models. On local models (Qwen 3.6, Qwen2.5-Coder, Gemma 4 via Ollama, LM Studio, llama-server) they fail the same ways: the system prompt eats most of a small context window, tool calls come back in a format the harness doesn't parse, edits fail on exact-match whitespace, and the harness itself (Node, hundreds of MB of RSS) competes with the model for unified memory. agl is a small, fast harness tuned for those models, and it plugs cleanly into agterm.

## Goals

- Single native binary (Rust). Cold start under 20 ms, idle RSS under 15 MB, release binary under 5 MB.
- Works against any OpenAI-compatible endpoint; auto-detects Ollama (`:11434`), LM Studio (`:1234`) and llama-server (`:8080`) when no endpoint is configured.
- Tuned for local models:
  - System prompt under 600 tokens (Pi's approach: four tools, short rules).
  - Tool calls accepted in native `tool_calls`, Hermes/Qwen `<tool_call>{json}</tool_call>`, Qwen3-Coder `<function=name><parameter=k>v</parameter></function>`, and a fenced ```json {"name","arguments"}``` block.
  - Edits that survive local-model sloppiness: exact match first, then whitespace-normalized match, and a clear error that shows the closest lines when both fail.
  - Context budget from the model's real window (`num_ctx` / `/v1/models` / config): tool output truncated, old tool results elided before the window fills.
- Tools: `read`, `write`, `edit`, `bash`. Nothing else in phase 1.
- Sessions saved as JSONL (one event per line) so agterm can show them in its chat pane, timeline and phone app.
- `agl -p "<prompt>"` one-shot mode and an interactive line mode.

## Non-goals (phase 1)

- Hosted-model features: OAuth logins, usage limits, cloud sync, telemetry. None of these, ever, by default.
- MCP, subagents, hooks, skills, plugins.
- A full-screen TUI (phase 2, adapted from Grok Build's pager crates).
- Training or fine-tuning model weights (phase 3, optional, from collected sessions).

## Anti-goals

- Any network call other than to the configured model endpoint. Grok Build shipped a repo-upload path; nothing like that is copied over.
- Growing into a general framework. If a feature needs an abstraction layer, it waits.

## Sources

- Pi (`earendil-works/pi`, MIT): tool set, prompt shape, JSONL sessions. Design reference; TypeScript, so no code copied.
- Grok Build (`xai-org/grok-build`, Apache-2.0): Rust. Phase 1 may port `xai-grok-tools/src/implementations/grok_build_hashline/edit/` matching logic and `util/file_reader.rs` truncation; keep the Apache-2.0 header and add `THIRD-PARTY-NOTICES`. Phase 2 TUI comes from `xai-grok-pager*`.

## Phases

1. Core harness (this plan): config + endpoint detection, streaming client, tool-call parsing, four tools, agent loop with context budget, CLI, JSONL sessions.
2. agterm integration (`TimelineFeed.Agent.agl`, launch + resume, a `RemoteTimelineAgl` parser over the JSONL) and a TUI.
3. Tuning loop: an eval set of small coding tasks run per model to tune prompts and parsers; llama.cpp GBNF grammar for tool calls; optional LoRA on recorded sessions.

## Calls made without the user (check these)

- Rust from scratch rather than forking either project.
- "Fine-tuned" read as harness tuned for local models; weight training deferred to phase 3.
- Separate repo, not inside agterm.
- Blocking HTTP (`ureq`) and threads, no tokio, to keep the binary and build small.
