//! The full-screen interface: the agent runs on a worker thread, this thread draws and reads keys.

pub mod app;
pub mod view;
pub mod worker;

use app::{Action, App, Cmd, Event};
use ratatui::crossterm::event::{self, DisableBracketedPaste, EnableBracketedPaste, KeyCode, KeyEventKind, KeyModifiers};
use ratatui::crossterm::execute;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::channel;
use std::time::Duration;

const FRAME: Duration = Duration::from_millis(80);

/// True while the full screen is up, so a signal restores the terminal before exiting.
pub static ACTIVE: AtomicBool = AtomicBool::new(false);

/// Leaves the full screen: raw mode off, the normal screen back.
pub fn restore() {
    ACTIVE.store(false, Ordering::Relaxed);
    let _ = execute!(std::io::stdout(), DisableBracketedPaste);
    ratatui::restore();
}

/// Runs until the user quits. Returns the exit code.
pub fn run(st: crate::repl::State) -> i32 {
    let mut app = App::new(&st.cfg.model, &st.cfg.base_url, st.cfg.context_window);
    app.items = worker::history(&st);
    let (cmd_tx, cmd_rx) = channel::<Cmd>();
    let (ev_tx, ev_rx) = channel::<Event>();
    std::thread::spawn(move || worker::run(st, cmd_rx, ev_tx));

    // ratatui::init enters raw mode and the alternate screen, and restores them on panic.
    let mut term = ratatui::init();
    ACTIVE.store(true, Ordering::Relaxed);
    let _ = execute!(std::io::stdout(), EnableBracketedPaste);
    let mut tick = 0usize;
    let mut dirty = true;
    loop {
        while let Ok(e) = ev_rx.try_recv() {
            app.apply(e);
            dirty = true;
        }
        // The spinner needs frames while something runs; otherwise draw only on change.
        if dirty || app.busy || app.activity.is_some() {
            if term.draw(|f| view::draw(f, &app, tick)).is_err() {
                break;
            }
            tick = tick.wrapping_add(1);
            dirty = false;
        }
        if !event::poll(FRAME).unwrap_or(false) {
            continue;
        }
        dirty = true;
        let action = match event::read() {
            Ok(event::Event::Key(k)) if k.kind != KeyEventKind::Release => match (k.code, k.modifiers) {
                (KeyCode::Up, KeyModifiers::SHIFT) => {
                    app.scroll_by(1);
                    Action::None
                }
                (KeyCode::Down, KeyModifiers::SHIFT) => {
                    app.scroll_by(-1);
                    Action::None
                }
                _ => app.key(k),
            },
            Ok(event::Event::Paste(s)) => {
                app.paste(&s);
                Action::None
            }
            _ => Action::None,
        };
        match action {
            Action::None => {}
            Action::Cancel => crate::provider::CANCEL.store(true, Ordering::Relaxed),
            Action::Quit => break,
            Action::Cmd(c) => {
                if cmd_tx.send(c).is_err() {
                    break;
                }
            }
        }
    }
    // Stop a running turn or download, and let the turn kill its command before exiting.
    crate::repl::stop_turn();
    restore();
    0
}
