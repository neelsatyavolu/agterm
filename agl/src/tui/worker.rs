//! The thread that runs the agent, model switches and downloads for the interface.

use super::app::{Choice, Cmd, Event};
use crate::agent::Ui;
use crate::config;
use crate::message::{Role, ToolCall};
use crate::models::{self, Pick, catalog, discover, serve, store};
use crate::provider::CANCEL;
use crate::repl::{self, State};
use crate::tools::ToolResult;
use std::sync::atomic::Ordering;
use std::sync::mpsc::{Receiver, Sender};
use std::time::{Duration, Instant};

/// Sends what the agent does to the interface.
struct ChannelUi<'a>(&'a Sender<Event>);

impl Ui for ChannelUi<'_> {
    fn text(&mut self, s: &str) {
        let _ = self.0.send(Event::Text(s.into()));
    }
    fn reasoning(&mut self, s: &str) {
        let _ = self.0.send(Event::Reasoning(s.into()));
    }
    fn tool_start(&mut self, c: &ToolCall) {
        let _ = self.0.send(Event::ToolStart(crate::ui::summary(c)));
    }
    fn tool_end(&mut self, _c: &ToolCall, r: &ToolResult) {
        let _ = self.0.send(Event::ToolEnd { ok: r.ok, output: r.output.clone() });
    }
}

/// Runs commands until the interface hangs up.
pub fn run(mut st: State, rx: Receiver<Cmd>, tx: Sender<Event>) {
    for cmd in rx {
        handle(&mut st, cmd, &tx);
    }
}

pub fn handle(st: &mut State, cmd: Cmd, tx: &Sender<Event>) {
    let send = |e| {
        let _ = tx.send(e);
    };
    match cmd {
        Cmd::Send(text) => {
            let chat = st.cfg.clone();
            let r = repl::turn(st, &chat, &mut ChannelUi(tx), &text);
            send(Event::TurnDone(r.map_err(|e| e.to_string())));
        }
        Cmd::Clear => match repl::new_session(st) {
            Ok(()) => send(Event::Cleared),
            Err(e) => send(Event::Error(format!("cannot start a new session: {e}"))),
        },
        Cmd::ListModels => {
            send(Event::Busy("listing models…".into()));
            send(Event::Models(choices(&discover::all())));
            send(Event::Idle);
        }
        Cmd::UseModel(name) => {
            if let Err(e) = use_model(st, &name, tx) {
                send(Event::Error(e));
            }
            send(Event::Idle);
        }
        Cmd::Pull(name) => {
            match pull(&name, tx) {
                Ok(()) => {
                    send(Event::Note(format!("downloaded {name}")));
                    if let Err(e) = use_model(st, &name, tx) {
                        send(Event::Error(e));
                    }
                }
                Err(e) => send(Event::Error(e)),
            }
            send(Event::Idle);
        }
    }
}

/// The picker's rows: installed models, then catalog models not yet downloaded.
pub fn choices(installed: &[discover::Installed]) -> Vec<Choice> {
    let mut v: Vec<Choice> = installed
        .iter()
        .map(|m| Choice { name: m.name.clone(), detail: format!("{} · {}", m.source.label(), models::size(m.bytes)), download: false })
        .collect();
    for e in &catalog::CATALOG {
        if !installed.iter().any(|m| m.source == discover::Source::Agl && m.name == e.name) {
            v.push(Choice { name: e.name.into(), detail: format!("download · {:.1} GB · {}", e.size_gb, e.about), download: true });
        }
    }
    v
}

