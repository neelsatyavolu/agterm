//! Drawing the interface: the conversation, the `/` menu, the message box and a footer.

use super::app::{App, Item};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Clear, List, ListItem, ListState, Padding, Paragraph};
use serde_json::Value;
use unicode_width::UnicodeWidthChar;

const ACCENT: Color = Color::Rgb(0x4C, 0x8D, 0xFF);
const MAX_INPUT_ROWS: u16 = 8;
const SPINNER: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const PREVIEW_LINES: usize = 4;
const DIFF_LINES: usize = 6;

fn dim() -> Style {
    Style::new().add_modifier(Modifier::DIM)
}

fn width_of(s: &str) -> usize {
    s.chars().map(|c| c.width().unwrap_or(0)).sum()
}

/// Splits `text` into rows at most `width` columns wide, breaking at spaces when it can.
pub fn wrap(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut rows = Vec::new();
    let text = text.replace('\t', "    ");
    for line in text.split('\n') {
        let (mut row, mut cols) = (String::new(), 0usize);
        for word in line.split_inclusive(' ') {
            // The trailing space may hang past the edge.
            let w = width_of(word.trim_end_matches(' '));
            if cols + w > width && cols > 0 {
                rows.push(std::mem::take(&mut row).trim_end().to_string());
                cols = 0;
            }
            for c in word.chars() {
                let cw = c.width().unwrap_or(0);
                if c == ' ' && cols + cw > width {
                    continue;
                }
                if cols + cw > width && cols > 0 {
                    rows.push(std::mem::take(&mut row));
                    cols = 0;
                }
                row.push(c);
                cols += cw;
            }
        }
        rows.push(row);
    }
    rows
}

/// Wraps styled pieces of one line to `width`, starting rows with `first` then `rest`.
fn wrap_spans(pieces: Vec<(String, Style)>, width: usize, first: Span<'static>, rest: Span<'static>) -> Vec<Line<'static>> {
    let room = width.saturating_sub(width_of(&first.content)).max(1);
    let mut lines = Vec::new();
    let mut row: Vec<Span<'static>> = vec![first];
    let mut cols = 0usize;
    let flush = |row: &mut Vec<Span<'static>>, lines: &mut Vec<Line<'static>>, rest: &Span<'static>| {
        if let Some(last) = row.last_mut() {
            let trimmed = last.content.trim_end().to_string();
            last.content = trimmed.into();
        }
        lines.push(Line::from(std::mem::replace(row, vec![rest.clone()])));
    };
    for (text, style) in pieces {
        for word in text.split_inclusive(' ') {
            let w = width_of(word.trim_end_matches(' '));
            if cols + w > room && cols > 0 {
                flush(&mut row, &mut lines, &rest);
                cols = 0;
            }
            // A word longer than the row is cut where the row ends.
            let mut piece = String::new();
            for c in word.chars() {
                let cw = c.width().unwrap_or(0);
                if c == ' ' && cols + cw > room {
                    continue;
                }
                if cols + cw > room && cols > 0 {
                    row.push(Span::styled(std::mem::take(&mut piece), style));
                    flush(&mut row, &mut lines, &rest);
                    cols = 0;
                }
                piece.push(c);
                cols += cw;
            }
            if !piece.is_empty() {
                row.push(Span::styled(piece, style));
            }
        }
    }
    lines.push(Line::from(row));
    lines
}

/// `**bold**` and `` `code` `` inside a line of an answer.
fn inline(text: &str, base: Style) -> Vec<(String, Style)> {
    let mut out = Vec::new();
    let (mut bold, mut code) = (false, false);
    let mut cur = String::new();
    let mut chars = text.chars().peekable();
    let style = |bold: bool, code: bool| {
        let s = if code { base.fg(Color::Cyan) } else { base };
        if bold { s.add_modifier(Modifier::BOLD) } else { s }
    };
    while let Some(c) = chars.next() {
        if c == '`' {
            out.push((std::mem::take(&mut cur), style(bold, code)));
            code = !code;
        } else if c == '*' && chars.peek() == Some(&'*') && !code {
            chars.next();
            out.push((std::mem::take(&mut cur), style(bold, code)));
            bold = !bold;
        } else {
            cur.push(c);
        }
    }
    out.push((cur, style(bold, code)));
    out.retain(|(t, _)| !t.is_empty());
    out
}

