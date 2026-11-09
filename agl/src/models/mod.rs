//! The model library: what's installed, what can be downloaded, and getting a model running.

pub mod catalog;
pub mod discover;
pub mod serve;
pub mod store;

use discover::{Installed, Source};
use serve::Runtimes;

/// Context llama-server is started with for agl's own models.
pub const LLAMA_CONTEXT: u32 = 32_768;

/// Gets `m` served and returns the base URL to talk to it on.
/// `live` says whether a server answers at a base URL.
pub fn prepare(m: &Installed, rt: &Runtimes, live: &dyn Fn(&str) -> bool) -> Result<String, String> {
    match m.source {
        Source::Agl => {
            let path = m.path.as_deref().ok_or_else(|| format!("{} has no file", m.name))?;
            serve::start_llama(&rt.llama_server, path, LLAMA_CONTEXT)
        }
        Source::Ollama => {
            if !live(&rt.ollama_url) {
                serve::start_ollama(&rt.ollama, &rt.ollama_url)?;
            }
            Ok(rt.ollama_url.clone())
        }
        Source::LmStudio => {
            if let Some(u) = rt.lmstudio_urls.iter().find(|u| live(u)) {
                return Ok(u.clone());
            }
            serve::start_lmstudio(&rt.lms)?;
            rt.lmstudio_urls.iter().find(|u| live(u)).cloned()
                .ok_or_else(|| "LM Studio started but its server isn't answering on 1234 or 1235".to_string())
        }
    }
}

/// True when an OpenAI-compatible server answers `{base}/models`.
pub fn is_live(base: &str) -> bool {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(std::time::Duration::from_millis(300)))
        .build()
        .into();
    agent.get(&format!("{}/models", base.trim_end_matches('/'))).call().is_ok()
}

/// The `agl models` listing: installed models by source, then the catalog.
pub fn table(installed: &[Installed]) -> String {
    let mut out = String::new();
    for source in [Source::Agl, Source::LmStudio, Source::Ollama] {
        let group: Vec<&Installed> = installed.iter().filter(|m| m.source == source).collect();
        if group.is_empty() {
            continue;
        }
        out.push_str(&format!("{}\n", source.label()));
        for m in group {
            out.push_str(&format!("  {:<36} {:>8}\n", m.name, size(m.bytes)));
        }
        out.push('\n');
    }
    out.push_str("Download (agl pull NAME)\n");
    for e in &catalog::CATALOG {
        let have = installed.iter().any(|m| m.source == Source::Agl && m.name == e.name);
        let mark = if have { "  downloaded" } else { "" };
        out.push_str(&format!("  {:<20} {:>5.1} GB  {}{mark}\n", e.name, e.size_gb, e.about));
    }
    out.push_str("  hf:OWNER/REPO/FILE.gguf  any GGUF file on Hugging Face\n");
    out
}

/// How to run the model a user named.
#[derive(Debug, PartialEq)]
pub enum Pick<'a> {
    /// A running server already lists it.
    Served,
    Installed(&'a Installed),
    /// In the catalog but not downloaded.
    NotDownloaded(&'static catalog::Entry),
    Unknown,
}

/// Picks how to run `name`: a server that lists it, else an installed model, else the catalog.
pub fn pick<'a>(name: &str, served: bool, installed: &'a [Installed]) -> Pick<'a> {
    if served {
        return Pick::Served;
    }
    if let Some(m) = discover::lookup(installed, name) {
        return Pick::Installed(m);
    }
    catalog::find(name).map_or(Pick::Unknown, Pick::NotDownloaded)
}

/// Bytes as "18.6 GB".
pub fn size(bytes: u64) -> String {
    format!("{:.1} GB", bytes as f64 / 1e9)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn rt(dir: &std::path::Path) -> Runtimes {
        Runtimes {
            llama_server: serve::tests::fake_server(dir, 0),
            ollama: dir.join("no-ollama"),
            lms: dir.join("no-lms"),
            ollama_url: "http://ollama.test/v1".into(),
            lmstudio_urls: vec!["http://lms-a.test/v1".into(), "http://lms-b.test/v1".into()],
        }
    }

    fn m(name: &str, source: Source, path: Option<PathBuf>) -> Installed {
        Installed { name: name.into(), source, bytes: 2_500_000_000, path }
    }

    #[test]
    fn running_servers_are_used_as_they_are() {
        let d = tempfile::tempdir().unwrap();
        let rt = rt(d.path());
        let live = |u: &str| u == "http://ollama.test/v1" || u == "http://lms-b.test/v1";
        assert_eq!(prepare(&m("q:7b", Source::Ollama, None), &rt, &live).unwrap(), "http://ollama.test/v1");
        assert_eq!(prepare(&m("k", Source::LmStudio, None), &rt, &live).unwrap(), "http://lms-b.test/v1");
    }

    #[test]
    fn agl_models_get_their_own_llama_server() {
        let _turn = serve::tests::serial();
        let d = tempfile::tempdir().unwrap();
        let url = prepare(&m("x", Source::Agl, Some("/m/x.gguf".into())), &rt(d.path()), &|_| false).unwrap();
        assert!(url.starts_with("http://127.0.0.1:"), "{url}");
        serve::stop();
    }

    #[test]
    fn missing_runtimes_are_named() {
        let d = tempfile::tempdir().unwrap();
        let e = prepare(&m("q:7b", Source::Ollama, None), &rt(d.path()), &|_| false).unwrap_err();
        assert!(e.contains("ollama"), "{e}");
        let e = prepare(&m("k", Source::LmStudio, None), &rt(d.path()), &|_| false).unwrap_err();
        assert!(e.contains("lms"), "{e}");
    }

    #[test]
    fn pick_prefers_a_running_server_then_installed_then_catalog() {
        let v = vec![m("qwen3-4b", Source::Agl, Some("/m".into())), m("hermes:latest", Source::Ollama, None)];
        assert_eq!(pick("qwen3-4b", true, &v), Pick::Served);
        assert_eq!(pick("qwen3-4b", false, &v), Pick::Installed(&v[0]));
        assert_eq!(pick("hermes", false, &v), Pick::Installed(&v[1]));
        assert!(matches!(pick("gpt-oss-20b", false, &v), Pick::NotDownloaded(e) if e.name == "gpt-oss-20b"));
        assert_eq!(pick("whatever", false, &v), Pick::Unknown);
    }

    #[test]
    fn table_groups_installed_and_marks_downloaded_catalog_entries() {
        let t = table(&[m("qwen3-4b", Source::Agl, Some("/m".into())), m("hermes:latest", Source::Ollama, None)]);
        assert!(t.contains("agl") && t.contains("Ollama") && t.contains("hermes:latest"), "{t}");
        let catalog = t.split("Download").nth(1).unwrap();
        let catalog_line = catalog.lines().find(|l| l.contains("qwen3-4b")).unwrap();
        assert!(catalog_line.contains("downloaded"), "{catalog_line}");
        let other = catalog.lines().find(|l| l.contains("qwen3-coder-30b")).unwrap();
        assert!(!other.contains("downloaded"), "{other}");
        assert!(t.contains("agl pull"), "{t}");
    }
}
