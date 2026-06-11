//! Cachebay-specific directive recognition. `@connection(mode: "…", filters: […], key: "…")`
//! isn't in the GraphQL spec — it's our cache-layer annotation.
//!
//! apollo-compiler will happily parse + validate unknown directives as long as
//! we tell its schema about them. We inject a synthetic type-system extension
//! into the user's SDL before handing it to the compiler.

pub const CACHEBAY_DIRECTIVES_SDL: &str = r#"
directive @connection(
  mode: String
  filters: [String!]
  key: String
) on FIELD
"#;

use std::collections::BTreeMap;
use std::path::Path;

/// `cachebay.config.json` filename, discovered next to the schema (overridable
/// via `--config`).
pub const CONFIG_FILE_NAME: &str = "cachebay.config.json";

/// Parse the `scalars` map from a `cachebay.config.json` body:
/// `{ "scalars": { "ISO8601DateTime": "Foundation.Date", "JSON": "Cachebay.JSONValue" } }`.
/// A missing/empty `scalars` key yields an empty map; **malformed JSON is an
/// error** (a config that silently parses to nothing is exactly the disease we're
/// treating).
pub fn parse_scalar_config(json: &str) -> anyhow::Result<BTreeMap<String, String>> {
    let value: serde_json::Value = serde_json::from_str(json)
        .map_err(|e| anyhow::anyhow!("invalid {CONFIG_FILE_NAME}: {e}"))?;
    let mut out = BTreeMap::new();
    if let Some(scalars) = value.get("scalars").and_then(|v| v.as_object()) {
        for (name, ty) in scalars {
            if let Some(s) = ty.as_str() {
                out.insert(name.clone(), s.to_string());
            }
        }
    }
    Ok(out)
}

/// Read + parse the scalar config at `path`.
pub fn load_scalar_config(path: &Path) -> anyhow::Result<BTreeMap<String, String>> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| anyhow::anyhow!("reading {}: {e}", path.display()))?;
    parse_scalar_config(&text)
}

/// Merge in-SDL `@cachebay(swiftType:)` mappings (`sdl`) with `config` scalars.
/// **No silent precedence**: if both define a scalar and DISAGREE, it's a hard
/// error. Agreeing or disjoint definitions union cleanly.
pub fn merge_scalar_types(
    sdl: &BTreeMap<String, String>,
    config: &BTreeMap<String, String>,
) -> anyhow::Result<BTreeMap<String, String>> {
    let mut merged = sdl.clone();
    for (name, cfg_type) in config {
        if let Some(sdl_type) = sdl.get(name) {
            if sdl_type != cfg_type {
                anyhow::bail!(
                    "scalar `{name}`: {CONFIG_FILE_NAME} maps it to `{cfg_type}` but the schema's @cachebay(swiftType: \"{sdl_type}\") disagrees — define it in one place."
                );
            }
        }
        merged.insert(name.clone(), cfg_type.clone());
    }
    Ok(merged)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_reads_scalars_map() {
        let cfg = parse_scalar_config(
            r#"{ "scalars": { "ISO8601DateTime": "Foundation.Date", "JSON": "Cachebay.JSONValue" } }"#,
        )
        .unwrap();
        assert_eq!(cfg.get("ISO8601DateTime").map(String::as_str), Some("Foundation.Date"));
        assert_eq!(cfg.get("JSON").map(String::as_str), Some("Cachebay.JSONValue"));
    }

    #[test]
    fn parse_empty_when_no_scalars_key() {
        assert!(parse_scalar_config(r#"{ "other": 1 }"#).unwrap().is_empty());
        assert!(parse_scalar_config("{}").unwrap().is_empty());
    }

    #[test]
    fn parse_errors_on_malformed_json() {
        assert!(parse_scalar_config("{ not json").is_err());
    }

    #[test]
    fn merge_unions_disjoint_and_agreeing() {
        let sdl = BTreeMap::from([("Date".to_string(), "Foundation.Date".to_string())]);
        let config = BTreeMap::from([
            ("JSON".to_string(), "Cachebay.JSONValue".to_string()),
            ("Date".to_string(), "Foundation.Date".to_string()), // agrees with SDL
        ]);
        let merged = merge_scalar_types(&sdl, &config).unwrap();
        assert_eq!(merged.get("Date").map(String::as_str), Some("Foundation.Date"));
        assert_eq!(merged.get("JSON").map(String::as_str), Some("Cachebay.JSONValue"));
    }

    #[test]
    fn merge_hard_errors_on_disagreement() {
        let sdl = BTreeMap::from([("Date".to_string(), "Foundation.Date".to_string())]);
        let config = BTreeMap::from([("Date".to_string(), "My.Other.Date".to_string())]);
        let err = merge_scalar_types(&sdl, &config).unwrap_err().to_string();
        assert!(err.contains("Date") && err.contains("disagree"), "{err}");
    }
}