fn use_model(st: &mut State, name: &str, tx: &Sender<Event>) -> Result<(), String> {
    let _ = tx.send(Event::Busy(format!("starting {name}…")));
    CANCEL.store(false, Ordering::Relaxed);
    let (base_url, model) = if let Some(url) = config::serving(&config::DEFAULT_CANDIDATES, name) {
        (url, name.to_string())
    } else if models::is_live(&st.cfg.base_url) && config::serving(&[st.cfg.base_url.as_str()], name).is_some() {
        (st.cfg.base_url.clone(), name.to_string())
    } else {
        let installed = discover::all();
        match models::pick(name, false, &installed) {
            Pick::Installed(m) => {
                // One private server at a time.
                serve::stop();
                (models::prepare(m, &serve::Runtimes::default(), &models::is_live)?, m.name.clone())
            }
            Pick::NotDownloaded(e) => return Err(format!("{} isn't downloaded yet; pick it in /models to download it", e.name)),
            Pick::Served | Pick::Unknown => return Err(format!("no model called {name}; /models lists them")),
        }
    };
    st.cfg.base_url = base_url;
    repl::set_model(st, &model);
    st.cfg.context_window = config::detect_context(&st.cfg.base_url, &model).unwrap_or(models::LLAMA_CONTEXT);
    let _ = tx.send(Event::ModelChanged { model, base_url: st.cfg.base_url.clone(), context: st.cfg.context_window });
    Ok(())
}

fn pull(name: &str, tx: &Sender<Event>) -> Result<(), String> {
    let entry = catalog::find(name).ok_or_else(|| format!("no model called {name} to download"))?;
    let dest = store::path_for(&store::dir(), name);
    if dest.exists() {
        return Ok(());
    }
    CANCEL.store(false, Ordering::Relaxed);
    let mut last = Instant::now() - Duration::from_secs(1);
    let mut progress = |done: u64, total: Option<u64>| {
        if last.elapsed() < Duration::from_millis(200) {
            return;
        }
        last = Instant::now();
        let of = total.map(|t| format!(" of {} ({}%)", models::size(t), done * 100 / t.max(1))).unwrap_or_default();
        let _ = tx.send(Event::Busy(format!("downloading {name}: {}{of} · Esc to stop", models::size(done))));
    };
    store::pull(&entry.url(), &dest, &CANCEL, &mut progress)
}

