//! Test-only helpers: a one-thread HTTP stub that answers every request with a fixed body.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;

/// A running stub server. `base` is `http://127.0.0.1:PORT`; `requests` collects request bodies.
pub struct Stub {
    pub base: String,
    pub requests: Arc<Mutex<Vec<String>>>,
}

/// Serves `body` with `content_type` to every request until the test process ends.
pub fn serve(content_type: &'static str, body: String) -> Stub {
    serve_status(200, content_type, body)
}

/// Like `serve`, with a chosen HTTP status.
pub fn serve_status(status: u16, content_type: &'static str, body: String) -> Stub {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let requests = Arc::new(Mutex::new(Vec::new()));
    let seen = Arc::clone(&requests);
    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut len = 0usize;
            let mut line = String::new();
            while reader.read_line(&mut line).unwrap_or(0) > 0 && line != "\r\n" {
                if let Some(v) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    len = v.trim().parse().unwrap_or(0);
                }
                line.clear();
            }
            let mut buf = vec![0u8; len];
            let _ = reader.read_exact(&mut buf);
            seen.lock().unwrap().push(String::from_utf8_lossy(&buf).into_owned());
            let mut out = stream;
            let _ = write!(
                out,
                "HTTP/1.1 {status} X\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
        }
    });
    Stub { base, requests }
}

/// Answers every request with `response` written verbatim, then closes the connection.
pub fn serve_raw(response: String) -> Stub {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            while reader.read_line(&mut line).unwrap_or(0) > 0 && line != "\r\n" {
                line.clear();
            }
            let mut out = stream;
            let _ = out.write_all(response.as_bytes());
        }
    });
    Stub { base, requests: Arc::new(Mutex::new(Vec::new())) }
}

/// A local URL nothing listens on.
pub fn dead_url() -> String {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", l.local_addr().unwrap());
    drop(l);
    url
}
