mod agent;
mod budget;
mod cli;
mod config;
mod message;
mod models;
mod prompt;
mod provider;
mod repl;
mod session;
mod sse;
mod toolcall;
mod tools;
mod tui;
mod ui;
#[cfg(test)]
mod testutil;

use clap::{Parser, Subcommand};
use message::{Message, Role};
use session::Session;
use std::io::IsTerminal;
use std::process::exit;
use std::sync::atomic::Ordering;
use std::time::Duration;

/// A small, fast coding agent for local models.
#[derive(Parser)]
#[command(version)]
struct Args {
    #[command(subcommand)]
    cmd: Option<Cmd>,
    /// Run one prompt and exit.
    #[arg(short = 'p', long)]
    prompt: Option<String>,
    /// Model name (default: the server's first model).
    #[arg(long)]
    model: Option<String>,
    /// OpenAI-compatible base URL, e.g. http://127.0.0.1:11434/v1.
    #[arg(long)]
    base_url: Option<String>,
    /// Continue the newest session in this folder, or the one with this id.
    #[arg(long, num_args = 0..=1, default_missing_value = "")]
    resume: Option<String>,
    /// Print the resolved settings and exit.
    #[arg(long)]
    print_config: bool,
    /// Use the plain line-by-line chat instead of the full-screen interface.
    #[arg(long)]
    plain: bool,
    /// Stop a turn after this many model calls.
    #[arg(long, default_value_t = 50)]
    max_steps: u32,
}

#[derive(Subcommand)]
enum Cmd {
    /// List installed models (agl, LM Studio, Ollama) and the ones agl can download.
    Models,
    /// Download a model: a name from `agl models`, or hf:OWNER/REPO/FILE.gguf.
    Pull { name: String },
    /// Delete a model agl downloaded.
    Rm { name: String },
}

fn main() {
    let args = Args::parse();
    let _ = ctrlc::set_handler(|| {
        // In full screen Ctrl-C is a key, so a signal here is SIGTERM, SIGHUP or a kill: quit.
        if tui::ACTIVE.load(Ordering::Relaxed) {
            repl::stop_turn();
            tui::restore();
            repl::finish();
            exit(130);
        }
        // First Ctrl-C in a turn cancels it; a second one, or one at the prompt, quits.
        if repl::RUNNING.load(Ordering::Relaxed) && !provider::CANCEL.swap(true, Ordering::Relaxed) {
            eprintln!("\nagl: stopping… (Ctrl-C again to quit)");
        } else {
            repl::finish();
            exit(130);
        }
    });
    match &args.cmd {
        Some(Cmd::Models) => exit(cli::list()),
        Some(Cmd::Pull { name }) => exit(cli::pull(name)),
        Some(Cmd::Rm { name }) => exit(cli::rm(name)),
        None => {}
    }
    let given = config::Overrides { base_url: args.base_url.clone(), model: args.model.clone(), api_key: None };
    let overrides = cli::resolve(given).unwrap_or_else(|e| {
        eprintln!("agl: {e}");
        repl::finish();
        exit(1)
    });
    let cfg = config::load(config::default_path().as_deref(), overrides).unwrap_or_else(|e| {
        eprintln!("agl: {e}");
        repl::finish();
        exit(2)
    });
    if args.print_config {
        println!("base_url = {}\nmodel = {}\ncontext_window = {}", cfg.base_url, cfg.model, cfg.context_window);
        return;
    }
    let mut st = start(cfg, &args).unwrap_or_else(|e| {
        eprintln!("agl: {e}");
        repl::finish();
        exit(1)
    });
    models::release::note(&st.cfg.base_url, &st.cfg.model);
    repl::point(&st);
    let full_screen = !args.plain && std::io::stdin().is_terminal() && std::io::stdout().is_terminal();
    let mut term = ui::Term::new();
    let code = match &args.prompt {
        Some(p) => repl::exit_code(&repl::send(&mut st, &mut term, p)),
        None if full_screen => tui::run(st),
        None => repl::interactive(&mut st, &mut term),
    };
    repl::finish();
    exit(code);
}

/// Builds the prompt and opens (or resumes) the session.
fn start(cfg: config::Config, args: &Args) -> Result<repl::State, String> {
    let cwd = std::env::current_dir().map_err(|e| format!("no working directory: {e}"))?;
    let system = prompt::system(&cwd, &prompt::project_files(&cwd));
    let root = session::default_root();
    let (session, msgs) = match &args.resume {
        Some(id) => {
            let id = Some(id.as_str()).filter(|s| !s.is_empty());
            let path = session::find(&root, &cwd, id).ok_or("no session to resume in this folder")?;
            let events = session::load(&path).map_err(|e| e.to_string())?;
            (Session::append_to(&path).map_err(|e| e.to_string())?, session::rebuild(&events, system.clone()))
        }
        None => (
            Session::create(&root, &cwd, &cfg.model, &cfg.base_url).map_err(|e| format!("cannot create session: {e}"))?,
            vec![Message::new(Role::System, system.clone())],
        ),
    };
    let ctx = tools::ToolCtx { cwd, bash_timeout: Duration::from_secs(cfg.bash_timeout_secs) };
    Ok(repl::State { cfg, ctx, msgs, session, system, max_steps: args.max_steps })
}
