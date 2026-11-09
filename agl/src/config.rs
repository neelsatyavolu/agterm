//! Settings: flags > env (`AGL_*`) > `~/.config/agl/config.toml` > local endpoint detection.

use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Ollama, LM Studio (1234, or 1235 when 1234 is taken) and llama-server, in that order.
pub const DEFAULT_CANDIDATES: [&str; 4] = [
    "http://127.0.0.1:11434/v1",
    "http://127.0.0.1:1234/v1",
    "http://127.0.0.1:1235/v1",
    "http://127.0.0.1:8080/v1",
];
const DEFAULT_CONTEXT_WINDOW: u32 = 32_768;
const DEFAULT_BASH_TIMEOUT_SECS: u64 = 120;
const DEFAULT_TEMPERATURE: f32 = 0.2;
const PROBE_TIMEOUT: Duration = Duration::from_millis(300);

#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    pub base_url: String,
    pub model: String,
    pub api_key: Option<String>,
    pub context_window: u32,
    pub bash_timeout_secs: u64,
    pub temperature: f32,
}

/// Values given on the command line.
#[derive(Debug, Default, Clone)]
pub struct Overrides {
    pub base_url: Option<String>,
    pub model: Option<String>,
    pub api_key: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
struct FileConfig {
    base_url: Option<String>,
    model: Option<String>,
    api_key: Option<String>,
    context_window: Option<u32>,
    bash_timeout_secs: Option<u64>,
    temperature: Option<f32>,
}

#[derive(Debug)]
pub enum ConfigError {
    BadFile { path: PathBuf, reason: String },
    NoEndpoint,
    NoModel { base_url: String },
}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            Self::BadFile { path, reason } => write!(f, "cannot read {}: {reason}", path.display()),
            Self::NoEndpoint => write!(
                f,
                "no local model server found on ports 11434 (Ollama), 1234 (LM Studio) or 8080 (llama-server); start one or pass --base-url"
            ),
            Self::NoModel { base_url } => {
                write!(f, "{base_url} lists no models; load one or pass --model")
            }
        }
    }
}

/// The default config file path.
pub fn default_path() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config/agl/config.toml"))
}

/// Loads settings, reading `AGL_*` from the process environment.
pub fn load(path: Option<&Path>, overrides: Overrides) -> Result<Config, ConfigError> {
    load_with_env(path, overrides, &|k| std::env::var(k).ok())
}

