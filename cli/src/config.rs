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

/// Parsed `cachebay.config.json`. Keeps a single coherent shape as the config
/// grows (scalars now; polymorphism; future knobs) so adding one never breaks
/// the file contract.
///
/// ```json
/// { "scalars": { "ISO8601DateTime": "Foundation.Date", "JSON": "Cachebay.JSONValue" },
///   "polymorphism": { "exhaustive": true } }
/// ```
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct CachebayConfig {
    /// Scalar → Swift-type overrides (merged with in-SDL `@cachebay(swiftType:)`).
    pub scalars: BTreeMap<String, String>,
    /// `polymorphism.exhaustive`: emit one interface/union case per schema
    /// implementor (not just per selected inline fragment). Opt-in — it adds
    /// enum cases, which is source-breaking for exhaustive switches.
    pub exhaustive_interfaces: bool,
}

/// Parse a `cachebay.config.json` body. A missing key takes its default;
/// **malformed JSON is an error** (a config that silently parses to nothing is
/// exactly the disease we're treating).
pub fn parse_config(json: &str) -> anyhow::Result<CachebayConfig> {
    let value: serde_json::Value = serde_json::from_str(json)
        .map_err(|e| anyhow::anyhow!("invalid {CONFIG_FILE_NAME}: {e}"))?;

    let mut scalars = BTreeMap::new();
    if let Some(map) = value.get("scalars").and_then(|v| v.as_object()) {
        for (name, ty) in map {
            if let Some(s) = ty.as_str() {
                scalars.insert(name.clone(), s.to_string());
            }
        }
    }

    let exhaustive_interfaces = value
        .get("polymorphism")
        .and_then(|p| p.get("exhaustive"))
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    Ok(CachebayConfig { scalars, exhaustive_interfaces })
}

/// Read + parse the config at `path`.
pub fn load_config(path: &Path) -> anyhow::Result<CachebayConfig> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| anyhow::anyhow!("reading {}: {e}", path.display()))?;
    parse_config(&text)
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
        let cfg = parse_config(
            r#"{ "scalars": { "ISO8601DateTime": "Foundation.Date", "JSON": "Cachebay.JSONValue" } }"#,
        )
        .unwrap();
        assert_eq!(cfg.scalars.get("ISO8601DateTime").map(String::as_str), Some("Foundation.Date"));
        assert_eq!(cfg.scalars.get("JSON").map(String::as_str), Some("Cachebay.JSONValue"));
        assert!(!cfg.exhaustive_interfaces, "absent polymorphism defaults off");
    }

    #[test]
    fn parse_reads_polymorphism_exhaustive() {
        let cfg = parse_config(r#"{ "polymorphism": { "exhaustive": true } }"#).unwrap();
        assert!(cfg.exhaustive_interfaces);
        assert!(cfg.scalars.is_empty());
    }

    #[test]
    fn parse_empty_when_no_keys() {
        let cfg = parse_config("{}").unwrap();
        assert!(cfg.scalars.is_empty());
        assert!(!cfg.exhaustive_interfaces);
    }

    #[test]
    fn parse_errors_on_malformed_json() {
        assert!(parse_config("{ not json").is_err());
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