/// An answer, with light markdown: headings, bullets, inline code, bold and code blocks.
fn answer(text: &str, w: usize) -> Vec<Line<'static>> {
    let mut out = Vec::new();
    let mut code = false;
    for (i, line) in text.split('\n').enumerate() {
        let lead = if i == 0 { Span::raw("● ") } else { Span::raw("  ") };
        let trimmed = line.trim_start();
        if trimmed.starts_with("```") {
            code = !code;
            continue;
        }
        if code {
            out.extend(wrap_spans(vec![(line.replace('\t', "    "), Style::new().fg(Color::Cyan))], w, Span::styled(
                if i == 0 { "● │ " } else { "  │ " }, dim()), Span::styled("  │ ", dim())));
            continue;
        }
        if let Some(h) = trimmed.strip_prefix('#') {
            let h = h.trim_start_matches('#').trim();
            out.extend(wrap_spans(inline(h, Style::new().add_modifier(Modifier::BOLD)), w, lead, Span::raw("  ")));
            continue;
        }
        let indent = line.len() - trimmed.len();
        if let Some(item) = trimmed.strip_prefix("- ").or_else(|| trimmed.strip_prefix("* ")) {
            let pad = " ".repeat(indent);
            let first = Span::raw(if i == 0 { format!("● {pad}• ") } else { format!("  {pad}• ") });
            out.extend(wrap_spans(inline(item, Style::new()), w, first, Span::raw(format!("  {pad}  "))));
            continue;
        }
        out.extend(wrap_spans(inline(line, Style::new()), w, lead, Span::raw("  ")));
    }
    out
}

/// What a tool call shows: its verb and what it acted on.
fn tool_title(name: &str, args: &Value) -> (String, String) {
    let s = |k: &str| args[k].as_str().unwrap_or("").to_string();
    match name {
        "read" => ("Read".into(), s("path")),
        "write" => ("Write".into(), s("path")),
        "edit" => ("Edit".into(), s("path")),
        "bash" => ("Run".into(), s("command").lines().next().unwrap_or("").to_string()),
        other => (other.to_string(), String::new()),
    }
}

/// The rows under a tool call: an edit's diff, a command's output, a read's size, or the error.
fn tool_body(name: &str, args: &Value, ok: Option<bool>, preview: &[String], more: usize) -> Vec<(String, Style)> {
    let red = Style::new().fg(Color::Red);
    let green = Style::new().fg(Color::Green);
    match ok {
        None => vec![("running…".into(), dim())],
        Some(false) => {
            let mut v: Vec<(String, Style)> = preview.iter().take(PREVIEW_LINES).map(|l| (l.clone(), red)).collect();
            if preview.len() + more > PREVIEW_LINES {
                v.push((format!("… +{} lines", preview.len() + more - PREVIEW_LINES), dim()));
            }
            v
        }
        Some(true) => match name {
            "read" => vec![(format!("{} lines", preview.len() + more), dim())],
            "write" => vec![(format!("{} lines", args["content"].as_str().map_or(0, |c| c.lines().count())), dim())],
            "edit" => {
                let old: Vec<&str> = args["old"].as_str().unwrap_or("").lines().collect();
                let new: Vec<&str> = args["new"].as_str().unwrap_or("").lines().collect();
                let mut v: Vec<(String, Style)> = old.iter().take(DIFF_LINES).map(|l| (format!("- {l}"), red)).collect();
                v.extend(new.iter().take(DIFF_LINES).map(|l| (format!("+ {l}"), green)));
                let hidden = old.len().saturating_sub(DIFF_LINES) + new.len().saturating_sub(DIFF_LINES);
                if hidden > 0 {
                    v.push((format!("… +{hidden} lines"), dim()));
                }
                v
            }
            _ => {
                let mut v: Vec<(String, Style)> = preview.iter().take(PREVIEW_LINES).map(|l| (l.clone(), dim())).collect();
                if preview.len() + more > PREVIEW_LINES {
                    v.push((format!("… +{} lines", preview.len() + more - PREVIEW_LINES), dim()));
                }
                v
            }
        },
    }
}

