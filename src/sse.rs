//! Server-sent events: yields the JSON payload of each `data:` event until `[DONE]`.

use std::io::BufRead;

#[derive(Debug)]
pub enum SseError {
    Io(std::io::Error),
    BadJson { line: String, reason: String },
}

impl std::fmt::Display for SseError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            Self::Io(e) => write!(f, "stream read failed: {e}"),
            Self::BadJson { line, reason } => write!(f, "bad event JSON ({reason}): {line}"),
        }
    }
}

#[derive(Debug, PartialEq)]
pub enum Event {
    Data(serde_json::Value),
    /// The `[DONE]` marker; nothing follows it.
    Done,
}

/// Parses an SSE body. Non-`data:` lines (comments, `event:`, blanks) are skipped.
pub fn parse_lines(r: impl BufRead) -> impl Iterator<Item = Result<Event, SseError>> {
    let mut lines = r.lines();
    let mut done = false;
    std::iter::from_fn(move || {
        while !done {
            let line = match lines.next()? {
                Ok(l) => l,
                Err(e) => {
                    done = true;
                    return Some(Err(SseError::Io(e)));
                }
            };
            let Some(data) = line.trim_end_matches('\r').strip_prefix("data:") else {
                continue;
            };
            let data = data.trim();
            if data == "[DONE]" {
                done = true;
                return Some(Ok(Event::Done));
            }
            if data.is_empty() {
                continue;
            }
            return Some(serde_json::from_str(data).map(Event::Data).map_err(|e| SseError::BadJson {
                line: data.chars().take(200).collect(),
                reason: e.to_string(),
            }));
        }
        None
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn collect(s: &str) -> Vec<serde_json::Value> {
        parse_lines(s.as_bytes())
            .map(Result::unwrap)
            .filter_map(|e| if let Event::Data(v) = e { Some(v) } else { None })
            .collect()
    }

    #[test]
    fn sse_parses_text_deltas() {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n: keep-alive\n\ndata: {\"choices\":[{\"delta\":{\"content\":\" there\"}}]}\n\n";
        let events = collect(body);
        assert_eq!(events.len(), 2);
        assert_eq!(events[1]["choices"][0]["delta"]["content"], " there");
    }

    #[test]
    fn sse_stops_at_done() {
        let body = "data: {\"a\":1}\n\ndata: [DONE]\n\ndata: {\"a\":2}\n\n";
        assert_eq!(collect(body).len(), 1);
    }

    #[test]
    fn sse_accepts_crlf_and_no_space() {
        let body = "data:{\"a\":1}\r\n\r\n";
        assert_eq!(collect(body)[0]["a"], 1);
    }

    #[test]
    fn sse_bad_json_is_error() {
        let mut it = parse_lines("data: {nope\n\n".as_bytes());
        assert!(matches!(it.next(), Some(Err(SseError::BadJson { .. }))));
    }
}
