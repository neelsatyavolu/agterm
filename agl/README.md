# agl

A small, fast coding agent for local models: Ollama, LM Studio, llama-server, or any OpenAI-compatible endpoint. One native binary, four tools (read, write, edit, bash), a system prompt under 600 tokens.

## Use

```sh
cargo build --release
target/release/agl                       # full screen
target/release/agl --plain               # line-by-line chat
target/release/agl -p "fix the failing test"
target/release/agl --resume              # continue this folder's newest session
target/release/agl --print-config        # show endpoint and model
```

With no settings, agl looks for a server on ports 11434 (Ollama), 1234 and 1235 (LM Studio) and 8080 (llama-server). If you name a model, it picks the server that has it; otherwise it uses a loaded model that can call tools.

Settings, highest first: flags (`--base-url`, `--model`), env (`AGL_BASE_URL`, `AGL_MODEL`, `AGL_API_KEY`), then `~/.config/agl/config.toml`:

```toml
base_url = "http://127.0.0.1:11434/v1"
model = "qwen3-coder:30b"
context_window = 32768   # tokens; also sent to Ollama as num_ctx
bash_timeout_secs = 120
temperature = 0.2
```

Commands: `/models` (pick or download a model), `/model NAME`, `/clear` (new session), `/help`, `/exit`. Type `/` to see them with what each does; Up/Down choose, Tab completes, Enter runs.

Keys in full screen: Enter sends, Alt+Enter or Ctrl-J adds a line, Esc or Ctrl-C stops a turn or download, Ctrl-C on an empty box quits, Up/Down recall sent messages, PgUp/PgDn and Shift+Up/Down scroll.

## Models

```sh
agl models                 # installed (agl, LM Studio, Ollama) and downloadable
agl pull qwen3-coder-30b   # or hf:OWNER/REPO/FILE.gguf
agl --model qwen3-coder-30b
agl rm qwen3-coder-30b
```

When agl exits, or you switch models, it unloads any model it made Ollama or LM Studio load, unless another running agl is using it; a model that was loaded before agl started stays loaded. Servers agl starts stop with it, even if agl is killed.

A model a running server lists is used there. Otherwise agl starts what it needs: Ollama (`ollama serve`) or LM Studio (`lms server start`) for their models, and its own `llama-server --jinja` for GGUF files it downloaded to `~/.agl/models` (install with `brew install llama.cpp`). Servers agl starts stop when it exits; LM Studio keeps its own. With no server running and no model named, agl starts its first downloaded model. Downloads resume where they stopped.

## What it does for local models

- Accepts tool calls as native `tool_calls`, Hermes/Qwen `<tool_call>{json}</tool_call>`, Qwen3-Coder `<function=…><parameter=…>` XML, or a fenced JSON block.
- Splits `<think>` blocks and `reasoning_content` from the answer.
- Edits match exactly, then ignoring indentation style and trailing spaces; a miss shows the closest lines.
- Tool output is capped at 2,000 lines / 30,000 chars. Near the context window, the oldest tool results are elided first.
- The same call three times in a row gets a note telling the model to change course.
- No network calls except to the model server, and to Hugging Face when you download a model.

## Sessions

Each session is a JSONL file in `~/.agl/sessions/<cwd-slug>/<YYYYMMDDTHHMMSSZ>-<id>.jsonl` (`AGL_HOME` moves `~/.agl`). One event per line, flushed as written. This is the format agterm reads.

| `type` | Fields |
|--------|--------|
| `session` | `id`, `cwd`, `model`, `base_url`, `started` (ISO 8601 UTC) |
| `user` | `text` |
| `assistant` | `text`, `reasoning` |
| `tool_call` | `id`, `name`, `arguments` (object) |
| `tool_result` | `id`, `ok`, `output` |
| `error` | `message` |
| `model` | `name` (after `/model`) |

Every event also has `ts`, milliseconds since 1970. While agl runs, `~/.agl/run/<pid>.json` holds `{"session": "<path>"}`; agterm reads it to show the conversation of the agl in a tab.

## Numbers (M5 Max, release build)

| | agl | Pi 0.84 |
|---|---|---|
| Binary | 2.1 MB | 18 MB bundle + Node |
| `--version` cold | 4.4 ms median | 159 ms |
| Peak RSS (`--print-config`) | 7 MB | |

End-to-end (`AGL_E2E=1 cargo test --release --test e2e`): with LM Studio's `qwen3.8-27b-splash`, agl reads a buggy `add.py`, fixes it, runs it and reports in 8.3 s.

## Tests

```sh
cargo test                                         # unit + CLI tests (stub server)
AGL_E2E=1 AGL_MODEL=<model> cargo test --release --test e2e
```

Design: `docs/superpowers/specs/2026-11-08-agl-design.md`. Third-party notices: `THIRD-PARTY-NOTICES`.