/// The conversation as rows `width` columns wide.
pub fn transcript(items: &[Item], width: u16) -> Vec<Line<'static>> {
    let w = usize::from(width).max(8);
    let mut out: Vec<Line<'static>> = Vec::new();
    for item in items {
        if !out.is_empty() {
            out.push(Line::default());
        }
        match item {
            Item::User(t) => {
                for (i, line) in t.split('\n').enumerate() {
                    let first = if i == 0 { Span::styled("› ", Style::new().fg(ACCENT).add_modifier(Modifier::BOLD)) } else { Span::raw("  ") };
                    out.extend(wrap_spans(vec![(line.to_string(), Style::new().add_modifier(Modifier::BOLD))], w, first, Span::raw("  ")));
                }
            }
            Item::Assistant(t) => out.extend(answer(t.trim(), w)),
            Item::Reasoning(t) => {
                let style = dim().add_modifier(Modifier::ITALIC);
                let text = t.trim();
                let rows = wrap(text, w.saturating_sub(2));
                let shown = rows.len().min(3);
                for (i, r) in rows.iter().take(shown).enumerate() {
                    let lead = if i == 0 { Span::styled("✻ ", dim()) } else { Span::raw("  ") };
                    out.push(Line::from(vec![lead, Span::styled(r.clone(), style)]));
                }
                if rows.len() > shown {
                    out.push(Line::styled("  …", dim()));
                }
            }
            Item::Tool { name, args, ok, preview, more } => {
                let color = match ok {
                    None => Color::Yellow,
                    Some(true) => Color::Green,
                    Some(false) => Color::Red,
                };
                let (verb, subject) = tool_title(name, args);
                out.extend(wrap_spans(
                    vec![(format!("{verb} "), Style::new().add_modifier(Modifier::BOLD)), (subject, Style::new())],
                    w,
                    Span::styled("● ", Style::new().fg(color)),
                    Span::raw("  "),
                ));
                for (i, (text, style)) in tool_body(name, args, *ok, preview, *more).into_iter().enumerate() {
                    let lead = if i == 0 { "  ⎿ " } else { "    " };
                    out.extend(wrap_spans(vec![(text, style)], w, Span::styled(lead, dim()), Span::raw("    ")));
                }
            }
            Item::Note { text, error } => {
                let (lead, style) = if *error { ("✗ ", Style::new().fg(Color::Red)) } else { ("  ", dim()) };
                for (i, line) in text.split('\n').enumerate() {
                    let first = if i == 0 { Span::styled(lead, style) } else { Span::raw("  ") };
                    out.extend(wrap_spans(vec![(line.to_string(), style)], w, first, Span::raw("  ")));
                }
            }
        }
    }
    out
}

/// Where the model runs, by port: LM Studio, Ollama, or agl's own llama-server.
pub fn source(base_url: &str) -> &'static str {
    let port = base_url.split("://").nth(1).and_then(|h| h.split('/').next()).and_then(|h| h.rsplit(':').next()).unwrap_or("");
    match port {
        "11434" => "Ollama",
        "1234" | "1235" => "LM Studio",
        "8080" => "llama-server",
        _ if base_url.contains("127.0.0.1") || base_url.contains("localhost") => "local",
        _ => "remote",
    }
}

fn tokens(n: u32) -> String {
    if n >= 1_000 { format!("{:.1}k", f64::from(n) / 1_000.0) } else { n.to_string() }
}

