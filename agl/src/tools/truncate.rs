//! Caps long tool output, keeping its head and tail.

/// Returns `s` unchanged if within both limits; otherwise keeps the first and last part
/// and notes how many lines were cut.
pub fn cap(s: &str, max_chars: usize, max_lines: usize) -> String {
    let by_lines = cap_lines(s, max_lines);
    cap_chars(&by_lines, max_chars)
}

fn cap_lines(s: &str, max_lines: usize) -> String {
    let lines: Vec<&str> = s.lines().collect();
    if lines.len() <= max_lines {
        return s.to_string();
    }
    let head = max_lines / 2;
    let tail = max_lines - head;
    let cut = lines.len() - head - tail;
    let mut out = lines[..head].join("\n");
    out.push_str(&format!("\n[… {cut} lines cut …]\n"));
    out.push_str(&lines[lines.len() - tail..].join("\n"));
    out
}

fn cap_chars(s: &str, max_chars: usize) -> String {
    let total = s.chars().count();
    if total <= max_chars {
        return s.to_string();
    }
    let half = max_chars / 2;
    let head: String = s.chars().take(half).collect();
    let tail: String = s.chars().skip(total - half).collect();
    format!("{head}\n[… {} chars cut …]\n{tail}", total - 2 * half)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_output_unchanged() {
        assert_eq!(cap("a\nb", 100, 10), "a\nb");
    }

    #[test]
    fn cap_keeps_head_and_tail_by_lines() {
        let s: String = (1..=100).map(|i| format!("line{i}\n")).collect();
        let out = cap(&s, 1_000_000, 10);
        assert!(out.starts_with("line1\n"));
        assert!(out.trim_end().ends_with("line100"));
        assert!(out.contains("lines cut"));
        assert!(out.lines().count() <= 11);
    }

    #[test]
    fn cap_limits_chars_on_one_long_line() {
        let s = "x".repeat(10_000);
        let out = cap(&s, 1_000, 100);
        assert!(out.chars().count() < 1_200, "{}", out.len());
        assert!(out.contains("chars cut"));
    }

    #[test]
    fn cap_respects_char_boundaries() {
        let s = "é".repeat(5_000);
        let out = cap(&s, 100, 10);
        assert!(out.contains("cut"));
    }
}
