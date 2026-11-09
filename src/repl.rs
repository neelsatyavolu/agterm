//! One-shot and interactive modes.

use crate::agent::{self, AgentError, AgentOpts};
use crate::config::Config;
use crate::message::{Message, Role};
use crate::provider::{CANCEL, ProviderError};
use crate::session::{self, Session};
use crate::tools::ToolCtx;
use crate::ui::{Recorder, Term};
use serde_json::json;
use std::io::{BufRead, Write};
use std::sync::atomic::{AtomicBool, Ordering};

/// True while a turn runs, so Ctrl-C cancels the turn instead of quitting.
pub static RUNNING: AtomicBool = AtomicBool::new(false);

pub struct State {
    pub cfg: Config,
    pub ctx: ToolCtx,
    pub msgs: Vec<Message>,
    pub session: Session,
    pub system: String,
    pub max_steps: u32,
}

/// Exit code for a finished turn: 0 ok, 1 agent error, 2 endpoint unreachable.
pub fn exit_code(r: &Result<(), AgentError>) -> i32 {
    match r {
        Ok(()) => 0,
        Err(AgentError::Provider(ProviderError::Unreachable { .. })) => 2,
        Err(_) => 1,
    }
}

/// Sends one user message and runs the agent until it answers.
pub fn send(st: &mut State, term: &mut Term, text: &str) -> Result<(), AgentError> {
    let r = turn(st, &st.cfg.clone(), term, text);
    if let Err(e) = &r {
        eprintln!("agl: {e}");
    }
    r
}

/// One user turn against `chat`, recorded in the session; errors are logged, not printed.
pub fn turn(st: &mut State, chat: &dyn agent::Chat, out: &mut dyn agent::Ui, text: &str) -> Result<(), AgentError> {
    st.session.log("user", json!({"text": text}));
    st.msgs.push(Message::new(Role::User, text));
    let opts = AgentOpts { max_steps: st.max_steps, context_window: st.cfg.context_window };
    CANCEL.store(false, Ordering::Relaxed);
    RUNNING.store(true, Ordering::Relaxed);
    let mut ui = Recorder { term: out, session: &mut st.session };
    let r = agent::run_turn(chat, &mut st.msgs, &st.ctx, &mut ui, &opts);
    RUNNING.store(false, Ordering::Relaxed);
    if let Err(e) = &r {
        st.session.log("error", json!({"message": e.to_string()}));
    }
    r
}

/// Reads prompts from stdin until EOF or `/exit`.
pub fn interactive(st: &mut State, term: &mut Term) -> i32 {
    println!("agl · {} · {}  (/exit, /clear, /model NAME; Ctrl-C stops a turn)", st.cfg.model, st.cfg.base_url);
    let stdin = std::io::stdin();
    let mut line = String::new();
    loop {
        print!("\n› ");
        let _ = std::io::stdout().flush();
        line.clear();
        if stdin.lock().read_line(&mut line).unwrap_or(0) == 0 {
            return 0;
        }
        let input = line.trim();
        match input {
            "" => continue,
            "/exit" | "/quit" => return 0,
            "/clear" => {
                if let Err(e) = clear(st) {
                    eprintln!("agl: cannot start a new session: {e}");
                }
                continue;
            }
            _ if input.starts_with("/model ") => {
                set_model(st, input["/model ".len()..].trim());
                println!("model: {}", st.cfg.model);
                continue;
            }
            _ => {}
        }
        if let Err(AgentError::Provider(ProviderError::Unreachable { .. })) = send(st, term, input) {
            return 2;
        }
    }
}

fn clear(st: &mut State) -> std::io::Result<()> {
    new_session(st)?;
    println!("new session {}", st.session.id);
    Ok(())
}

/// Forgets the conversation and starts a new session file next to the current one.
pub fn new_session(st: &mut State) -> std::io::Result<()> {
    // Sessions live in <root>/<folder>/<file>.
    let root = st.session.path.parent().and_then(|p| p.parent()).map_or_else(session::default_root, |p| p.to_path_buf());
    st.msgs = vec![Message::new(Role::System, st.system.clone())];
    st.session = Session::create(&root, &st.ctx.cwd, &st.cfg.model, &st.cfg.base_url)?;
    session::write_pointer(&root, std::process::id(), &st.session.path);
    Ok(())
}

/// Switches model and records it in the session.
pub fn set_model(st: &mut State, name: &str) {
    st.cfg.model = name.to_string();
    st.session.log("model", json!({"name": name}));
}

/// Cancels the running turn and waits up to two seconds for it to stop, so the command it
/// was running is killed before agl exits.
pub fn stop_turn() {
    CANCEL.store(true, Ordering::Relaxed);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
    while RUNNING.load(Ordering::Relaxed) && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

/// Removes this process's run pointer and stops servers agl started; call before exiting.
pub fn finish() {
    session::remove_pointer(&session::default_root(), std::process::id());
    crate::models::serve::stop();
}