/// The card an empty conversation shows.
fn welcome(app: &App, w: usize) -> Vec<Line<'static>> {
    let home = std::env::var("HOME").unwrap_or_default();
    let mut cwd = if !home.is_empty() && app.cwd.starts_with(&home) { format!("~{}", &app.cwd[home.len()..]) } else { app.cwd.clone() };
    // A long path keeps its end, the part that names the project.
    let room = w.saturating_sub(6);
    if cwd.chars().count() > room {
        let tail: String = cwd.chars().rev().take(room.saturating_sub(1)).collect::<Vec<_>>().into_iter().rev().collect();
        cwd = format!("…{tail}");
    }
    let mut lines = vec![
        Line::default(),
        Line::from(vec![
            Span::styled("  ✻ ", Style::new().fg(ACCENT)),
            Span::styled("agl", Style::new().fg(ACCENT).add_modifier(Modifier::BOLD)),
            Span::styled("  coding agent for local models", dim()),
        ]),
        Line::default(),
        Line::from(vec![Span::raw("    "), Span::raw(app.model.clone()), Span::styled(
            format!("  ·  {}  ·  {}k context", source(&app.base_url), app.context / 1024), dim())]),
        Line::styled(format!("    {cwd}"), dim()),
        Line::default(),
        Line::styled("    Ask for a change, a fix or an explanation.", Style::new()),
        Line::from(vec![Span::styled("    Type ", dim()), Span::styled("/", Style::new().fg(ACCENT)),
            Span::styled(" for commands, ", dim()), Span::styled("/models", Style::new().fg(ACCENT)), Span::styled(" to switch model.", dim())]),
    ];
    lines.iter_mut().for_each(|l| {
        if width_of(&l.to_string()) > w {
            *l = Line::raw(l.to_string().chars().take(w).collect::<String>());
        }
    });
    lines
}

/// Rows of the message box and where the cursor sits in them (row, column).
fn input_rows(input: &str, cursor: usize, width: usize) -> (Vec<String>, (usize, usize)) {
    let rows = wrap(input, width);
    let before = wrap(&input[..cursor], width);
    let row = before.len().saturating_sub(1);
    let col = before.last().map_or(0, |r| width_of(r));
    // A cursor at the very end of a full row moves to the next one.
    if col >= width { (rows, (row + 1, 0)) } else { (rows, (row, col)) }
}

/// What the spinner line says while something runs.
fn activity(app: &App, tick: usize) -> Line<'static> {
    let label = if app.cancelling {
        "Stopping…".to_string()
    } else if let Some(a) = &app.activity {
        a.clone()
    } else {
        match app.items.last() {
            Some(Item::Reasoning(_)) => "Thinking…".into(),
            Some(Item::Tool { name, args, ok: None, .. }) => format!("{}…", tool_title(name, args).0),
            Some(Item::Assistant(_)) => "Writing…".into(),
            _ => "Working…".into(),
        }
    };
    let secs = app.since.map_or(0, |s| s.elapsed().as_secs());
    Line::from(vec![
        Span::styled(format!("{} ", SPINNER[tick % SPINNER.len()]), Style::new().fg(ACCENT)),
        Span::raw(label),
        Span::styled(format!("  {secs}s · esc to stop"), dim()),
    ])
}

