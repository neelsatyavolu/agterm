//! agterm's `SessionWire` frames: a 4-byte big-endian length (tag plus payload), a 1-byte tag,
//! then the payload. Only the tags a command connection uses are known here; others are skipped,
//! as the Mac's own decoder does for tags from newer versions.

use serde::{Deserialize, Serialize};

pub const MAX_FRAME: usize = 16 * 1024 * 1024;

const OUTPUT: u8 = 8;
const EXITED: u8 = 9;
const ERROR: u8 = 12;
const INPUT: u8 = 13;
const AUTH: u8 = 15;
const EXEC: u8 = 18;
const STDERR: u8 = 19;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Message {
    /// Bytes for the command's stdin; empty means its input ended.
    Input(Vec<u8>),
    Auth(String),
    Exec(Vec<String>),
    Output(Vec<u8>),
    Stderr(Vec<u8>),
    Exited(i32),
    Error(String),
}

#[derive(Serialize, Deserialize)]
struct Exited {
    id: String,
    status: i32,
}

#[derive(Debug, PartialEq, Eq)]
pub enum FrameError {
    TooLarge(usize),
    BadPayload,
}

impl std::fmt::Display for FrameError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FrameError::TooLarge(n) => write!(f, "frame of {n} bytes is too large"),
            FrameError::BadPayload => write!(f, "bad frame payload"),
        }
    }
}

impl std::error::Error for FrameError {}

pub fn encode(message: &Message) -> Vec<u8> {
    let (tag, payload): (u8, Vec<u8>) = match message {
        Message::Input(b) => (INPUT, b.clone()),
        Message::Auth(t) => (AUTH, t.as_bytes().to_vec()),
        Message::Exec(argv) => (EXEC, serde_json::to_vec(argv).expect("argv as JSON")),
        Message::Output(b) => (OUTPUT, b.clone()),
        Message::Stderr(b) => (STDERR, b.clone()),
        Message::Exited(status) => {
            (EXITED, serde_json::to_vec(&Exited { id: String::new(), status: *status }).expect("exit as JSON"))
        }
        Message::Error(text) => (ERROR, text.as_bytes().to_vec()),
    };
    let mut frame = Vec::with_capacity(5 + payload.len());
    frame.extend_from_slice(&((payload.len() + 1) as u32).to_be_bytes());
    frame.push(tag);
    frame.extend_from_slice(&payload);
    frame
}

/// Collects bytes as they arrive and hands out whole frames.
#[derive(Default)]
pub struct Decoder {
    buffer: Vec<u8>,
}

impl Decoder {
    pub fn push(&mut self, bytes: &[u8]) {
        self.buffer.extend_from_slice(bytes);
    }

    /// The next whole message, or None until one has arrived. After an error the connection
    /// must be dropped.
    pub fn next_message(&mut self) -> Result<Option<Message>, FrameError> {
        loop {
            if self.buffer.len() < 4 {
                return Ok(None);
            }
            let length = u32::from_be_bytes([self.buffer[0], self.buffer[1], self.buffer[2], self.buffer[3]]) as usize;
            if length > MAX_FRAME {
                return Err(FrameError::TooLarge(length));
            }
            if length < 1 {
                return Err(FrameError::BadPayload);
            }
            if self.buffer.len() < 4 + length {
                return Ok(None);
            }
            let tag = self.buffer[4];
            let payload: Vec<u8> = self.buffer[5..4 + length].to_vec();
            self.buffer.drain(..4 + length);
            if let Some(message) = message(tag, payload)? {
                return Ok(Some(message));
            }
        }
    }
}

fn message(tag: u8, payload: Vec<u8>) -> Result<Option<Message>, FrameError> {
    let text = |p: Vec<u8>| String::from_utf8_lossy(&p).into_owned();
    Ok(Some(match tag {
        INPUT => Message::Input(payload),
        AUTH => Message::Auth(text(payload)),
        EXEC => Message::Exec(serde_json::from_slice(&payload).map_err(|_| FrameError::BadPayload)?),
        OUTPUT => Message::Output(payload),
        STDERR => Message::Stderr(payload),
        EXITED => {
            let exited: Exited = serde_json::from_slice(&payload).map_err(|_| FrameError::BadPayload)?;
            Message::Exited(exited.status)
        }
        ERROR => Message::Error(text(payload)),
        _ => return Ok(None),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_every_message() {
        let all = [
            Message::Input(b"abc".to_vec()),
            Message::Input(vec![]),
            Message::Auth("tok".into()),
            Message::Exec(vec!["a b".into(), "c".into()]),
            Message::Output(vec![0, 1, 2]),
            Message::Stderr(b"err".to_vec()),
            Message::Exited(-3),
            Message::Error("unauthorized".into()),
        ];
        let mut decoder = Decoder::default();
        for m in &all {
            decoder.push(&encode(m));
        }
        for m in &all {
            assert_eq!(decoder.next_message().unwrap().as_ref(), Some(m));
        }
        assert_eq!(decoder.next_message().unwrap(), None);
    }

    #[test]
    fn matches_the_mac_layout() {
        assert_eq!(encode(&Message::Auth("ab".into())), vec![0, 0, 0, 3, 15, b'a', b'b']);
        let exited = encode(&Message::Exited(3));
        assert_eq!(&exited[5..], br#"{"id":"","status":3}"#);
    }

    #[test]
    fn skips_unknown_tags_and_waits_for_partial_frames() {
        let mut decoder = Decoder::default();
        decoder.push(&[0, 0, 0, 3, 99, 1, 2]); // tag 99: from a newer version
        let frame = encode(&Message::Output(b"hi".to_vec()));
        decoder.push(&frame[..3]);
        assert_eq!(decoder.next_message().unwrap(), None);
        decoder.push(&frame[3..]);
        assert_eq!(decoder.next_message().unwrap(), Some(Message::Output(b"hi".to_vec())));
    }

    #[test]
    fn rejects_oversized_and_empty_frames() {
        let mut decoder = Decoder::default();
        decoder.push(&((MAX_FRAME + 1) as u32).to_be_bytes());
        assert!(matches!(decoder.next_message(), Err(FrameError::TooLarge(_))));
        let mut empty = Decoder::default();
        empty.push(&[0, 0, 0, 0]);
        assert_eq!(empty.next_message(), Err(FrameError::BadPayload));
    }
}
