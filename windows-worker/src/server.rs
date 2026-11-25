//! The listener: each connection is TLS with the pairing PSK, then `auth`, then one `exec`.
//! The secret is read from `worker.json` for every connection, so `new-code` takes effect for
//! the next connection without a restart.

use crate::{
    config, crypto,
    exec::{self, Event, Failure, Running},
    wire::{self, Decoder, Message},
};
use openssl::ssl::{Ssl, SslContext, SslMethod, SslStream, SslVerifyMode, SslVersion};
use std::{
    error::Error,
    io::{self, Read, Write},
    net::{TcpListener, TcpStream},
    path::PathBuf,
    sync::{
        mpsc::{sync_channel, TryRecvError},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};

const AUTH_TIMEOUT: Duration = Duration::from_secs(10);
/// How long a read waits before the connection's thread sends what the command has written.
const POLL: Duration = Duration::from_millis(10);
pub const CIPHERS: &str = "PSK-AES128-GCM-SHA256:@SECLEVEL=0";

pub struct Server {
    /// Where `worker.json` is.
    pub dir: PathBuf,
    /// This program, for built-ins.
    pub exe: PathBuf,
}

/// Serves connections from `listener` until it fails.
pub fn serve(listener: TcpListener, server: Arc<Server>) -> io::Result<()> {
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let server = server.clone();
                thread::spawn(move || {
                    let peer = stream.peer_addr().map(|a| a.to_string()).unwrap_or_default();
                    if let Err(e) = handle(stream, &server) {
                        eprintln!("agterm-worker: {peer}: {e}");
                    }
                });
            }
            Err(e) => eprintln!("agterm-worker: accept failed: {e}"),
        }
    }
    Ok(())
}

/// A TLS 1.2 server context that accepts only the pairing's PSK, as `MacLink` offers it.
pub fn context(secret: &str) -> Result<SslContext, openssl::error::ErrorStack> {
    let psk = crypto::psk(secret);
    let mut builder = SslContext::builder(SslMethod::tls_server())?;
    builder.set_min_proto_version(Some(SslVersion::TLS1_2))?;
    builder.set_max_proto_version(Some(SslVersion::TLS1_2))?;
    builder.set_cipher_list(CIPHERS)?;
    builder.set_verify(SslVerifyMode::NONE);
    builder.set_psk_server_callback(move |_ssl, identity, out| {
        if identity != Some(crypto::PSK_IDENTITY.as_bytes()) || out.len() < psk.len() {
            return Ok(0);
        }
        out[..psk.len()].copy_from_slice(&psk);
        Ok(psk.len())
    });
    Ok(builder.build())
}

fn handle(tcp: TcpStream, server: &Server) -> Result<(), Box<dyn Error>> {
    tcp.set_nodelay(true)?;
    tcp.set_read_timeout(Some(AUTH_TIMEOUT))?;
    let config = config::load(&server.dir)?;
    let context = context(&config.secret)?;
    let ssl = Ssl::new(&context)?;
    let stream = ssl.accept(tcp).map_err(|e| format!("handshake failed (wrong pairing code?): {e}"))?;
    stream.get_ref().set_read_timeout(Some(POLL))?;
    Connection { stream, token: crypto::token(&config.secret), exe: server.exe.clone() }.run()
}

struct Connection {
    stream: SslStream<TcpStream>,
    token: String,
    exe: PathBuf,
}

impl Connection {
    fn run(mut self) -> Result<(), Box<dyn Error>> {
        let started = Instant::now();
        let mut decoder = Decoder::default();
        let mut authed = false;
        let (events_tx, events) = sync_channel::<Event>(16);
        let mut running: Option<Running> = None;
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            loop {
                match events.try_recv() {
                    Ok(Event::Message(message)) => self.send(&message)?,
                    Ok(Event::Exit(status)) => {
                        self.send(&Message::Exited(status))?;
                        let _ = self.stream.shutdown();
                        return Ok(());
                    }
                    Err(TryRecvError::Empty | TryRecvError::Disconnected) => break,
                }
            }
            if !authed && started.elapsed() > AUTH_TIMEOUT {
                return self.refuse();
            }
            match self.stream.read(&mut buf) {
                Ok(0) => return Ok(()), // the Mac hung up; dropping `running` stops the command
                Ok(n) => decoder.push(&buf[..n]),
                Err(e) if matches!(e.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => {}
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(e) => return Err(e.into()),
            }
            while let Some(message) = decoder.next_message()? {
                match message {
                    Message::Auth(token) if !authed => {
                        if !crypto::same(token.as_bytes(), self.token.as_bytes()) {
                            return self.refuse();
                        }
                        authed = true;
                    }
                    _ if !authed => return self.refuse(),
                    Message::Exec(argv) if running.is_none() => match self.start(&argv, events_tx.clone()) {
                        Ok(started) => running = Some(started),
                        Err(failure) => {
                            match failure {
                                Failure::Refused(text) => self.send(&Message::Error(text))?,
                                Failure::Exit(text, status) => {
                                    self.send(&Message::Stderr(text.into_bytes()))?;
                                    self.send(&Message::Exited(status))?;
                                }
                            }
                            let _ = self.stream.shutdown();
                            return Ok(());
                        }
                    },
                    Message::Input(bytes) => {
                        if let Some(running) = &running {
                            running.input(bytes);
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    fn start(&self, argv: &[String], events: std::sync::mpsc::SyncSender<Event>) -> Result<Running, Failure> {
        let cmd = exec::command(argv, &self.exe)?;
        Running::start(cmd, events).map_err(|e| Failure::Refused(format!("exec failed: {e}")))
    }

    fn send(&mut self, message: &Message) -> io::Result<()> {
        self.stream.write_all(&wire::encode(message))
    }

    fn refuse(&mut self) -> Result<(), Box<dyn Error>> {
        self.send(&Message::Error("unauthorized".into()))?;
        let _ = self.stream.shutdown();
        Ok(())
    }
}