pub fn draw(f: &mut Frame, app: &App, tick: usize) {
    let area = f.area();
    let inner_w = usize::from(area.width.saturating_sub(6)).max(1);
    let (rows, (crow, ccol)) = input_rows(&app.input, app.cursor, inner_w.saturating_sub(2).max(1));
    let shown_rows = (rows.len().max(crow + 1) as u16).clamp(1, MAX_INPUT_ROWS);
    let menu = app.slash_matches();
    let menu_h = menu.len() as u16;
    let busy_h = u16::from(app.running());
    let [body, gap, busy, slash, input, footer] = Layout::vertical([
        Constraint::Min(1),
        Constraint::Length(1),
        Constraint::Length(busy_h),
        Constraint::Length(menu_h),
        Constraint::Length(shown_rows + 2),
        Constraint::Length(1),
    ])
    .areas(area);
    let _ = gap;

    // The conversation, padded one column on each side.
    let text_area = Rect { x: body.x + 1, width: body.width.saturating_sub(2), ..body };
    let lines = if app.items.is_empty() { welcome(app, usize::from(text_area.width)) } else { transcript(&app.items, text_area.width) };
    let height = usize::from(text_area.height);
    let max_scroll = lines.len().saturating_sub(height);
    let scroll = app.scroll.min(max_scroll);
    let end = lines.len() - scroll;
    let start = end.saturating_sub(height);
    f.render_widget(Paragraph::new(lines[start..end].to_vec()), text_area);

    if busy_h > 0 {
        f.render_widget(Paragraph::new(activity(app, tick)), Rect { x: busy.x + 1, width: busy.width.saturating_sub(1), ..busy });
    }

    if menu_h > 0 {
        let sel = app.slash_sel.min(menu.len() - 1);
        let rows: Vec<Line> = menu
            .iter()
            .enumerate()
            .map(|(i, c)| {
                let (mark, name) = if i == sel {
                    ("› ", Style::new().fg(ACCENT).add_modifier(Modifier::BOLD))
                } else {
                    ("  ", Style::new())
                };
                Line::from(vec![
                    Span::styled(mark, Style::new().fg(ACCENT)),
                    Span::styled(format!("{:<10}", c.name), name),
                    Span::styled(c.about, dim()),
                ])
            })
            .collect();
        f.render_widget(Paragraph::new(rows), Rect { x: slash.x + 1, width: slash.width.saturating_sub(1), ..slash });
    }

    let top = crow.saturating_sub(usize::from(shown_rows) - 1);
    let prompt = Span::styled("› ", Style::new().fg(if app.running() { Color::DarkGray } else { ACCENT }));
    let visible: Vec<Line> = if app.input.is_empty() {
        let hint = if app.running() { "Type your next message…" } else { "Ask agl anything  ·  / for commands" };
        vec![Line::from(vec![prompt, Span::styled(hint, dim())])]
    } else {
        rows.iter()
            .enumerate()
            .skip(top)
            .take(usize::from(shown_rows))
            .map(|(i, r)| Line::from(vec![if i == 0 { prompt.clone() } else { Span::raw("  ") }, Span::raw(r.clone())]))
            .collect()
    };
    let border = if app.running() { dim() } else { Style::new().fg(ACCENT) };
    let block = Block::bordered().border_type(BorderType::Rounded).border_style(border).padding(Padding::horizontal(1));
    f.render_widget(Paragraph::new(visible).block(block), input);
    if app.picker.is_none() {
        // Border, padding, then the "› " prompt.
        f.set_cursor_position((input.x + 4 + ccol as u16, input.y + 1 + (crow - top) as u16));
    }

    f.render_widget(Paragraph::new(footer_line(app, footer.width)), footer);
    if let Some(p) = &app.picker {
        picker(f, area, p);
    }
}

fn footer_line(app: &App, width: u16) -> Line<'static> {
    let pct = if app.context > 0 { (u64::from(app.tokens) * 100 / u64::from(app.context)).min(100) } else { 0 };
    let left = format!("  {} · {} · {} / {}k ({pct}%)", app.model, source(&app.base_url), tokens(app.tokens), app.context / 1024);
    let right = if app.picker.is_some() {
        "↑↓ choose · enter use · esc close  "
    } else if !app.slash_matches().is_empty() {
        "↑↓ choose · tab complete · enter run  "
    } else if app.running() {
        "esc stop  "
    } else {
        "/ commands · ctrl-c quit  "
    };
    // The hint gives way to the model name on a narrow screen.
    let room = usize::from(width).saturating_sub(left.chars().count() + 1);
    let right: String = right.chars().take(room).collect();
    let pad = usize::from(width).saturating_sub(left.chars().count() + right.chars().count()).max(1);
    Line::from(vec![Span::styled(left, dim()), Span::raw(" ".repeat(pad)), Span::styled(right, dim())])
}

fn picker(f: &mut Frame, area: Rect, p: &super::app::Picker) {
    let h = (p.choices.len() as u16 + 2).clamp(3, area.height.saturating_sub(4).max(3));
    let w = area.width.saturating_sub(6).clamp(20, 90);
    let rect = Rect { x: area.x + area.width.saturating_sub(w) / 2, y: area.y + 1, width: w.min(area.width), height: h.min(area.height) };
    f.render_widget(Clear, rect);
    let title = if p.choices.is_empty() { " No models found " } else { " Models " };
    let items: Vec<ListItem> = p
        .choices
        .iter()
        .map(|c| {
            let (mark, style) = if c.download { ("↓ ", dim()) } else { ("  ", Style::new()) };
            ListItem::new(Line::from(vec![
                Span::styled(mark, Style::new().fg(ACCENT)),
                Span::styled(format!("{:<32}", c.name), style),
                Span::styled(c.detail.clone(), dim()),
            ]))
        })
        .collect();
    let list = List::new(items)
        .block(Block::bordered().border_type(BorderType::Rounded).title(title).border_style(Style::new().fg(ACCENT)))
        .highlight_style(Style::new().bg(ACCENT).fg(Color::Black).add_modifier(Modifier::BOLD));
    let mut state = ListState::default().with_selected(Some(p.selected));
    f.render_stateful_widget(list, rect, &mut state);
}

