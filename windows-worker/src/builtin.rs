//! `agterm-worker --builtin <command> …`: the worker's own commands, which the server runs as a
//! child process (argv `agterm-worker <command> …` from the Mac) so they get stdin, stdout and
//! an exit status like any other command.

use crate::{config, files, shell};
use std::{
    io::{self, BufWriter, Write},
    path::Path,
};

pub const USAGE: &str = "built-ins: info | manifest <dir> [--skip <name>]... | receive <dir> | delete <dir> | \
                         changed <dir> <since> [--skip <name>]... | pack <dir> | shell <cwd> <command>";

/// Runs one built-in with this process's stdin and stdout; its exit status.
pub fn run(args: &[String]) -> i32 {
    match dispatch(args) {
        Ok(status) => status,
        Err(e) => {
            eprintln!("agterm-worker: {e}");
            1
        }
    }
}

fn dispatch(args: &[String]) -> io::Result<i32> {
    let stdin = io::stdin();
    let mut input = stdin.lock();
    let stdout = io::stdout();
    let mut out = BufWriter::new(stdout.lock());
    let mut err = io::stderr();
    let words: Vec<&str> = args.iter().map(String::as_str).collect();
    let status = match words.as_slice() {
        ["info"] => {
            writeln!(out, "{}", info())?;
            0
        }
        ["manifest", dir, rest @ ..] => {
            files::manifest(Path::new(dir), &skips(rest)?, &mut out)?;
            0
        }
        ["changed", dir, since, rest @ ..] => {
            let since: u64 = since.parse().map_err(|_| invalid(format!("not a time: {since}")))?;
            files::changed(Path::new(dir), since, &skips(rest)?, &mut out)?;
            0
        }
        ["receive", dir] => status(files::receive(Path::new(dir), &mut input, &mut err)?),
        ["delete", dir] => status(files::delete(Path::new(dir), &mut input, &mut err)?),
        ["pack", dir] => {
            files::pack(Path::new(dir), &mut input, &mut out)?;
            0
        }
        _ => {
            eprintln!("agterm-worker: unknown built-in {}\n{USAGE}", args.join(" "));
            2
        }
    };
    out.flush()?;
    Ok(status)
}

fn status(ok: bool) -> i32 {
    if ok {
        0
    } else {
        1
    }
}

fn invalid(text: String) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, text)
}

/// `--skip <name>` pairs.
fn skips(words: &[&str]) -> io::Result<Vec<String>> {
    let mut names = Vec::new();
    let mut rest = words.iter();
    while let Some(word) = rest.next() {
        match (*word, rest.next()) {
            ("--skip", Some(name)) => names.push(name.to_string()),
            _ => return Err(invalid(format!("unexpected {word}"))),
        }
    }
    Ok(names)
}

/// What `info` prints: one line of JSON.
pub fn info() -> String {
    let home = config::home().to_string_lossy().replace('\\', "/");
    serde_json::json!({
        "version": env!("CARGO_PKG_VERSION"),
        "system": config::system(),
        "home": home,
        "shell": shell::name(),
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn info_is_json_with_forward_slashes() {
        let value: serde_json::Value = serde_json::from_str(&info()).unwrap();
        assert_eq!(value["version"], env!("CARGO_PKG_VERSION"));
        assert!(!value["home"].as_str().unwrap().contains('\\'));
        assert_eq!(value["system"], config::system());
    }

    #[test]
    fn parses_skips() {
        assert_eq!(skips(&["--skip", "a", "--skip", "b"]).unwrap(), vec!["a", "b"]);
        assert!(skips(&["--skip"]).is_err());
        assert!(skips(&["x"]).is_err());
    }
}
