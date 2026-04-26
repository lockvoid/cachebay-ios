//! Source ingestion: collect operation files + build an `apollo_compiler`
//! context with the schema and every executable document parsed+validated.

use std::path::{Path, PathBuf};

use anyhow::Context;
use apollo_compiler::{ExecutableDocument, Schema};
use walkdir::WalkDir;

use crate::config::CACHEBAY_DIRECTIVES_SDL;

pub struct CompilerContext {
    pub schema: apollo_compiler::validation::Valid<Schema>,
    pub documents: Vec<ExecutableDoc>,
    pub diagnostics: Vec<String>,
}

pub struct ExecutableDoc {
    pub source_path: PathBuf,
    pub doc: apollo_compiler::validation::Valid<ExecutableDocument>,
}

pub fn collect_operation_files(paths: &[PathBuf]) -> anyhow::Result<Vec<PathBuf>> {
    collect_operation_files_excluding(paths, &[])
}

pub fn collect_operation_files_excluding(
    paths: &[PathBuf],
    exclude: &[PathBuf],
) -> anyhow::Result<Vec<PathBuf>> {
    let canon_exclude: Vec<PathBuf> = exclude.iter().filter_map(|p| p.canonicalize().ok()).collect();
    let mut out = Vec::new();
    for p in paths {
        if p.is_file() {
            if !is_excluded(p, &canon_exclude) {
                out.push(p.clone());
            }
            continue;
        }
        if p.is_dir() {
            for entry in WalkDir::new(p) {
                let entry = entry.context("walking operations dir")?;
                let path = entry.path();
                if path.is_file() && has_graphql_extension(path) && !is_excluded(path, &canon_exclude) {
                    out.push(path.to_path_buf());
                }
            }
        }
    }
    out.sort();
    out.dedup();
    Ok(out)
}

fn is_excluded(p: &Path, exclude: &[PathBuf]) -> bool {
    if let Ok(canon) = p.canonicalize() {
        return exclude.iter().any(|e| *e == canon);
    }
    exclude.iter().any(|e| e == p)
}

fn has_graphql_extension(p: &Path) -> bool {
    matches!(
        p.extension().and_then(|s| s.to_str()),
        Some("graphql" | "gql")
    )
}

pub fn build_compiler(schema_src: &str, operation_files: &[PathBuf]) -> anyhow::Result<CompilerContext> {
    let mut diagnostics = Vec::new();

    // Parse schema with cachebay's custom directives injected.
    let combined_schema_src = format!("{schema_src}\n{CACHEBAY_DIRECTIVES_SDL}");
    let schema_result = Schema::parse_and_validate(&combined_schema_src, "schema.graphql");
    let schema = match schema_result {
        Ok(s) => s,
        Err(with_errors) => {
            for e in with_errors.errors.iter() {
                diagnostics.push(format!("schema: {e}"));
            }
            anyhow::bail!(
                "schema has {} validation error(s)",
                with_errors.errors.len()
            );
        }
    };

    // Parse every executable document against the validated schema.
    let mut documents = Vec::with_capacity(operation_files.len());
    for path in operation_files {
        let src = std::fs::read_to_string(path)
            .with_context(|| format!("reading operation file {}", path.display()))?;
        match ExecutableDocument::parse_and_validate(&schema, src.as_str(), path.to_string_lossy().as_ref()) {
            Ok(doc) => documents.push(ExecutableDoc {
                source_path: path.clone(),
                doc,
            }),
            Err(with_errors) => {
                for e in with_errors.errors.iter() {
                    diagnostics.push(format!("{}: {e}", path.display()));
                }
            }
        }
    }

    Ok(CompilerContext { schema, documents, diagnostics })
}
