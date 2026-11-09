//! What the full-screen interface shows and how keys change it. No terminal I/O here.

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use serde_json::Value;
use std::time::Instant;

const TOOL_PREVIEW_LINES: usize = 5;

/// A slash command and what it does, as the `/` menu shows it.
#[derive(Debug, PartialEq)]
pub struct Command {
    pub name: &'static str,
    pub about: &'static str,
    /// Takes an argument, so choosing it fills in the name instead of running it.
    pub arg: bool,
}

pub const COMMANDS: [Command; 6] = [
    Command { name: "/models", about: "Pick a model, or download one", arg: false },
    Command { name: "/model", about: "Switch to a model by name", arg: true },
    Command { name: "/clear", about: "Start a new conversation", arg: false },
    Command { name: "/help", about: "Keys and commands", arg: false },
    Command { name: "/exit", about: "Quit agl", arg: false },
    Command { name: "/quit", about: "Quit agl", arg: false },
];

const HELP: &str = "Commands
  /models          pick a model, or download one
  /model NAME      switch to a model by name
  /clear           start a new conversation
  /exit            quit
Keys
  Enter            send          Alt+Enter, Ctrl-J   new line
  Esc              stop a reply, download or model load
  Up / Down        earlier messages
  PgUp / PgDn      scroll        Shift+Up / Down      scroll a line
  Ctrl-C           clear the box, or quit when it's empty";

/// One block of the conversation.
#[derive(Debug, Clone, PartialEq)]
pub enum Item {
    User(String),
    Assistant(String),
    Reasoning(String),
    /// A tool call; `ok` is None while it runs. `preview` is the start of its output.
    Tool { name: String, args: Value, ok: Option<bool>, preview: Vec<String>, more: usize },
    /// agl's own messages: errors, model switches, download progress.
    Note { text: String, error: bool },
}

/// A row in the model picker.
#[derive(Debug, Clone, PartialEq)]
pub struct Choice {
    pub name: String,
    /// "LM Studio · 17.4 GB", or "download · 18.6 GB".
    pub detail: String,
    pub download: bool,
}

/// From the worker thread.
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    Text(String),
    Reasoning(String),
    ToolStart { name: String, args: Value },
    ToolEnd { ok: bool, output: String },
    /// The turn ended; `Err` carries the message to show.
    TurnDone(Result<(), String>),
    Note(String),
    Error(String),
    /// Download progress or model loading, shown in the status line until `Idle`.
    Busy(String),
    Idle,
    Models(Vec<Choice>),
    ModelChanged { model: String, base_url: String, context: u32 },
    Cleared,
    /// The conversation's estimated size in tokens.
    Usage(u32),
}

/// To the worker thread.
#[derive(Debug, Clone, PartialEq)]
pub enum Cmd {
    Send(String),
    Clear,
    ListModels,
    UseModel(String),
    Pull(String),
}

#[derive(Debug, PartialEq)]
pub enum Action {
    None,
    Cmd(Cmd),
    /// Stop the running turn or download.
    Cancel,
    Quit,
}

pub struct Picker {
    pub choices: Vec<Choice>,
    pub selected: usize,
}

pub struct App {
    pub items: Vec<Item>,
    pub input: String,
    /// Byte offset of the cursor in `input`.
    pub cursor: usize,
    /// Lines scrolled up from the bottom of the conversation.
    pub scroll: usize,
    pub model: String,
    pub base_url: String,
    pub context: u32,
    /// A turn is running.
    pub busy: bool,
    /// What the status line says while something runs.
    pub activity: Option<String>,
    pub cancelling: bool,
    pub picker: Option<Picker>,
    /// `/models` was asked for and nothing typed since, so the list may open when it arrives.
    awaiting_models: bool,
    history: Vec<String>,
    /// Position while stepping through `history` with Up/Down.
    recall: Option<usize>,
    /// The streaming assistant/reasoning block belongs to the current model call.
    streaming: bool,
    /// The highlighted row of the `/` menu.
    pub slash_sel: usize,
    /// Estimated tokens in the conversation.
    pub tokens: u32,
    /// When the running turn, download or load started.
    pub since: Option<Instant>,
    /// The folder agl works in, for the welcome card.
    pub cwd: String,
}

