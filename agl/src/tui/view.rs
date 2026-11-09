//! Drawing the interface: the conversation, the message box and a status line.

use super::app::{App, Item};
use ratatui::Frame;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, List, ListItem, ListState, Paragraph};
use unicode_width::UnicodeWidthChar;

const ACCENT: Color = Color::LightBlue;
const MAX_INPUT_ROWS: u16 = 8;
const SPINNER: [&str; 4] = ["◐", "◓", "◑", "◒"];

/// Splits `text` into rows at most `width` columns wide, breaking at spaces when it can.
pub fn wrap(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    let mut rows = Vec::new();
    let text = text.replace('\t', "    ");
    for line in text.split('\n') {
        let (mut row, mut cols) = (String::new(), 0usize);
        for word in line.split_inclusive(' ') {
            // The trailing space may hang past the edge.
            let w: usize = word.trim_end_matches(' ').chars().map(|c| c.width().unwrap_or(0)).sum();
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

fn styled(rows: Vec<String>, prefix: &'static str, style: Style) -> Vec<Line<'static>> {
    rows.into_iter().map(|r| Line::from(vec![Span::styled(prefix, style), Span::styled(r, style)])).collect()
}

/// The conversation as rows `width` columns wide.
pub fn transcript(items: &[Item], width: u16) -> Vec<Line<'static>> {
    let w = usize::from(width);
    let dim = Style::new().add_modifier(Modifier::DIM);
    let mut out: Vec<Line<'static>> = Vec::new();
    for item in items {
        if !out.is_empty() {
            out.push(Line::default());
        }
        match item {
            Item::User(t) => {
                for (i, r) in wrap(t, w.saturating_sub(2)).into_iter().enumerate() {
                    let mark = if i == 0 { "› " } else { "  " };
                    out.push(Line::from(vec![
                        Span::styled(mark, Style::new().fg(ACCENT).add_modifier(Modifier::BOLD)),
                        Span::styled(r, Style::new().add_modifier(Modifier::BOLD)),
                    ]));
                }
            }
            Item::Assistant(t) => out.extend(assistant(t.trim(), w)),
            Item::Reasoning(t) => out.extend(styled(wrap(t.trim(), w), "", dim.add_modifier(Modifier::ITALIC))),
            Item::Tool { summary, ok, preview, more } => {
                let (mark, color) = match ok {
                    None => ("● ", Color::Yellow),
                    Some(true) => ("✓ ", Color::Green),
                    Some(false) => ("✗ ", Color::Red),
                };
                for (i, r) in wrap(summary, w.saturating_sub(2)).into_iter().enumerate() {
                    let lead = if i == 0 { mark } else { "  " };
                    out.push(Line::from(vec![Span::styled(lead, Style::new().fg(color)), Span::raw(r)]));
                }
                let body = if *ok == Some(false) { Style::new().fg(Color::Red) } else { dim };
                for p in preview {
                    out.extend(styled(wrap(p, w.saturating_sub(4)), "  │ ", body));
                }
                if *more > 0 {
                    out.push(Line::styled(format!("  │ … {more} more lines"), dim));
                }
            }
            Item::Note { text, error } => {
                let style = if *error { Style::new().fg(Color::Red) } else { dim };
                out.extend(styled(wrap(text, w), "", style));
            }
        }
    }
    out
}

/// Answer text, with fenced code blocks tinted.
fn assistant(text: &str, w: usize) -> Vec<Line<'static>> {
    let mut out = Vec::new();
    let mut code = false;
    for line in text.split('\n') {
        let fence = line.trim_start().starts_with("```");
        let style = if fence {
            Style::new().add_modifier(Modifier::DIM)
        } else if code {
            Style::new().fg(Color::Cyan)
        } else {
            Style::new()
        };
        out.extend(styled(wrap(line, w), "", style));
        if fence {
            code = !code;
        }
    }
    out
}

/// Rows of the message box and where the cursor sits in them (row, column).
fn input_rows(input: &str, cursor: usize, width: usize) -> (Vec<String>, (usize, usize)) {
    let rows = wrap(input, width);
    let before = wrap(&input[..cursor], width);
    let row = before.len().saturating_sub(1);
    let col: usize = before.last().map_or(0, |r| r.chars().map(|c| c.width().unwrap_or(0)).sum());
    // A cursor at the very end of a full row moves to the next one.
    if col >= width { (rows, (row + 1, 0)) } else { (rows, (row, col)) }
}

pub fn draw(f: &mut Frame, app: &App, tick: usize) {
    let area = f.area();
    let inner_w = usize::from(area.width.saturating_sub(2)).max(1);
    let (rows, (crow, ccol)) = input_rows(&app.input, app.cursor, inner_w);
    let shown_rows = (rows.len().max(crow + 1) as u16).clamp(1, MAX_INPUT_ROWS);
    let [body, input, status] =
        Layout::vertical([Constraint::Min(1), Constraint::Length(shown_rows + 2), Constraint::Length(1)]).areas(area);

    let lines = transcript(&app.items, body.width);
    let height = usize::from(body.height);
    let max_scroll = lines.len().saturating_sub(height);
    let scroll = app.scroll.min(max_scroll);
    let end = lines.len() - scroll;
    let start = end.saturating_sub(height);
    f.render_widget(Paragraph::new(lines[start..end].to_vec()), body);

    let top = crow.saturating_sub(usize::from(shown_rows) - 1);
    let visible: Vec<Line> = rows.iter().skip(top).take(usize::from(shown_rows)).map(|r| Line::raw(r.clone())).collect();
    let border = if app.busy { Style::new().add_modifier(Modifier::DIM) } else { Style::new().fg(ACCENT) };
    let block = Block::new().borders(Borders::TOP | Borders::BOTTOM).border_style(border);
    f.render_widget(Paragraph::new(visible).block(block), input);
    if app.picker.is_none() {
        f.set_cursor_position((input.x + 1 + ccol as u16, input.y + 1 + (crow - top) as u16));
    }

    f.render_widget(Paragraph::new(status_line(app, tick, status.width)), status);
    if let Some(p) = &app.picker {
        picker(f, area, p);
    }
}

fn status_line(app: &App, tick: usize, width: u16) -> Line<'static> {
    let dim = Style::new().add_modifier(Modifier::DIM);
    let host = app.base_url.trim_start_matches("http://").trim_end_matches("/v1").to_string();
    let left = format!(" {} · {host} · {}k ctx", app.model, app.context / 1024);
    let right = if let Some(a) = &app.activity {
        format!("{} {a} ", SPINNER[tick % SPINNER.len()])
    } else if app.busy {
        let what = if app.cancelling { "stopping…" } else { "working · Esc to stop" };
        format!("{} {what} ", SPINNER[tick % SPINNER.len()])
    } else {
        "Enter send · Alt+Enter newline · /models · Ctrl-C quit ".to_string()
    };
    // The hint gives way to the model name on a narrow screen.
    let room = usize::from(width).saturating_sub(left.chars().count() + 1);
    let right: String = if right.chars().count() > room { right.chars().take(room).collect() } else { right };
    let pad = usize::from(width).saturating_sub(left.chars().count() + right.chars().count()).max(1);
    Line::from(vec![Span::styled(left, dim), Span::raw(" ".repeat(pad)), Span::styled(right, dim)])
}

fn picker(f: &mut Frame, area: Rect, p: &super::app::Picker) {
    let h = (p.choices.len() as u16 + 2).clamp(3, area.height.saturating_sub(2).max(3));
    let w = area.width.saturating_sub(8).clamp(20, 80);
    let rect = Rect { x: area.x + (area.width.saturating_sub(w)) / 2, y: area.y + 1, width: w.min(area.width), height: h.min(area.height) };
    f.render_widget(Clear, rect);
    let title = if p.choices.is_empty() { " no models found " } else { " models · Enter use · Esc close " };
    let items: Vec<ListItem> = p
        .choices
        .iter()
        .map(|c| {
            let style = if c.download { Style::new().add_modifier(Modifier::DIM) } else { Style::new() };
            ListItem::new(Line::from(vec![Span::styled(format!("{:<34}", c.name), style), Span::styled(c.detail.clone(), Style::new().add_modifier(Modifier::DIM))]))
        })
        .collect();
    let list = List::new(items)
        .block(Block::bordered().title(title).border_style(Style::new().fg(ACCENT)))
        .highlight_style(Style::new().bg(ACCENT).fg(Color::Black));
    let mut state = ListState::default().with_selected(Some(p.selected));
    f.render_stateful_widget(list, rect, &mut state);
}

#[cfg(test)]
mod tests {
    use super::super::app::{Choice, Event};
    use super::*;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    fn screen(app: &App, w: u16, h: u16) -> String {
        let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
        t.draw(|f| draw(f, app, 0)).unwrap();
        let buf = t.backend().buffer().clone();
        (0..h).map(|y| (0..w).map(|x| buf[(x, y)].symbol().to_string()).collect::<String>().trim_end().to_string())
            .collect::<Vec<_>>()
            .join("\n")
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
    fn shows_conversation_input_and_status() {
        let mut a = App::new("qwen3", "http://127.0.0.1:1235/v1", 262_144);
        a.items.push(Item::User("fix add.py".into()));
        a.apply(Event::Text("Looking.".into()));
        a.apply(Event::ToolStart("edit add.py".into()));
        a.apply(Event::ToolEnd { ok: false, output: "old text not found".into() });
        a.input = "next".into();
        a.cursor = 4;
        let s = screen(&a, 60, 14);
        assert!(s.contains("› fix add.py"), "{s}");
        assert!(s.contains("Looking."), "{s}");
        assert!(s.contains("✗ edit add.py") && s.contains("│ old text not found"), "{s}");
        assert!(s.contains("next"), "{s}");
        assert!(s.contains("qwen3 · 127.0.0.1:1235 · 256k ctx"), "{s}");
    }

    #[test]
    fn newest_lines_show_and_scrolling_reveals_older_ones() {
        let mut a = App::new("m", "u", 1024);
        for i in 0..30 {
            a.items.push(Item::Note { text: format!("line {i}"), error: false });
        }
        let s = screen(&a, 40, 10);
        assert!(s.contains("line 29") && !s.contains("line 20"), "{s}");
        a.scroll = 10;
        let s = screen(&a, 40, 10);
        assert!(s.contains("line 24") && !s.contains("line 29"), "{s}");
        a.scroll = 10_000;
        assert!(screen(&a, 40, 10).contains("line 0"), "clamped to the top");
    }

    #[test]
    fn busy_status_and_picker() {
        let mut a = App::new("m", "u", 1024);
        a.busy = true;
        assert!(screen(&a, 60, 8).contains("Esc to stop"));
        a.apply(Event::Busy("qwen3-4b: 1.2 GB of 2.5 GB (48%)".into()));
        assert!(screen(&a, 60, 8).contains("48%"));
        a.busy = false;
        a.apply(Event::Idle);
        a.input = "/models".into();
        a.cursor = a.input.len();
        a.key(ratatui::crossterm::event::KeyEvent::from(ratatui::crossterm::event::KeyCode::Enter));
        a.apply(Event::Models(vec![Choice { name: "qwen3.8-27b-splash".into(), detail: "LM Studio · 17.4 GB".into(), download: false }]));
        let s = screen(&a, 70, 10);
        assert!(s.contains("qwen3.8-27b-splash") && s.contains("LM Studio · 17.4 GB"), "{s}");
    }

    #[test]
    fn status_halves_never_touch() {
        let a = App::new("qwen3.8-27b-splash", "http://127.0.0.1:1235/v1", 262_144);
        let s = screen(&a, 70, 6);
        assert!(s.contains("256k ctx Enter"), "{s}");
    }

    #[test]
    fn code_fences_and_multiline_input_render() {
        let mut a = App::new("m", "u", 1024);
        a.items.push(Item::Assistant("Run:\n```sh\ncargo test\n```".into()));
        a.input = "one\ntwo\nthree".into();
        a.cursor = a.input.len();
        let s = screen(&a, 40, 14);
        assert!(s.contains("cargo test") && s.contains("```sh"), "{s}");
        assert!(s.contains("one") && s.contains("two") && s.contains("three"), "{s}");
    }

    #[test]
    fn cursor_position_follows_wrapping() {
        assert_eq!(input_rows("abcdef", 6, 4).1, (1, 2));
        assert_eq!(input_rows("abcd", 4, 4).1, (1, 0));
        assert_eq!(input_rows("a\nb", 3, 10).1, (1, 1));
        assert_eq!(input_rows("", 0, 10).1, (0, 0));
    }
}