/// The conversation so far, for a resumed session.
pub fn history(st: &State) -> Vec<super::app::Item> {
    use super::app::Item;
    let mut items = Vec::new();
    for m in &st.msgs {
        match m.role {
            Role::User => items.push(Item::User(m.content.clone())),
            Role::Assistant => {
                if !m.content.trim().is_empty() {
                    items.push(Item::Assistant(m.content.clone()));
                }
                for c in &m.tool_calls {
                    items.push(Item::Tool { summary: crate::ui::summary(c), ok: Some(true), preview: Vec::new(), more: 0 });
                }
            }
            Role::System | Role::Tool => {}
        }
    }
    items
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::message::Message;
    use crate::session::Session;
    use crate::testutil;
    use std::path::Path;
    use std::sync::mpsc::channel;

    fn state(dir: &Path, base_url: &str) -> State {
        let cfg = config::Config {
            base_url: base_url.into(),
            model: "stub".into(),
            api_key: None,
            context_window: 32_768,
            bash_timeout_secs: 5,
            temperature: 0.2,
        };
        let session = Session::create(&dir.join("sessions"), dir, "stub", base_url).unwrap();
        let ctx = crate::tools::ToolCtx { cwd: dir.to_path_buf(), bash_timeout: Duration::from_secs(5) };
        State { cfg, ctx, msgs: vec![Message::new(Role::System, "sys")], session, system: "sys".into(), max_steps: 5 }
    }

    fn drain(rx: &Receiver<Event>) -> Vec<Event> {
        rx.try_iter().collect()
    }

    #[test]
    fn send_streams_events_and_ends_the_turn() {
        let d = tempfile::tempdir().unwrap();
        let stub = testutil::serve(
            "text/event-stream",
            "data: {\"choices\":[{\"delta\":{\"content\":\"hi there\"}}]}\n\ndata: [DONE]\n\n".into(),
        );
        let mut st = state(d.path(), &stub.base);
        let (tx, rx) = channel();
        handle(&mut st, Cmd::Send("hello".into()), &tx);
        let ev = drain(&rx);
        assert_eq!(ev.first(), Some(&Event::Text("hi there".into())));
        assert_eq!(ev.last(), Some(&Event::TurnDone(Ok(()))));
        let log = std::fs::read_to_string(&st.session.path).unwrap();
        assert!(log.contains("\"hello\"") && log.contains("hi there"), "{log}");
    }

    #[test]
    fn a_failed_turn_reports_the_error() {
        let d = tempfile::tempdir().unwrap();
        let mut st = state(d.path(), &format!("{}/v1", testutil::dead_url()));
        let (tx, rx) = channel();
        handle(&mut st, Cmd::Send("hello".into()), &tx);
        match drain(&rx).last() {
            Some(Event::TurnDone(Err(e))) => assert!(e.contains("cannot reach"), "{e}"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn clear_starts_a_new_session() {
        let d = tempfile::tempdir().unwrap();
        let mut st = state(d.path(), "http://x/v1");
        st.msgs.push(Message::new(Role::User, "old"));
        let before = st.session.path.clone();
        let (tx, rx) = channel();
        std::thread::sleep(Duration::from_millis(1_100));
        handle(&mut st, Cmd::Clear, &tx);
        assert_eq!(drain(&rx), vec![Event::Cleared]);
        assert_eq!(st.msgs.len(), 1);
        assert_ne!(st.session.path, before);
        assert!(st.session.path.starts_with(d.path()), "stays out of the real ~/.agl");
        assert!(d.path().join("run").join(format!("{}.json", std::process::id())).exists());
    }

    #[test]
    fn switching_to_a_model_the_current_server_lists() {
        let d = tempfile::tempdir().unwrap();
        let stub = testutil::serve("application/json", r#"{"data":[{"id":"stub"},{"id":"other-model-xyz"}]}"#.into());
        let mut st = state(d.path(), &stub.base);
        let (tx, rx) = channel();
        handle(&mut st, Cmd::UseModel("other-model-xyz".into()), &tx);
        let ev = drain(&rx);
        assert!(ev.iter().any(|e| matches!(e, Event::ModelChanged { model, .. } if model == "other-model-xyz")), "{ev:?}");
        assert_eq!(ev.last(), Some(&Event::Idle));
        assert_eq!(st.cfg.model, "other-model-xyz");
        assert!(std::fs::read_to_string(&st.session.path).unwrap().contains("\"type\":\"model\""));
    }

    #[test]
    fn unknown_and_undownloaded_models_are_errors() {
        let d = tempfile::tempdir().unwrap();
        let mut st = state(d.path(), &format!("{}/v1", testutil::dead_url()));
        let (tx, rx) = channel();
        handle(&mut st, Cmd::UseModel("definitely-not-a-model".into()), &tx);
        assert!(drain(&rx).iter().any(|e| matches!(e, Event::Error(m) if m.contains("no model called"))));
        assert_eq!(st.cfg.model, "stub", "unchanged");
    }

    #[test]
    fn choices_list_installed_then_downloads() {
        let installed = vec![discover::Installed {
            name: "qwen3-4b".into(),
            source: discover::Source::Agl,
            bytes: 2_500_000_000,
            path: Some("/m".into()),
        }];
        let c = choices(&installed);
        assert_eq!(c[0], Choice { name: "qwen3-4b".into(), detail: "agl · 2.5 GB".into(), download: false });
        assert!(c[1..].iter().all(|c| c.download && c.name != "qwen3-4b"));
        assert_eq!(c.len(), catalog::CATALOG.len());
    }

    #[test]
    fn history_shows_a_resumed_conversation() {
        let d = tempfile::tempdir().unwrap();
        let mut st = state(d.path(), "u");
        st.msgs.push(Message::new(Role::User, "fix it"));
        let mut a = Message::new(Role::Assistant, "ok");
        a.tool_calls.push(ToolCall { id: "c".into(), name: "read".into(), arguments: serde_json::json!({"path": "a.py"}) });
        st.msgs.push(a);
        st.msgs.push(Message::tool_result("c", "1\tx"));
        let items = history(&st);
        assert_eq!(items.len(), 3);
        assert!(matches!(&items[2], super::super::app::Item::Tool { summary, .. } if summary == "read a.py"));
    }
}