impl App {
    pub fn new(model: &str, base_url: &str, context: u32) -> Self {
        Self {
            items: Vec::new(),
            input: String::new(),
            cursor: 0,
            scroll: 0,
            model: model.into(),
            base_url: base_url.into(),
            context,
            busy: false,
            activity: None,
            cancelling: false,
            picker: None,
            awaiting_models: false,
            history: Vec::new(),
            recall: None,
            streaming: false,
            slash_sel: 0,
            tokens: 0,
            since: None,
            cwd: String::new(),
        }
    }

    /// Applies an event from the worker.
    pub fn apply(&mut self, e: Event) {
        match e {
            Event::Text(t) => match self.items.last_mut() {
                Some(Item::Assistant(s)) if self.streaming => s.push_str(&t),
                _ => {
                    self.items.push(Item::Assistant(t));
                    self.streaming = true;
                }
            },
            Event::Reasoning(t) => match self.items.last_mut() {
                Some(Item::Reasoning(s)) if self.streaming => s.push_str(&t),
                _ => {
                    self.items.push(Item::Reasoning(t));
                    self.streaming = true;
                }
            },
            Event::ToolStart { name, args } => {
                self.streaming = false;
                self.items.push(Item::Tool { name, args, ok: None, preview: Vec::new(), more: 0 });
            }
            Event::ToolEnd { ok: done, output } => {
                let open = self.items.iter_mut().rev().find_map(|i| match i {
                    Item::Tool { ok, preview, more, .. } if ok.is_none() => Some((ok, preview, more)),
                    _ => None,
                });
                if let Some((ok, preview, more)) = open {
                    let lines: Vec<&str> = output.lines().collect();
                    *ok = Some(done);
                    *preview = lines.iter().take(TOOL_PREVIEW_LINES).map(|l| l.to_string()).collect();
                    *more = lines.len().saturating_sub(TOOL_PREVIEW_LINES);
                }
            }
            Event::TurnDone(r) => {
                self.busy = false;
                self.cancelling = false;
                self.streaming = false;
                self.activity = None;
                self.since = None;
                if let Err(text) = r {
                    self.items.push(Item::Note { text, error: true });
                }
            }
            Event::Note(text) => self.note(text, false),
            Event::Error(text) => self.note(text, true),
            Event::Busy(s) => {
                self.since.get_or_insert_with(Instant::now);
                self.activity = Some(s);
            }
            Event::Idle => {
                self.activity = None;
                if !self.busy {
                    self.since = None;
                }
                self.cancelling = self.cancelling && self.busy;
            }
            Event::Models(choices) => {
                if std::mem::take(&mut self.awaiting_models) && self.input.is_empty() {
                    self.picker = Some(Picker { choices, selected: 0 });
                }
            }
            Event::ModelChanged { model, base_url, context } => {
                self.note(format!("Now using {model}"), false);
                self.model = model;
                self.base_url = base_url;
                self.context = context;
            }
            Event::Cleared => {
                self.items.clear();
                self.scroll = 0;
                self.streaming = false;
                self.tokens = 0;
            }
            Event::Usage(n) => self.tokens = n,
        }
    }

    fn note(&mut self, text: String, error: bool) {
        self.streaming = false;
        self.items.push(Item::Note { text, error });
    }