#[cfg(test)]
mod tests {
    use super::super::app::{Choice, Event};
    use super::*;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;
    use ratatui::crossterm::event::{KeyCode, KeyEvent};
    use serde_json::json;

    fn screen(app: &App, w: u16, h: u16) -> String {
        let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
        t.draw(|f| draw(f, app, 0)).unwrap();
        let buf = t.backend().buffer().clone();
        (0..h).map(|y| (0..w).map(|x| buf[(x, y)].symbol().to_string()).collect::<String>().trim_end().to_string())
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn tool(a: &mut App, name: &str, args: Value, ok: bool, output: &str) {
        a.apply(Event::ToolStart { name: name.into(), args });
        a.apply(Event::ToolEnd { ok, output: output.into() });
    }

    #[test]
    fn wrap_breaks_at_spaces_and_long_words() {
        assert_eq!(wrap("hello big world", 9), vec!["hello big", "world"]);
        assert_eq!(wrap("abcdefghij", 4), vec!["abcd", "efgh", "ij"]);
        assert_eq!(wrap("a\n\nb", 10), vec!["a", "", "b"]);
        assert_eq!(wrap("日本語です", 4), vec!["日本", "語で", "す"]);
        assert_eq!(wrap("     1\tdef", 20), vec!["     1    def"], "tabs take space");
    }

    #[test]
    fn styled_wrapping_keeps_words_and_indents() {
        let lines = wrap_spans(vec![("hello big world".into(), Style::new())], 11, Span::raw("● "), Span::raw("  "));
        let text: Vec<String> = lines.iter().map(|l| l.to_string()).collect();
        assert_eq!(text, vec!["● hello big", "  world"]);
        let long = wrap_spans(vec![("abcdefghij".into(), Style::new())], 6, Span::raw("> "), Span::raw("  "));
        assert_eq!(long.iter().map(|l| l.to_string()).collect::<Vec<_>>(), vec!["> abcd", "  efgh", "  ij"]);
    }

    #[test]
    fn inline_markdown() {
        let p = inline("run `cargo test` **now**", Style::new());
        assert_eq!(p.iter().map(|(t, _)| t.as_str()).collect::<Vec<_>>(), vec!["run ", "cargo test", " ", "now"]);
        assert_eq!(p[1].1.fg, Some(Color::Cyan));
        assert!(p[3].1.add_modifier.contains(Modifier::BOLD));
    }

    #[test]
    fn empty_conversation_shows_a_welcome() {
        let mut a = App::new("qwen3.8-27b-splash", "http://127.0.0.1:1235/v1", 262_144);
        a.cwd = "/w/proj".into();
        let s = screen(&a, 80, 20);
        assert!(s.contains("✻ agl") && s.contains("qwen3.8-27b-splash  ·  LM Studio  ·  256k context"), "{s}");
        assert!(s.contains("/w/proj") && s.contains("Type / for commands"), "{s}");
        assert!(s.contains("│ › Ask agl anything"), "placeholder\n{s}");
        a.cwd = format!("/very/long/{}/project", "x".repeat(200));
        let s = screen(&a, 80, 20);
        assert!(s.contains("…") && s.contains("/project"), "{s}");
    }

    #[test]
    fn conversation_tools_and_footer() {
        let mut a = App::new("qwen3", "http://127.0.0.1:1235/v1", 262_144);
        a.items.push(Item::User("fix add.py".into()));
        a.apply(Event::Reasoning("Looking at the file.".into()));
        a.apply(Event::Text("I'll fix **it** with `+`.".into()));
        tool(&mut a, "read", json!({"path": "add.py"}), true, "1\tdef add\n2\t  return a - b");
        tool(&mut a, "edit", json!({"path": "add.py", "old": "return a - b", "new": "return a + b"}), true, "edited");
        tool(&mut a, "bash", json!({"command": "python3 add.py"}), false, "Traceback\nNameError");
        a.apply(Event::Usage(3_200));
        let s = screen(&a, 70, 30);
        for want in ["› fix add.py", "✻ Looking at the file.", "● I'll fix it with +.", "● Read add.py", "⎿ 2 lines",
                     "● Edit add.py", "- return a - b", "+ return a + b", "● Run python3 add.py", "Traceback",
                     "qwen3 · LM Studio · 3.2k / 256k (1%)", "/ commands"] {
            assert!(s.contains(want), "missing {want:?}\n{s}");
        }
    }

    #[test]
    fn slash_menu_shows_descriptions() {
        let mut a = App::new("m", "http://127.0.0.1:11434/v1", 32_768);
        a.key(KeyEvent::from(KeyCode::Char('/')));
        let s = screen(&a, 70, 16);
        assert!(s.contains("› /models   Pick a model, or download one"), "{s}");
        assert!(s.contains("/clear    Start a new conversation"), "{s}");
        assert!(s.contains("tab complete"), "{s}");
        assert!(!s.contains("/quit"), "{s}");
    }

    #[test]
    fn running_shows_a_spinner_line() {
        let mut a = App::new("m", "u", 1024);
        a.busy = true;
        a.apply(Event::Reasoning("hmm".into()));
        let s = screen(&a, 60, 12);
        assert!(s.contains("⠋ Thinking…") && s.contains("esc to stop"), "{s}");
        a.apply(Event::Busy("downloading qwen3-4b: 1.2 GB of 2.5 GB (48%)".into()));
        assert!(screen(&a, 70, 12).contains("48%"));
    }

    #[test]
    fn picker_lists_models_and_downloads() {
        let mut a = App::new("m", "u", 1024);
        a.input = "/models".into();
        a.cursor = a.input.len();
        a.key(KeyEvent::from(KeyCode::Enter));
        a.apply(Event::Models(vec![
            Choice { name: "qwen3.8-27b-splash".into(), detail: "LM Studio · 17.4 GB".into(), download: false },
            Choice { name: "qwen3-coder-30b".into(), detail: "download · 18.6 GB".into(), download: true },
        ]));
        let s = screen(&a, 90, 12);
        assert!(s.contains("Models") && s.contains("qwen3.8-27b-splash") && s.contains("↓ qwen3-coder-30b"), "{s}");
    }

    #[test]
    fn newest_lines_show_and_scrolling_reveals_older_ones() {
        let mut a = App::new("m", "u", 1024);
        for i in 0..30 {
            a.items.push(Item::Note { text: format!("line {i}"), error: false });
        }
        let s = screen(&a, 40, 14);
        assert!(s.contains("line 29") && !s.contains("line 20"), "{s}");
        a.scroll = 10;
        let s = screen(&a, 40, 14);
        assert!(s.contains("line 24") && !s.contains("line 29"), "{s}");
        a.scroll = 10_000;
        assert!(screen(&a, 40, 14).contains("line 0"), "clamped to the top");
    }

    #[test]
    fn code_blocks_and_multiline_input_render() {
        let mut a = App::new("m", "u", 1024);
        a.items.push(Item::Assistant("Run:\n```sh\ncargo test\n```".into()));
        a.input = "one\ntwo\nthree".into();
        a.cursor = a.input.len();
        let s = screen(&a, 40, 16);
        assert!(s.contains("│ cargo test") && !s.contains("```"), "{s}");
        assert!(s.contains("one") && s.contains("two") && s.contains("three"), "{s}");
    }

    #[test]
    fn cursor_position_follows_wrapping() {
        assert_eq!(input_rows("abcdef", 6, 4).1, (1, 2));
        assert_eq!(input_rows("abcd", 4, 4).1, (1, 0));
        assert_eq!(input_rows("a\nb", 3, 10).1, (1, 1));
        assert_eq!(input_rows("", 0, 10).1, (0, 0));
    }

    #[test]
    fn source_names_the_server() {
        assert_eq!(source("http://127.0.0.1:11434/v1"), "Ollama");
        assert_eq!(source("http://127.0.0.1:1235/v1"), "LM Studio");
        assert_eq!(source("http://127.0.0.1:53111/v1"), "local");
        assert_eq!(source("https://api.example.com/v1"), "remote");
    }
}
