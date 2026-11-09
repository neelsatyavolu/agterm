//! `agl models`, `agl pull`, `agl rm`, and choosing how to run the model the user named.

use crate::config::{self, Overrides};
use crate::models::{self, Pick, catalog, discover, serve, store};
use std::io::Write;

pub fn list() -> i32 {
    print!("{}", models::table(&discover::all()));
    0
}

/// Downloads a catalog model or an `hf:` file, with a progress line on stderr.
pub fn pull(spec: &str) -> i32 {
    let (name, url) = match catalog::find(spec) {
        Some(e) => (e.name.to_string(), e.url()),
        None => match catalog::parse_hf(spec) {
            Some(x) => x,
            None => {
                eprintln!("agl: no model called {spec}; see agl models, or use hf:OWNER/REPO/FILE.gguf");
                return 1;
            }
        },
    };
    let dest = store::path_for(&store::dir(), &name);
    if dest.exists() {
        println!("{name} is already downloaded");
        return 0;
    }
    let mut last = std::time::Instant::now() - std::time::Duration::from_secs(1);
    let mut show = |done: u64, total: Option<u64>| {
        if last.elapsed().as_millis() < 250 && total != Some(done) {
            return;
        }
        last = std::time::Instant::now();
        let pct = total.map(|t| format!(" ({}%)", done * 100 / t.max(1))).unwrap_or_default();
        let of = total.map(|t| format!(" of {}", models::size(t))).unwrap_or_default();
        eprint!("\r{name}: {}{of}{pct}   ", models::size(done));
        let _ = std::io::stderr().flush();
    };
    match store::pull(&url, &dest, &crate::provider::CANCEL, &mut show) {
        Ok(()) => {
            eprintln!();
            println!("downloaded {name}; run it with: agl --model {name}");
            0
        }
        Err(e) => {
            eprintln!("\nagl: {e}");
            1
        }
    }
}

pub fn rm(name: &str) -> i32 {
    match store::remove(&store::dir(), name) {
        Ok(()) => {
            println!("removed {name}");
            0
        }
        Err(e) => {
            eprintln!("agl: {e}");
            1
        }
    }
}

/// Fills in `base_url` (and the model's full name) when the model has to be started first.
/// Leaves `o` alone when the user chose an endpoint or a running server has the model.
pub fn resolve(mut o: Overrides) -> Result<Overrides, String> {
    if o.base_url.is_some() || std::env::var_os("AGL_BASE_URL").is_some() {
        return Ok(o);
    }
    let Some(name) = o.model.clone().or_else(|| std::env::var("AGL_MODEL").ok()) else {
        return Ok(start_any(o));
    };
    let served = config::serving(&config::DEFAULT_CANDIDATES, &name).is_some();
    let installed = if served { Vec::new() } else { discover::all() };
    match models::pick(&name, served, &installed) {
        Pick::Served | Pick::Unknown => Ok(o),
        Pick::Installed(m) => {
            eprintln!("agl: starting {} ({})…", m.name, m.source.label());
            o.base_url = Some(models::prepare(m, &serve::Runtimes::default(), &models::is_live)?);
            o.model = Some(m.name.clone());
            Ok(o)
        }
        Pick::NotDownloaded(e) => {
            Err(format!("{} isn't downloaded yet ({:.1} GB): agl pull {}", e.name, e.size_gb, e.name))
        }
    }
}

/// With no model named and no server running, starts agl's first downloaded model.
fn start_any(mut o: Overrides) -> Overrides {
    if config::DEFAULT_CANDIDATES.iter().any(|c| models::is_live(c)) {
        return o;
    }
    let Some(m) = discover::agl(&store::dir()).into_iter().next() else { return o };
    eprintln!("agl: no model server running; starting {}…", m.name);
    if let Ok(url) = models::prepare(&m, &serve::Runtimes::default(), &models::is_live) {
        o.base_url = Some(url);
        o.model = Some(m.name);
    }
    o
}
