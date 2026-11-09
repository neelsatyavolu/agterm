//! Coding models agl can download. Each file was checked to exist on Hugging Face on 2026-11-08.

#[derive(Debug, PartialEq)]
pub struct Entry {
    pub name: &'static str,
    pub repo: &'static str,
    pub file: &'static str,
    pub size_gb: f32,
    pub about: &'static str,
}

pub const CATALOG: [Entry; 6] = [
    Entry {
        name: "qwen3-coder-30b",
        repo: "unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF",
        file: "Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf",
        size_gb: 18.6,
        about: "recommended: fast (3B active), strong at tool calls; 32 GB RAM",
    },
    Entry {
        name: "devstral-small-2",
        repo: "unsloth/Devstral-Small-2-24B-Instruct-2512-GGUF",
        file: "Devstral-Small-2-24B-Instruct-2512-Q4_K_M.gguf",
        size_gb: 14.3,
        about: "Mistral's agentic coding model; 24 GB RAM",
    },
    Entry {
        name: "gpt-oss-20b",
        repo: "unsloth/gpt-oss-20b-GGUF",
        file: "gpt-oss-20b-Q4_K_M.gguf",
        size_gb: 11.6,
        about: "OpenAI's open model, reasons before answering; 16 GB RAM",
    },
    Entry {
        name: "qwen2.5-coder-7b",
        repo: "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF",
        file: "qwen2.5-coder-7b-instruct-q4_k_m.gguf",
        size_gb: 4.7,
        about: "small and quick; 8 GB RAM",
    },
    Entry {
        name: "qwen3-4b",
        repo: "unsloth/Qwen3-4B-Instruct-2507-GGUF",
        file: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        size_gb: 2.5,
        about: "smallest; for laptops, simple edits",
    },
    Entry {
        name: "qwen3-coder-next",
        repo: "unsloth/Qwen3-Coder-Next-GGUF",
        file: "Qwen3-Coder-Next-Q4_K_M.gguf",
        size_gb: 48.5,
        about: "largest and best; 64 GB RAM",
    },
];

/// The catalog entry called `name`.
pub fn find(name: &str) -> Option<&'static Entry> {
    CATALOG.iter().find(|e| e.name == name)
}

impl Entry {
    /// Where the file downloads from.
    pub fn url(&self) -> String {
        hf_url(self.repo, self.file)
    }
}

/// `hf:owner/repo/file.gguf` → (local name, download URL). The name is the file's stem, lowercased.
pub fn parse_hf(spec: &str) -> Option<(String, String)> {
    let rest = spec.strip_prefix("hf:")?;
    let mut parts = rest.splitn(3, '/');
    let (owner, repo, file) = (parts.next()?, parts.next()?, parts.next()?);
    if owner.is_empty() || repo.is_empty() || !file.ends_with(".gguf") {
        return None;
    }
    let stem = file.rsplit('/').next()?.trim_end_matches(".gguf").to_lowercase();
    Some((stem, hf_url(&format!("{owner}/{repo}"), file)))
}

fn hf_url(repo: &str, file: &str) -> String {
    format!("https://huggingface.co/{repo}/resolve/main/{file}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_unique_and_files_are_gguf() {
        for (i, e) in CATALOG.iter().enumerate() {
            assert!(e.file.ends_with(".gguf"), "{}", e.file);
            assert!(CATALOG[i + 1..].iter().all(|o| o.name != e.name), "{}", e.name);
        }
    }

    #[test]
    fn find_by_name_and_url() {
        let e = find("qwen3-4b").unwrap();
        assert_eq!(
            e.url(),
            "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/main/Qwen3-4B-Instruct-2507-Q4_K_M.gguf"
        );
        assert!(find("nope").is_none());
    }

    #[test]
    fn hf_specs() {
        assert_eq!(
            parse_hf("hf:bartowski/X-GGUF/X-Q4_K_M.gguf"),
            Some(("x-q4_k_m".into(), "https://huggingface.co/bartowski/X-GGUF/resolve/main/X-Q4_K_M.gguf".into()))
        );
        assert_eq!(parse_hf("hf:a/b/sub/c.gguf").unwrap().1, "https://huggingface.co/a/b/resolve/main/sub/c.gguf");
        assert_eq!(parse_hf("hf:a/b"), None);
        assert_eq!(parse_hf("hf:a/b/c.bin"), None);
        assert_eq!(parse_hf("qwen3-4b"), None);
    }
}