    /// Handles a key press.
    pub fn key(&mut self, k: KeyEvent) -> Action {
        if self.picker.is_some() {
            return self.picker_key(k);
        }
        // Any key but Enter means the user moved on from a slow `/models`.
        if k.code != KeyCode::Enter {
            self.awaiting_models = false;
        }
        let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
        if !self.slash_matches().is_empty() && !ctrl
            && let Some(action) = self.slash_key(k)
        {
            return action;
        }
        let running = self.running();
        match k.code {
            KeyCode::Char('c' | 'd') if ctrl && running => {
                if self.cancelling {
                    return Action::Quit;
                }
                self.cancelling = true;
                return Action::Cancel;
            }
            KeyCode::Char('c') if ctrl => {
                if self.busy {
                    if self.cancelling {
                        return Action::Quit;
                    }
                    self.cancelling = true;
                    return Action::Cancel;
                }
                if self.input.is_empty() {
                    return Action::Quit;
                }
                self.set_input(String::new());
            }
            KeyCode::Char('d') if ctrl && self.input.is_empty() => return Action::Quit,
            KeyCode::Esc if running => {
                self.cancelling = true;
                return Action::Cancel;
            }
            KeyCode::Enter if k.modifiers.intersects(KeyModifiers::ALT | KeyModifiers::SHIFT) => self.insert("\n"),
            KeyCode::Char('j') if ctrl => self.insert("\n"),
            KeyCode::Enter => return self.submit(),
            KeyCode::Char('a') if ctrl => self.cursor = 0,
            KeyCode::Home => self.cursor = 0,
            KeyCode::Char('e') if ctrl => self.cursor = self.input.len(),
            KeyCode::End => self.cursor = self.input.len(),
            KeyCode::Char('u') if ctrl => self.set_input(String::new()),
            KeyCode::Char('w') if ctrl => self.delete_word(),
            KeyCode::Char(c) if !ctrl => {
                self.insert(c.encode_utf8(&mut [0; 4]));
                self.slash_sel = 0;
            }
            KeyCode::Backspace => {
                if let Some(prev) = self.input[..self.cursor].chars().next_back() {
                    self.cursor -= prev.len_utf8();
                    self.input.remove(self.cursor);
                    self.slash_sel = 0;
                }
            }
            KeyCode::Delete if self.cursor < self.input.len() => {
                self.input.remove(self.cursor);
            }
            KeyCode::Left => {
                if let Some(prev) = self.input[..self.cursor].chars().next_back() {
                    self.cursor -= prev.len_utf8();
                }
            }
            KeyCode::Right => {
                if let Some(next) = self.input[self.cursor..].chars().next() {
                    self.cursor += next.len_utf8();
                }
            }
            KeyCode::Up if !self.input.contains('\n') => self.recall_step(-1),
            KeyCode::Down if !self.input.contains('\n') => self.recall_step(1),
            KeyCode::PageUp => self.scroll_by(10),
            KeyCode::PageDown => self.scroll_by(-10),
            _ => {}
        }
        Action::None
    }

