//! agterm-worker: lets a paired Mac run tasks on this computer (a Windows PC, mainly).
//! It speaks the same link as a Mac worker: TLS 1.2 with a pre-shared key from the pairing
//! secret, then agterm's `SessionWire` frames, one command per connection.

pub mod builtin;
pub mod config;
pub mod crypto;
pub mod exec;
pub mod files;
pub mod server;
pub mod shell;
pub mod wire;

#[cfg(windows)]
pub mod windows;
