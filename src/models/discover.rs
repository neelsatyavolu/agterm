//! Models already on this Mac: agl's own, LM Studio's and Ollama's.

use serde_json::Value;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Agl,
    LmStudio,
    Ollama,
}

impl Source {
    pub fn label(self) -> &'static str {
        match self {
            Self::Agl => "agl",
            Self::LmStudio => "LM Studio",
            Self::Ollama => "Ollama",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Installed {
    /// What `--model` takes: agl's name, LM Studio's model key, or Ollama's `name:tag`.
    pub name: String,
    pub source: Source,
    pub bytes: u64,
    /// The GGUF file, for models agl runs itself.
    pub path: Option<PathBuf>,
}

/// agl's downloaded models.
pub fn agl(dir: &Path) -> Vec<Installed> {
    super::store::list(dir)
        .into_iter()
        .map(|(name, path, bytes)| Installed { name, source: Source::Agl, bytes, path: Some(path) })
        .collect()
}

/// LM Studio's chat models, from `lms ls --json`. Embedding models are left out.
pub fn lmstudio_from_json(json: &str) -> Vec<Installed> {
    let Ok(Value::Array(items)) = serde_json::from_str::<Value>(json) else { return Vec::new() };
    items
        .iter()
        .filter(|m| m["type"] == "llm")
        .filter_map(|m| {
            let name = m["modelKey"].as_str()?.to_string();
            Some(Installed { name, source: Source::LmStudio, bytes: m["sizeBytes"].as_u64().unwrap_or(0), path: None })
        })
        .collect()
}

/// Runs `lms ls --json`; empty when LM Studio isn't installed.
pub fn lmstudio(lms: &Path) -> Vec<Installed> {
    std::process::Command::new(lms)
        .args(["ls", "--json"])
        .stderr(std::process::Stdio::null())
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| lmstudio_from_json(&String::from_utf8_lossy(&o.stdout)))
        .unwrap_or_default()
}

/// Ollama's models, from its manifests under `models_root` (`~/.ollama/models`). A model whose
/// weights file is missing (a broken pull) is left out.
pub fn ollama(models_root: &Path) -> Vec<Installed> {
    let library = models_root.join("manifests/registry.ollama.ai/library");
    let mut v = Vec::new();
    for model in std::fs::read_dir(&library).into_iter().flatten().flatten() {
        let name = model.file_name().to_string_lossy().into_owned();
        for tag in std::fs::read_dir(model.path()).into_iter().flatten().flatten() {
            let Ok(text) = std::fs::read_to_string(tag.path()) else { continue };
            let Ok(manifest) = serde_json::from_str::<Value>(&text) else { continue };
            let weights = manifest["layers"].as_array().into_iter().flatten()
                .find(|l| l["mediaType"] == "application/vnd.ollama.image.model")
                .and_then(|l| l["digest"].as_str())
                .map(|d| models_root.join("blobs").join(d.replace(':', "-")));
            let Some(bytes) = weights.and_then(|w| std::fs::metadata(w).ok()).map(|m| m.len()) else { continue };
            let tag = tag.file_name().to_string_lossy().into_owned();
            v.push(Installed { name: format!("{name}:{tag}"), source: Source::Ollama, bytes, path: None });
        }
    }
    v.sort_by(|a, b| a.name.cmp(&b.name));
    v
}

/// Every installed model: agl's, then LM Studio's, then Ollama's.
pub fn all() -> Vec<Installed> {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let ollama_root = std::env::var_os("OLLAMA_MODELS").map(PathBuf::from).unwrap_or_else(|| home.join(".ollama/models"));
    let mut v = agl(&super::store::dir());
    v.extend(lmstudio(&home.join(".lmstudio/bin/lms")));
    v.extend(ollama(&ollama_root));
    v
}

/// The installed model `name` names: an exact match, or `name:latest` for Ollama.
pub fn lookup<'a>(installed: &'a [Installed], name: &str) -> Option<&'a Installed> {
    let latest = format!("{name}:latest");
    installed.iter().find(|m| m.name == name).or_else(|| installed.iter().find(|m| m.name == latest))
}

#[cfg(test)]
mod tests {
    use super::*;

    const LMS: &str = r#"[{"type":"llm","modelKey":"qwen3.8-27b-splash","format":"yuzu","path":"incoai/Qwen3.8-27B-Splash","sizeBytes":17382672684},
        {"type":"embedding","modelKey":"text-embedding-x","sizeBytes":1},
        {"type":"llm","modelKey":"small","format":"gguf","path":"a/b/small.gguf","sizeBytes":5}]"#;

    #[test]
    fn lmstudio_lists_chat_models_only() {
        let v = lmstudio_from_json(LMS);
        let names: Vec<&str> = v.iter().map(|m| m.name.as_str()).collect();
        assert_eq!(names, vec!["qwen3.8-27b-splash", "small"]);
        assert_eq!(v[0].bytes, 17_382_672_684);
        assert_eq!(v[0].source, Source::LmStudio);
        assert!(v.iter().all(|m| m.path.is_none()), "LM Studio runs its own models");
        assert!(lmstudio_from_json("not json").is_empty());
    }

    fn manifest(root: &Path, name: &str, tag: &str, digest: &str, blob: Option<usize>) {
        let dir = root.join("manifests/registry.ollama.ai/library").join(name);
        std::fs::create_dir_all(&dir).unwrap();
        let m = format!(
            r#"{{"layers":[{{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:{digest}","size":9}},
               {{"mediaType":"application/vnd.ollama.image.template","digest":"sha256:t","size":1}}]}}"#
        );
        std::fs::write(dir.join(tag), m).unwrap();
        if let Some(n) = blob {
            std::fs::create_dir_all(root.join("blobs")).unwrap();
            std::fs::write(root.join(format!("blobs/sha256-{digest}")), vec![0u8; n]).unwrap();
        }
    }

    #[test]
    fn ollama_lists_models_with_weights() {
        let root = tempfile::tempdir().unwrap();
        manifest(root.path(), "qwen2.5-coder", "7b", "aaa", Some(3));
        manifest(root.path(), "broken", "latest", "bbb", None);
        manifest(root.path(), "hermes", "latest", "ccc", Some(4));
        let v = ollama(root.path());
        let names: Vec<(&str, u64)> = v.iter().map(|m| (m.name.as_str(), m.bytes)).collect();
        assert_eq!(names, vec![("hermes:latest", 4), ("qwen2.5-coder:7b", 3)]);
        assert_eq!(v[0].source, Source::Ollama);
        assert!(ollama(&root.path().join("none")).is_empty());
    }

    #[test]
    fn lookup_exact_or_latest() {
        let m = |n: &str, s| Installed { name: n.into(), source: s, bytes: 0, path: None };
        let v = vec![m("qwen3-4b", Source::Agl), m("hermes:latest", Source::Ollama), m("q:7b", Source::Ollama)];
        assert_eq!(lookup(&v, "qwen3-4b").unwrap().source, Source::Agl);
        assert_eq!(lookup(&v, "hermes").unwrap().name, "hermes:latest");
        assert!(lookup(&v, "q").is_none());
        assert!(lookup(&v, "zzz").is_none());
    }
}
