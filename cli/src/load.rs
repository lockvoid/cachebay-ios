//! Source ingestion: collect operation files and produce a single validated
//! `ExecutableDocument` whose definitions are sourced from across the entire
//! `--operations` tree.
//!
//! Cross-file fragment resolution: the GraphQL community convention is to
//! define reusable fragments (`Fragments/UserFragment.graphql`) separately
//! from operations that spread them (`Queries/MeQuery.graphql`). Validating
//! each file independently would surface "fragment X is not defined" because
//! the fragment lives in a sibling file. The fix is to parse each file as an
//! AST, merge `definitions` + `sources` into one `ast::Document`, and
//! validate that combined document once. apollo-compiler assigns a unique
//! `FileId` per parse, so per-operation source attribution survives the
//! merge — `node.location().file_id()` keys back into the merged source map
//! to recover the original `.graphql` path for the emitted `// Source:`
//! comment.
//!
//! Concretely: we no longer return a `Vec<ExecutableDoc>`. We return one
//! validated document plus a `FileId → PathBuf` index, and consumers
//! (`plan.rs`, `schema.rs`) iterate operations/fragments from that single
//! document.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::Context;
use apollo_compiler::parser::{FileId, SourceSpan};
use apollo_compiler::validation::Valid;
use apollo_compiler::{ast, ExecutableDocument, Schema};
use walkdir::WalkDir;

use crate::config::CACHEBAY_DIRECTIVES_SDL;

pub struct CompilerContext {
    pub schema: apollo_compiler::validation::Valid<Schema>,
    pub document: apollo_compiler::validation::Valid<ExecutableDocument>,
    pub file_paths: HashMap<FileId, PathBuf>,
    pub diagnostics: Vec<String>,
}

impl CompilerContext {
    /// Resolve the source `.graphql` path for an AST node, given its
    /// `Node::location()`. Falls back to "<unknown>" if the node was
    /// synthesized without a location (e.g. injected `__typename`).
    pub fn source_path_for(&self, location: Option<SourceSpan>) -> String {
        location
            .and_then(|s| self.file_paths.get(&s.file_id()))
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|| "<unknown>".to_string())
    }
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

    // Parse each .graphql file into its own AST so apollo-compiler assigns a
    // distinct FileId per file. We then merge the ASTs into one combined
    // document so fragment spreads can resolve across files.
    let mut combined = ast::Document::new();
    let mut file_paths: HashMap<FileId, PathBuf> = HashMap::new();

    for path in operation_files {
        let src = std::fs::read_to_string(path)
            .with_context(|| format!("reading operation file {}", path.display()))?;
        let path_str = path.to_string_lossy().into_owned();
        match ast::Document::parse(src, &path_str) {
            Ok(doc) => {
                // The parser stamps every definition with the FileId it
                // assigned to this parse. Pull that ID off the first node we
                // see so we can map it back to the source path later.
                if let Some(file_id) = first_file_id(&doc) {
                    file_paths.insert(file_id, path.clone());
                }
                merge_ast(&mut combined, doc);
            }
            Err(with_errors) => {
                for e in with_errors.errors.iter() {
                    diagnostics.push(format!("{}: {e}", path.display()));
                }
            }
        }
    }

    if !diagnostics.is_empty() {
        return Ok(CompilerContext {
            schema,
            document: empty_executable(),
            file_paths,
            diagnostics,
        });
    }

    let document = match combined.to_executable_validate(&schema) {
        Ok(doc) => doc,
        Err(with_errors) => {
            for e in with_errors.errors.iter() {
                diagnostics.push(format!("{e}"));
            }
            return Ok(CompilerContext {
                schema,
                document: empty_executable(),
                file_paths,
                diagnostics,
            });
        }
    };

    Ok(CompilerContext { schema, document, file_paths, diagnostics })
}

/// Pull the `FileId` off the first definition (or source map entry) of a
/// freshly-parsed AST. apollo-compiler stamps every node + every entry in
/// `Document::sources` with the same FileId per parse, so any of them works.
fn first_file_id(doc: &ast::Document) -> Option<FileId> {
    if let Some(def) = doc.definitions.first() {
        if let Some(span) = definition_location(def) {
            return Some(span.file_id());
        }
    }
    doc.sources.keys().next().copied()
}

fn definition_location(def: &ast::Definition) -> Option<SourceSpan> {
    match def {
        ast::Definition::OperationDefinition(n) => n.location(),
        ast::Definition::FragmentDefinition(n) => n.location(),
        ast::Definition::DirectiveDefinition(n) => n.location(),
        ast::Definition::SchemaDefinition(n) => n.location(),
        ast::Definition::ScalarTypeDefinition(n) => n.location(),
        ast::Definition::ObjectTypeDefinition(n) => n.location(),
        ast::Definition::InterfaceTypeDefinition(n) => n.location(),
        ast::Definition::UnionTypeDefinition(n) => n.location(),
        ast::Definition::EnumTypeDefinition(n) => n.location(),
        ast::Definition::InputObjectTypeDefinition(n) => n.location(),
        ast::Definition::SchemaExtension(n) => n.location(),
        ast::Definition::ScalarTypeExtension(n) => n.location(),
        ast::Definition::ObjectTypeExtension(n) => n.location(),
        ast::Definition::InterfaceTypeExtension(n) => n.location(),
        ast::Definition::UnionTypeExtension(n) => n.location(),
        ast::Definition::EnumTypeExtension(n) => n.location(),
        ast::Definition::InputObjectTypeExtension(n) => n.location(),
    }
}

/// Merge `incoming` into `target`: append definitions and union the source
/// maps. apollo-compiler uses an `Arc<IndexMap<...>>` for sources, so we
/// `Arc::make_mut` and insert.
fn merge_ast(target: &mut ast::Document, incoming: ast::Document) {
    target.definitions.extend(incoming.definitions);
    let target_sources = std::sync::Arc::make_mut(&mut target.sources);
    for (id, src) in incoming.sources.iter() {
        target_sources.insert(*id, src.clone());
    }
}

/// Construct an empty validated executable document. Used when validation
/// fails so we can still return the diagnostics-bearing context to the
/// caller, who will surface the errors and exit non-zero.
fn empty_executable() -> Valid<ExecutableDocument> {
    Valid::assume_valid(ExecutableDocument::new())
}