/// Loads settings with an injectable environment lookup.
pub fn load_with_env(
    path: Option<&Path>,
    overrides: Overrides,
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<Config, ConfigError> {
    let file = match path {
        Some(p) => read_file(p)?,
        None => FileConfig::default(),
    };
    let api_key = overrides.api_key.or_else(|| env("AGL_API_KEY")).or(file.api_key);
    let want_model = overrides.model.or_else(|| env("AGL_MODEL")).or(file.model);
    let base_url = match overrides.base_url.or_else(|| env("AGL_BASE_URL")).or(file.base_url) {
        Some(u) => u.trim_end_matches('/').to_string(),
        None => detect_endpoint(&DEFAULT_CANDIDATES, want_model.as_deref()).ok_or(ConfigError::NoEndpoint)?,
    };
    let model = match want_model {
        Some(m) => m,
        None => get_json(&format!("{}/api/v0/models", base_url.trim_end_matches("/v1")))
            .as_ref()
            .and_then(pick_lmstudio_model)
            .or_else(|| fetch_models(&base_url).as_ref().and_then(pick_model))
            .ok_or_else(|| ConfigError::NoModel { base_url: base_url.clone() })?,
    };
    let context_window = file
        .context_window
        .or_else(|| detect_context(&base_url, &model))
        .unwrap_or(DEFAULT_CONTEXT_WINDOW);
    Ok(Config {
        base_url,
        model,
        api_key,
        context_window,
        bash_timeout_secs: file.bash_timeout_secs.unwrap_or(DEFAULT_BASH_TIMEOUT_SECS),
        temperature: file.temperature.unwrap_or(DEFAULT_TEMPERATURE),
    })
}

fn read_file(path: &Path) -> Result<FileConfig, ConfigError> {
    match std::fs::read_to_string(path) {
        Ok(s) => toml::from_str(&s).map_err(|e| ConfigError::BadFile {
            path: path.to_path_buf(),
            reason: e.to_string(),
        }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(FileConfig::default()),
        Err(e) => Err(ConfigError::BadFile { path: path.to_path_buf(), reason: e.to_string() }),
    }
}

fn probe_agent() -> ureq::Agent {
    ureq::Agent::config_builder().timeout_global(Some(PROBE_TIMEOUT)).build().into()
}

fn get_json(url: &str) -> Option<serde_json::Value> {
    probe_agent().get(url).call().ok()?.body_mut().read_json().ok()
}

fn post_json(url: &str, body: &serde_json::Value) -> Option<serde_json::Value> {
    probe_agent().post(url).send_json(body).ok()?.body_mut().read_json().ok()
}

fn fetch_models(base_url: &str) -> Option<serde_json::Value> {
    get_json(&format!("{base_url}/models"))
}

/// The first live candidate that lists `want_model`, else the first live candidate.
pub fn detect_endpoint(candidates: &[&str], want_model: Option<&str>) -> Option<String> {
    let mut first_live = None;
    for c in candidates {
        let Some(models) = fetch_models(c) else { continue };
        let url = c.trim_end_matches('/').to_string();
        let ids = models["data"].as_array().into_iter().flatten().filter_map(|m| m["id"].as_str());
        if want_model.is_none_or(|w| ids.into_iter().any(|id| id == w)) {
            return Some(url);
        }
        first_live.get_or_insert(url);
    }
    first_live
}

/// The first live candidate whose model list includes `model`.
pub fn serving(candidates: &[&str], model: &str) -> Option<String> {
    candidates.iter().find_map(|c| {
        let models = fetch_models(c)?;
        let listed = models["data"].as_array()?.iter().any(|m| m["id"] == model);
        listed.then(|| c.trim_end_matches('/').to_string())
    })
}

/// The context window the server will actually use for `model`, when it says.
/// Tries vLLM (`max_model_len`), then LM Studio (`loaded_context_length`), then Ollama
/// (`/api/show`; capped at the default because agl sends that as `num_ctx`).
pub fn detect_context(base_url: &str, model: &str) -> Option<u32> {
    let base = base_url.trim_end_matches('/');
    let root = base.strip_suffix("/v1").unwrap_or(base);
    let as_u32 = |v: &serde_json::Value| v.as_u64().map(|n| n.min(u64::from(u32::MAX)) as u32);
    let vllm = fetch_models(base).and_then(|m| {
        let entry = m["data"].as_array()?.iter().find(|e| e["id"] == model)?.clone();
        as_u32(&entry["max_model_len"])
    });
    if vllm.is_some() {
        return vllm;
    }
    if let Some(v) = get_json(&format!("{root}/api/v0/models/{model}"))
        && let Some(n) = as_u32(&v["loaded_context_length"]).or_else(|| as_u32(&v["max_context_length"])) {
            return Some(n);
        }
    let show = post_json(&format!("{root}/api/show"), &serde_json::json!({"model": model}))?;
    let (_, n) = show["model_info"].as_object()?.iter().find(|(k, _)| k.ends_with(".context_length"))?;
    as_u32(n).map(|n| n.min(DEFAULT_CONTEXT_WINDOW))
}

/// LM Studio's pick from `/api/v0/models`: a loaded chat model that can call tools, then any
/// loaded chat model, then any that can call tools, then any. Its OpenAI list also holds speech
/// and embedding models (some typed "llm"), in no useful order.
pub fn pick_lmstudio_model(v0: &serde_json::Value) -> Option<String> {
    let chat: Vec<&serde_json::Value> =
        v0["data"].as_array()?.iter().filter(|m| m["type"] == "llm" || m["type"] == "vlm").collect();
    let tools = |m: &&&serde_json::Value| m["capabilities"].as_array().is_some_and(|c| c.iter().any(|c| c == "tool_use"));
    let loaded = |m: &&&serde_json::Value| m["state"] == "loaded";
    let best = chat.iter().find(|m| loaded(m) && tools(m))
        .or_else(|| chat.iter().find(|m| tools(m)))
        .or_else(|| chat.iter().find(|m| loaded(m)))
        .or(chat.first());
    best?["id"].as_str().map(String::from)
}

/// The first `data[].id` in an OpenAI `/models` response.
pub fn pick_model(models_json: &serde_json::Value) -> Option<String> {
    models_json["data"].as_array()?.first()?["id"].as_str().map(String::from)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil;
    use std::collections::HashMap;

    fn env_of(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let map: HashMap<String, String> =
            pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        move |k| map.get(k).cloned()
    }

    #[test]
    fn lmstudio_default_prefers_a_loaded_chat_model() {
        let v = serde_json::json!({"data": [
            {"id": "phonon-40m", "type": "tts", "state": "loaded"},
            {"id": "embed", "type": "embeddings", "state": "loaded"},
            {"id": "big", "type": "llm", "state": "not-loaded"},
            {"id": "qwen", "type": "vlm", "state": "loaded"},
        ]});
        assert_eq!(pick_lmstudio_model(&v).as_deref(), Some("qwen"));
        let v = serde_json::json!({"data": [
            {"id": "phonon-40m", "type": "llm", "state": "loaded"},
            {"id": "qwen", "type": "vlm", "state": "loaded", "capabilities": ["tool_use"]},
        ]});
        assert_eq!(pick_lmstudio_model(&v).as_deref(), Some("qwen"), "tool use wins");
        let v = serde_json::json!({"data": [{"id": "x", "type": "tts"}, {"id": "big", "type": "llm", "state": "not-loaded"}]});
        assert_eq!(pick_lmstudio_model(&v).as_deref(), Some("big"));
        assert_eq!(pick_lmstudio_model(&serde_json::json!({"data": [{"id": "x", "type": "tts"}]})), None);
    }

    #[test]
    fn serving_finds_only_a_server_listing_the_model() {
        let a = testutil::serve("application/json", r#"{"data":[{"id":"other"}]}"#.into());
        let b = testutil::serve("application/json", r#"{"data":[{"id":"want"}]}"#.into());
        let (dead, a_url, b_url) = (testutil::dead_url(), format!("{}/v1", a.base), format!("{}/v1", b.base));
        assert_eq!(serving(&[&dead, &a_url, &b_url], "want"), Some(b_url.clone()));
        assert_eq!(serving(&[&dead, &a_url], "want"), None);
    }

    #[test]
    fn flags_override_env_and_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        std::fs::write(
            &path,
            "base_url = \"http://file\"\nmodel = \"file-model\"\napi_key = \"file-key\"\ncontext_window = 8192\n",
        )
        .unwrap();
        let env = env_of(&[("AGL_MODEL", "env-model"), ("AGL_API_KEY", "env-key")]);
        let overrides = Overrides { base_url: Some("http://flag/".into()), ..Default::default() };
        let cfg = load_with_env(Some(&path), overrides, &env).unwrap();
        assert_eq!(cfg.base_url, "http://flag");
        assert_eq!(cfg.model, "env-model");
        assert_eq!(cfg.api_key.as_deref(), Some("env-key"));
        assert_eq!(cfg.context_window, 8192);
    }

    #[test]
    fn missing_file_is_not_error() {
        let dir = tempfile::tempdir().unwrap();
        let overrides = Overrides {
            base_url: Some("http://x".into()),
            model: Some("m".into()),
            ..Default::default()
        };
        let cfg = load_with_env(Some(&dir.path().join("nope.toml")), overrides, &|_| None).unwrap();
        assert_eq!(cfg.context_window, 32_768);
        assert_eq!(cfg.bash_timeout_secs, 120);
    }

    #[test]
    fn detect_skips_dead_ports() {
        let stub = testutil::serve("application/json", r#"{"data":[{"id":"qwen3.6"}]}"#.into());
        let dead = testutil::dead_url();
        let found = detect_endpoint(&[&dead, &stub.base], None).unwrap();
        assert_eq!(found, stub.base);
    }

    #[test]
    fn model_detected_when_unset() {
        let stub = testutil::serve("application/json", r#"{"data":[{"id":"qwen3.6"}]}"#.into());
        let overrides = Overrides { base_url: Some(stub.base.clone()), ..Default::default() };
        let cfg = load_with_env(None, overrides, &|_| None).unwrap();
        assert_eq!(cfg.model, "qwen3.6");
    }

    #[test]
    fn detect_prefers_server_with_requested_model() {
        let a = testutil::serve("application/json", r#"{"data":[{"id":"hermes3"}]}"#.into());
        let b = testutil::serve("application/json", r#"{"data":[{"id":"qwen-coder"}]}"#.into());
        assert_eq!(detect_endpoint(&[&a.base, &b.base], Some("qwen-coder")), Some(b.base.clone()));
        // No server has it: fall back to the first live one so the error names a real server.
        assert_eq!(detect_endpoint(&[&a.base, &b.base], Some("missing")), Some(a.base.clone()));
        assert_eq!(detect_endpoint(&[&a.base, &b.base], None), Some(a.base.clone()));
    }

    #[test]
    fn context_from_lm_studio_loaded_length() {
        let s = testutil::serve("application/json", r#"{"loaded_context_length":4096,"max_context_length":262144}"#.into());
        assert_eq!(detect_context(&format!("{}/v1", s.base), "m"), Some(4096));
    }

    #[test]
    fn context_from_ollama_capped_at_default() {
        let big = testutil::serve("application/json", r#"{"model_info":{"llama.context_length":131072}}"#.into());
        assert_eq!(detect_context(&format!("{}/v1", big.base), "m"), Some(32_768));
        let small = testutil::serve("application/json", r#"{"model_info":{"qwen2.context_length":8192}}"#.into());
        assert_eq!(detect_context(&format!("{}/v1", small.base), "m"), Some(8192));
    }

    #[test]
    fn context_from_vllm_max_model_len() {
        let s = testutil::serve("application/json", r#"{"data":[{"id":"m","max_model_len":16384}]}"#.into());
        assert_eq!(detect_context(&format!("{}/v1", s.base), "m"), Some(16384));
    }

    #[test]
    fn configured_context_beats_detection() {
        let s = testutil::serve("application/json", r#"{"data":[{"id":"m"}],"loaded_context_length":4096}"#.into());
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.toml");
        std::fs::write(&path, "context_window = 9000\n").unwrap();
        let o = Overrides { base_url: Some(s.base.clone()), model: Some("m".into()), ..Default::default() };
        assert_eq!(load_with_env(Some(&path), o.clone(), &|_| None).unwrap().context_window, 9000);
        assert_eq!(load_with_env(None, o, &|_| None).unwrap().context_window, 4096);
    }

    #[test]
    fn pick_model_first_id() {
        let v = serde_json::json!({"data":[{"id":"a"},{"id":"b"}]});
        assert_eq!(pick_model(&v).as_deref(), Some("a"));
        assert_eq!(pick_model(&serde_json::json!({"data":[]})), None);
    }
}