    /// Commands matching what's typed, while the box holds just a `/word`.
    pub fn slash_matches(&self) -> Vec<&'static Command> {
        let t = self.input.as_str();
        if !t.starts_with('/') || t.contains(char::is_whitespace) {
            return Vec::new();
        }
        let mut v: Vec<&Command> = COMMANDS.iter().filter(|c| c.name.starts_with(t)).collect();
        // /quit is the same as /exit: list it only when typed.
        if !"/quit".starts_with(t) || t.len() < 2 {
            v.retain(|c| c.name != "/quit");
        }
        // What's typed exactly comes first, so `/model` + Enter isn't `/models`.
        v.sort_by_key(|c| c.name != t);
        v
    }

    /// Keys while the `/` menu is open; None lets the key through.
    fn slash_key(&mut self, k: KeyEvent) -> Option<Action> {
        let matches = self.slash_matches();
        let chosen = matches.get(self.slash_sel.min(matches.len() - 1)).copied()?;
        match k.code {
            KeyCode::Up => self.slash_sel = self.slash_sel.saturating_sub(1),
            KeyCode::Down => self.slash_sel = (self.slash_sel + 1).min(matches.len() - 1),
            KeyCode::Esc => self.set_input(String::new()),
            KeyCode::Tab => self.set_input(format!("{}{}", chosen.name, if chosen.arg { " " } else { "" })),
            KeyCode::Enter if k.modifiers.is_empty() => {
                if chosen.arg {
                    self.set_input(format!("{} ", chosen.name));
                    return Some(Action::None);
                }
                self.set_input(chosen.name.to_string());
                return Some(self.submit());
            }
            _ => return None,
        }
        Some(Action::None)
    }

    fn picker_key(&mut self, k: KeyEvent) -> Action {
        let Some(p) = self.picker.as_mut() else { return Action::None };
        match k.code {
            KeyCode::Up => p.selected = p.selected.saturating_sub(1),
            KeyCode::Down if p.selected + 1 < p.choices.len() => p.selected += 1,
            KeyCode::Esc => self.picker = None,
            KeyCode::Char('c') if k.modifiers.contains(KeyModifiers::CONTROL) => self.picker = None,
            KeyCode::Enter => {
                let chosen = p.choices.get(p.selected).cloned();
                self.picker = None;
                if let Some(c) = chosen {
                    return Action::Cmd(if c.download { Cmd::Pull(c.name) } else { Cmd::UseModel(c.name) });
                }
            }
            _ => {}
        }
        Action::None
    }

    fn submit(&mut self) -> Action {
        let text = self.input.trim().to_string();
        if text.is_empty() || self.running() {
            return Action::None;
        }
        self.set_input(String::new());
        self.scroll = 0;
        match text.as_str() {
            "/exit" | "/quit" => return Action::Quit,
            "/clear" => return Action::Cmd(Cmd::Clear),
            "/help" => {
                self.note(HELP.to_string(), false);
                return Action::None;
            }
            "/models" | "/model" => {
                self.awaiting_models = true;
                return Action::Cmd(Cmd::ListModels);
            }
            _ => {}
        }
        if let Some(name) = text.strip_prefix("/model ") {
            return Action::Cmd(Cmd::UseModel(name.trim().to_string()));
        }
        self.history.push(text.clone());
        self.items.push(Item::User(text.clone()));
        self.busy = true;
        self.streaming = false;
        self.since = Some(Instant::now());
        Action::Cmd(Cmd::Send(text))
    }

    /// A turn, download or model load is under way.
    pub fn running(&self) -> bool {
        self.busy || self.activity.is_some()
    }

    fn set_input(&mut self, s: String) {
        self.cursor = s.len();
        self.input = s;
        self.recall = None;
        self.slash_sel = 0;
    }

    fn insert(&mut self, s: &str) {
        self.input.insert_str(self.cursor, s);
        self.cursor += s.len();
    }

    fn delete_word(&mut self) {
        let before = &self.input[..self.cursor];
        let trimmed = before.trim_end_matches(' ');
        let start = trimmed.rfind(' ').map_or(0, |i| i + 1);
        self.input.replace_range(start..self.cursor, "");
        self.cursor = start;
    }

    fn recall_step(&mut self, dir: isize) {
        if self.history.is_empty() {
            return;
        }
        let next = match (self.recall, dir < 0) {
            (None, true) => Some(self.history.len() - 1),
            (None, false) => return,
            (Some(i), true) => Some(i.saturating_sub(1)),
            (Some(i), false) if i + 1 < self.history.len() => Some(i + 1),
            (Some(_), false) => None,
        };
        let text = next.map(|i| self.history[i].clone()).unwrap_or_default();
        self.cursor = text.len();
        self.input = text;
        self.recall = next;
    }

    /// Inserts pasted text at the cursor.
    pub fn paste(&mut self, s: &str) {
        self.insert(&s.replace("\r\n", "\n").replace('\r', "\n"));
    }

    pub fn scroll_by(&mut self, lines: isize) {
        self.scroll = self.scroll.saturating_add_signed(lines);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn k(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }
    fn ctrl(c: char) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL)
    }
    fn typed(app: &mut App, s: &str) {
        for c in s.chars() {
            assert_eq!(app.key(k(KeyCode::Char(c))), Action::None);
        }
    }
    fn app() -> App {
        App::new("qwen", "http://x/v1", 32_768)
    }

    #[test]
    fn enter_sends_and_shows_the_message() {
        let mut a = app();
        typed(&mut a, "fix it");
        assert_eq!(a.key(k(KeyCode::Enter)), Action::Cmd(Cmd::Send("fix it".into())));
        assert_eq!(a.items, vec![Item::User("fix it".into())]);
        assert!(a.busy && a.input.is_empty() && a.cursor == 0);
    }

    #[test]
    fn enter_on_blank_or_while_busy_sends_nothing() {
        let mut a = app();
        typed(&mut a, "  ");
        assert_eq!(a.key(k(KeyCode::Enter)), Action::None);
        a.busy = true;
        typed(&mut a, "x");
        assert_eq!(a.key(k(KeyCode::Enter)), Action::None);
        assert_eq!(a.input, "  x", "kept for after the turn");
    }

    #[test]
    fn alt_enter_and_ctrl_j_insert_newlines() {
        let mut a = app();
        typed(&mut a, "a");
        a.key(KeyEvent::new(KeyCode::Enter, KeyModifiers::ALT));
        typed(&mut a, "b");
        a.key(ctrl('j'));
        typed(&mut a, "c");
        assert_eq!(a.input, "a\nb\nc");
    }

    #[test]
    fn editing_keys() {
        let mut a = app();
        typed(&mut a, "héllo wörld");
        a.key(k(KeyCode::Left));
        a.key(k(KeyCode::Backspace));
        assert_eq!(a.input, "héllo wörd");
        a.key(ctrl('a'));
        a.key(k(KeyCode::Delete));
        assert_eq!(a.input, "éllo wörd");
        a.key(ctrl('e'));
        a.key(ctrl('w'));
        assert_eq!(a.input, "éllo ");
        a.key(ctrl('u'));
        assert_eq!((a.input.as_str(), a.cursor), ("", 0));
    }

    #[test]
    fn slash_commands() {
        let mut a = app();
        typed(&mut a, "/clear");
        assert_eq!(a.key(k(KeyCode::Enter)), Action::Cmd(Cmd::Clear));
        typed(&mut a, "/models");
        assert_eq!(a.key(k(KeyCode::Enter)), Action::Cmd(Cmd::ListModels));
        typed(&mut a, "/model qwen3-4b");
        assert_eq!(a.key(k(KeyCode::Enter)), Action::Cmd(Cmd::UseModel("qwen3-4b".into())));
        typed(&mut a, "/exit");
        assert_eq!(a.key(k(KeyCode::Enter)), Action::Quit);
        assert!(a.items.is_empty(), "commands aren't messages");
    }

    #[test]
    fn ctrl_c_cancels_a_turn_then_quits() {
        let mut a = app();
        a.busy = true;
        assert_eq!(a.key(ctrl('c')), Action::Cancel);
        assert!(a.cancelling);
        assert_eq!(a.key(ctrl('c')), Action::Quit, "second Ctrl-C while stopping quits");
    }

    #[test]
    fn ctrl_c_clears_input_then_quits_when_idle() {
        let mut a = app();
        typed(&mut a, "draft");
        assert_eq!(a.key(ctrl('c')), Action::None);
        assert!(a.input.is_empty());
        assert_eq!(a.key(ctrl('c')), Action::Quit);
        assert_eq!(app().key(ctrl('d')), Action::Quit);
    }

    #[test]
    fn esc_and_ctrl_c_stop_a_download_and_typing_waits_for_it() {
        let mut a = app();
        a.apply(Event::Busy("downloading qwen3-4b".into()));
        assert_eq!(a.key(k(KeyCode::Esc)), Action::Cancel);
        a.cancelling = false;
        assert_eq!(a.key(ctrl('c')), Action::Cancel, "not quit");
        typed(&mut a, "hi");
        assert_eq!(a.key(k(KeyCode::Enter)), Action::None, "no turn queued behind a download");
        a.apply(Event::Idle);
        assert_eq!(a.key(k(KeyCode::Enter)), Action::Cmd(Cmd::Send("hi".into())));
    }

    #[test]
    fn ctrl_d_stops_a_running_turn_instead_of_quitting() {
        let mut a = app();
        a.busy = true;
        assert_eq!(a.key(ctrl('d')), Action::Cancel);
    }

    #[test]
    fn slash_shows_matching_commands_with_descriptions() {
        let mut a = app();
        assert!(a.slash_matches().is_empty());
        typed(&mut a, "/");
        assert_eq!(a.slash_matches().len(), COMMANDS.len() - 1, "/quit only when typed");
        typed(&mut a, "mo");
        let names: Vec<&str> = a.slash_matches().iter().map(|c| c.name).collect();
        assert_eq!(names, vec!["/models", "/model"]);
        assert!(a.slash_matches()[0].about.contains("model"));
        typed(&mut a, "dels x");
        assert!(a.slash_matches().is_empty(), "closed once arguments start");
    }

    #[test]
    fn slash_menu_keys_pick_complete_and_run() {
        let mut a = app();
        typed(&mut a, "/");
        a.key(k(KeyCode::Down));
        assert_eq!(a.slash_sel, 1);
        a.key(k(KeyCode::Up));
        a.key(k(KeyCode::Up));
        assert_eq!(a.slash_sel, 0, "stops at the top");
        typed(&mut a, "cl");
        assert_eq!(a.slash_sel, 0, "typing resets the choice");
        assert_eq!(a.key(k(KeyCode::Enter)), Action::Cmd(Cmd::Clear), "Enter runs the highlighted command");
        typed(&mut a, "/mod");
        a.key(k(KeyCode::Down));
        a.key(k(KeyCode::Tab));
        assert_eq!((a.input.as_str(), a.cursor), ("/model ", 7), "Tab completes; a command with an argument gets a space");
        typed(&mut a, "/mod");
        a.key(ctrl('u'));
        typed(&mut a, "/mod");
        a.key(k(KeyCode::Down));
        assert_eq!(a.key(k(KeyCode::Enter)), Action::None, "/model needs a name: Enter completes it");
        assert_eq!(a.input, "/model ");
        typed(&mut a, "qwen3-4b");
        assert_eq!(a.key(k(KeyCode::Enter)), Action::Cmd(Cmd::UseModel("qwen3-4b".into())));
        typed(&mut a, "/he");
        assert_eq!(a.key(k(KeyCode::Esc)), Action::None);
        assert!(a.input.is_empty(), "Esc closes the menu");
    }

    #[test]
    fn help_lists_commands_and_keys() {
        let mut a = app();
        typed(&mut a, "/help");
        assert_eq!(a.key(k(KeyCode::Enter)), Action::None);
        match a.items.last() {
            Some(Item::Note { text, error: false }) => assert!(text.contains("/models") && text.contains("Esc"), "{text}"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn usage_and_elapsed() {
        let mut a = app();
        a.apply(Event::Usage(3_200));
        assert_eq!(a.tokens, 3_200);
        typed(&mut a, "go");
        a.key(k(KeyCode::Enter));
        assert!(a.since.is_some());
        a.apply(Event::TurnDone(Ok(())));
        assert!(a.since.is_none());
    }

    #[test]
    fn esc_cancels_a_turn() {
        let mut a = app();
        assert_eq!(a.key(k(KeyCode::Esc)), Action::None);
        a.busy = true;
        assert_eq!(a.key(k(KeyCode::Esc)), Action::Cancel);
    }

    #[test]
    fn streamed_text_joins_one_block_per_model_call() {
        let mut a = app();
        a.apply(Event::Reasoning("think".into()));
        a.apply(Event::Reasoning("ing".into()));
        a.apply(Event::Text("Hel".into()));
        a.apply(Event::Text("lo".into()));
        a.apply(Event::ToolStart { name: "bash".into(), args: serde_json::json!({"command": "ls"}) });
        a.apply(Event::ToolEnd { ok: true, output: (1..=8).map(|i| i.to_string()).collect::<Vec<_>>().join("\n") });
        a.apply(Event::Text("done".into()));
        assert_eq!(a.items, vec![
            Item::Reasoning("thinking".into()),
            Item::Assistant("Hello".into()),
            Item::Tool { name: "bash".into(), args: serde_json::json!({"command": "ls"}), ok: Some(true), preview: vec!["1".into(), "2".into(), "3".into(), "4".into(), "5".into()], more: 3 },
            Item::Assistant("done".into()),
        ]);
    }

    #[test]
    fn turn_done_clears_busy_and_shows_errors() {
        let mut a = app();
        a.busy = true;
        a.cancelling = true;
        a.apply(Event::TurnDone(Err("cannot reach x".into())));
        assert!(!a.busy && !a.cancelling);
        assert_eq!(a.items.last(), Some(&Item::Note { text: "cannot reach x".into(), error: true }));
        a.apply(Event::Text("new".into()));
        assert_eq!(a.items.last(), Some(&Item::Assistant("new".into())), "next turn starts a new block");
    }

    #[test]
    fn history_recalls_sent_messages() {
        let mut a = app();
        for m in ["one", "two"] {
            typed(&mut a, m);
            a.key(k(KeyCode::Enter));
            a.apply(Event::TurnDone(Ok(())));
        }
        a.key(k(KeyCode::Up));
        assert_eq!(a.input, "two");
        a.key(k(KeyCode::Up));
        assert_eq!(a.input, "one");
        a.key(k(KeyCode::Down));
        assert_eq!(a.input, "two");
        a.key(k(KeyCode::Down));
        assert_eq!(a.input, "");
    }

    #[test]
    fn picker_chooses_or_downloads() {
        let mut a = app();
        typed(&mut a, "/models");
        a.key(k(KeyCode::Enter));
        a.apply(Event::Models(vec![
            Choice { name: "qwen3.8".into(), detail: "LM Studio · 17.4 GB".into(), download: false },
            Choice { name: "qwen3-4b".into(), detail: "download · 2.5 GB".into(), download: true },
        ]));
        assert!(a.picker.is_some());
        a.key(k(KeyCode::Down));
        assert_eq!(a.key(k(KeyCode::Enter)), Action::Cmd(Cmd::Pull("qwen3-4b".into())));
        assert!(a.picker.is_none());
        typed(&mut a, "/models");
        a.key(k(KeyCode::Enter));
        a.apply(Event::Models(vec![Choice { name: "m".into(), detail: String::new(), download: false }]));
        a.key(k(KeyCode::Up));
        assert_eq!(a.key(k(KeyCode::Enter)), Action::Cmd(Cmd::UseModel("m".into())));
        typed(&mut a, "/models");
        a.key(k(KeyCode::Enter));
        a.apply(Event::Models(vec![]));
        assert_eq!(a.key(k(KeyCode::Esc)), Action::None);
        assert!(a.picker.is_none());
    }

    #[test]
    fn a_late_model_list_does_not_open_after_the_user_moved_on() {
        let mut a = app();
        assert!(a.picker.is_none());
        a.apply(Event::Models(vec![]));
        assert!(a.picker.is_none(), "nobody asked");
        typed(&mut a, "/models");
        a.key(k(KeyCode::Enter));
        typed(&mut a, "fix");
        a.apply(Event::Models(vec![Choice { name: "m".into(), detail: String::new(), download: false }]));
        assert!(a.picker.is_none(), "typing moved on");
        assert_eq!(a.key(k(KeyCode::Enter)), Action::Cmd(Cmd::Send("fix".into())));
    }

    #[test]
    fn model_change_updates_status_and_notes_it() {
        let mut a = app();
        a.apply(Event::ModelChanged { model: "m2".into(), base_url: "http://y/v1".into(), context: 8_192 });
        assert_eq!((a.model.as_str(), a.base_url.as_str(), a.context), ("m2", "http://y/v1", 8_192));
        assert!(matches!(a.items.last(), Some(Item::Note { error: false, .. })));
    }

    #[test]
    fn busy_and_cleared() {
        let mut a = app();
        a.items.push(Item::User("x".into()));
        a.apply(Event::Busy("downloading 10%".into()));
        assert_eq!(a.activity.as_deref(), Some("downloading 10%"));
        a.apply(Event::Idle);
        assert_eq!(a.activity, None);
        a.scroll = 4;
        a.apply(Event::Cleared);
        assert!(a.items.is_empty() && a.scroll == 0);
    }

    #[test]
    fn paste_inserts_at_cursor_and_scroll_never_goes_below_zero() {
        let mut a = app();
        typed(&mut a, "ad");
        a.key(k(KeyCode::Left));
        a.paste("b\r\nc");
        assert_eq!(a.input, "ab\ncd");
        a.scroll_by(3);
        a.scroll_by(-10);
        assert_eq!(a.scroll, 0);
    }
}
