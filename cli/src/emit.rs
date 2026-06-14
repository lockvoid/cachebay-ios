//! Swift emitter. Produces one file per operation/fragment plus a shared
//! `CachebayGenerated.swift` declaring the `Variables`/`Data` baselines.
//!
//! The generated code is deliberately minimal: typed `Variables` structs,
//! typed `Data` structs with thin accessors over the cache's materialized
//! `[String: Cachebay.JSONValue]`, and a pre-baked `CachePlan` constant per operation.
//!
//! Nothing exotic — no enum generation, no input-object generation in this MVP.
//! Those extend cleanly once the pipeline is proven.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;

use crate::plan::{ArgPiece, ConnectionMode, OpKind, OutputShape, Plan, PlanField};
use crate::schema::{EnumTypeDef, InputField, InputTypeDef, TypeKind, TypeShape};

/// GraphQL response key for a connection's edge list. The connection's edge type
/// is the named type of this child field.
const CONNECTION_EDGES_KEY: &str = "edges";

/// Built-in GraphQL scalars — always typed (`swift_type_for_shape`), never warned.
const BUILTIN_SCALARS: &[&str] = &["Int", "Float", "String", "Boolean", "ID"];

/// A custom scalar used by operations that has no `swiftType` mapping, so codegen
/// emits its fields as untyped `Cachebay.JSONValue`. Surfaced as a build warning
/// (one per scalar, with blast-radius counts) so an untyped field is a deliberate
/// choice, not a silent default. `non_null` counts the non-null uses — the
/// fake-optionality sites where a `Foo!` collapses to `JSONValue` and loses its
/// non-null typing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnmappedScalarWarning {
    pub scalar: String,
    pub uses: usize,
    pub non_null: usize,
}

/// A field whose type is a custom scalar with no `swiftType` mapping → emitted as
/// `Cachebay.JSONValue`. Built-ins, enums (`swift_enum_type`), and explicitly
/// mapped scalars (`swift_scalar_type`, including `"Cachebay.JSONValue"`) are
/// excluded — the last is the deliberate "I mean it" silencer.
fn is_unmapped_custom_scalar(f: &PlanField) -> bool {
    matches!(f.output_shape, OutputShape::Leaf { .. })
        && f.swift_enum_type.is_none()
        && f.swift_scalar_type.is_none()
        && !BUILTIN_SCALARS.contains(&f.named_type.as_str())
}

/// Walk every operation's selection tree and tally unmapped custom scalars — one
/// entry per scalar, with total + non-null use counts, sorted by scalar name.
pub fn collect_unmapped_scalar_warnings(plans: &[Plan]) -> Vec<UnmappedScalarWarning> {
    fn walk(fields: &[PlanField], tally: &mut BTreeMap<String, (usize, usize)>) {
        for f in fields {
            if is_unmapped_custom_scalar(f) {
                let entry = tally.entry(f.named_type.clone()).or_insert((0, 0));
                entry.0 += 1;
                if let OutputShape::Leaf { nullable: false, .. } = f.output_shape {
                    entry.1 += 1;
                }
            }
            walk(&f.children, tally);
        }
    }
    let mut tally: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    for plan in plans {
        walk(&plan.root, &mut tally);
    }
    tally
        .into_iter()
        .map(|(scalar, (uses, non_null))| UnmappedScalarWarning { scalar, uses, non_null })
        .collect()
}

/// Under `polymorphism.exhaustive`, an interface selection's cases are derived
/// from the SCHEMA implementor list — so an inline fragment that narrows via
/// ANOTHER interface (`... on Captionable` inside an `Element` selection) is not
/// a concrete implementor and would silently vanish from the generated enum.
/// Reject it loudly (a hard error) rather than drop fields. Run only when the
/// flag is on — non-exhaustive mode keeps such a condition as its own case.
pub fn validate_exhaustive(
    plans: &[Plan],
    interfaces: &BTreeMap<String, Vec<String>>,
) -> anyhow::Result<()> {
    fn walk(fields: &[PlanField], interfaces: &BTreeMap<String, Vec<String>>) -> anyhow::Result<()> {
        for f in fields {
            if let Some(implementors) = interfaces.get(&f.named_type) {
                for child in &f.children {
                    if let Some(tc) = &child.type_condition {
                        if tc != &f.named_type && !implementors.contains(tc) {
                            anyhow::bail!(
                                "selection narrows `{}` via `{}`, not a concrete implementor — unsupported under polymorphism.exhaustive (it would silently drop `{}`'s fields). Use a concrete-implementor inline fragment, or turn exhaustive off.",
                                f.named_type, tc, tc
                            );
                        }
                    }
                }
            }
            walk(&f.children, interfaces)?;
        }
        Ok(())
    }
    for plan in plans {
        walk(&plan.root, interfaces)?;
    }
    Ok(())
}

/// Cross-cutting state threaded through the typed emitter — bundled so adding a
/// knob (interfaces map, exhaustive flag) doesn't ripple a new parameter through
/// every render function.
#[derive(Clone, Copy)]
struct EmitCtx<'a> {
    /// Fragments whose `Data` is Codable-safe (so a struct spreading them can be).
    safe_fragments: &'a BTreeSet<String>,
    /// Interface/union → schema implementor type names (for exhaustive cases).
    interfaces: &'a BTreeMap<String, Vec<String>>,
    /// `polymorphism.exhaustive`: emit one case per schema implementor, not just
    /// per selected inline fragment.
    exhaustive: bool,
}

static EMPTY_SAFE_FRAGMENTS: BTreeSet<String> = BTreeSet::new();
static EMPTY_INTERFACES: BTreeMap<String, Vec<String>> = BTreeMap::new();

impl EmitCtx<'static> {
    /// No fragments/interfaces, exhaustive off — for the simple `render_typed_*`
    /// wrappers and unit tests of non-exhaustive shapes.
    fn bare() -> Self {
        EmitCtx {
            safe_fragments: &EMPTY_SAFE_FRAGMENTS,
            interfaces: &EMPTY_INTERFACES,
            exhaustive: false,
        }
    }
}

pub fn write_all(
    plans: &[Plan],
    inputs: &BTreeMap<String, InputTypeDef>,
    enums: &BTreeMap<String, EnumTypeDef>,
    interfaces: &BTreeMap<String, Vec<String>>,
    out_dir: &Path,
    namespace: &str,
    exhaustive: bool,
) -> anyhow::Result<()> {
    // Build the COMPLETE output set in memory first, then reconcile the directory.
    // Nothing on disk is touched until every file is generated, so a generation
    // failure leaves existing output untouched; unchanged files aren't rewritten,
    // so a no-op regen doesn't invalidate the generated SwiftPM target.
    let mut files: BTreeMap<String, String> = BTreeMap::new();
    if !enums.is_empty() {
        files.insert("Enums.graphql.swift".into(), render_enums(enums));
    }
    if !inputs.is_empty() {
        files.insert("Inputs.graphql.swift".into(), render_inputs(inputs));
    }
    // The namespace enum is declared once (here); each operation/fragment file extends it.
    files.insert("Schema.graphql.swift".into(), render_schema(interfaces, namespace));
    // Which fragments' `Data` are Codable (concrete subtree, no interface enum) —
    // so a struct that spreads them can itself be Codable.
    let safe_fragments = compute_safe_fragments(plans);
    let ctx = EmitCtx { safe_fragments: &safe_fragments, interfaces, exhaustive };
    for plan in plans {
        files.insert(
            format!("{}.graphql.swift", plan.name),
            wrap_in_namespace(render_typed_plan_impl(plan, &ctx), namespace),
        );
    }
    reconcile_output_dir(out_dir, &files)?;
    Ok(())
}

/// Outcome of `reconcile_output_dir`, surfaced for tests/telemetry.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ReconcileStats {
    pub written: usize,
    pub skipped: usize,
    pub deleted: usize,
}

/// Bring `out_dir` in line with the generated `files` set, atomically and
/// minimally:
///
/// 1. **Writes first** — each changed file is written to a temp sibling and
///    `rename`d into place (atomic per file); byte-identical files are skipped so
///    a no-op regen leaves mtimes stable. If any write fails we return early,
///    *before* step 2, so a failed run never removes existing output.
/// 2. **Deletes last** — `*.graphql.swift` files we did NOT generate this run are
///    swept (renamed/removed operations don't linger as orphans). Files with any
///    other extension are left untouched.
pub fn reconcile_output_dir(
    out_dir: &Path,
    files: &BTreeMap<String, String>,
) -> std::io::Result<ReconcileStats> {
    fs::create_dir_all(out_dir)?;
    let mut stats = ReconcileStats::default();

    // 1. Writes (changed only), atomic per file.
    for (name, content) in files {
        let path = out_dir.join(name);
        if fs::read_to_string(&path).map(|cur| cur == *content).unwrap_or(false) {
            stats.skipped += 1;
            continue;
        }
        let tmp = out_dir.join(format!(".{name}.tmp"));
        fs::write(&tmp, content)?;
        fs::rename(&tmp, &path)?;
        stats.written += 1;
    }

    // 2. Sweep stale generated files (only AFTER every write succeeded).
    for entry in fs::read_dir(out_dir)? {
        let entry = entry?;
        let fname = entry.file_name().to_string_lossy().into_owned();
        if fname.ends_with(".graphql.swift") && !files.contains_key(&fname) {
            fs::remove_file(entry.path())?;
            stats.deleted += 1;
        }
    }

    Ok(stats)
}

/// Wrap a typed operation/fragment file's struct in `extension <namespace> { … }`
/// so generated model types don't collide with consumer/SDK types
/// (`Image`/`Video`/`Color`/…). Imports stay at file scope. No-op when empty.
fn wrap_in_namespace(contents: String, namespace: &str) -> String {
    if namespace.is_empty() {
        return contents;
    }
    match contents.find("public struct ") {
        Some(idx) => {
            let (header, decl) = contents.split_at(idx);
            format!("{header}extension {namespace} {{\n{decl}}}\n")
        }
        None => contents,
    }
}

/// Schema-level constants the runtime reads at client construction.
/// Currently just the interface→implementers map (consumed by
/// `CachebayOptions.interfaces`); future schema-derived knobs (custom
/// scalar serialisers, type-policy keyFields, …) belong here too.
fn render_schema(interfaces: &BTreeMap<String, Vec<String>>, namespace: &str) -> String {
    let mut s = String::new();
    s.push_str("// Generated by cachebay-cli. DO NOT EDIT.\n\n");
    s.push_str("import Cachebay\n\n");
    if !namespace.is_empty() {
        s.push_str(&format!("/// Namespace for generated typed models (`{namespace}.GetCook`, …).\n"));
        s.push_str(&format!("public enum {namespace} {{}}\n\n"));
    }
    s.push_str("/// Generated schema metadata. Pass `CachebaySchema.interfaces`\n");
    s.push_str("/// to `CachebayOptions.interfaces` so the runtime knows which\n");
    s.push_str("/// concrete types implement which interfaces — required for\n");
    s.push_str("/// `fragment X on InterfaceName { ... }` to apply against the\n");
    s.push_str("/// concrete records when normalising/materialising.\n");
    s.push_str("public enum CachebaySchema {\n");
    if interfaces.is_empty() {
        // Swift parses `[]` as Array literal; the empty Dictionary
        // literal is `[:]`. Emit the dict form so consumers that have
        // no interfaces still get a valid `[String: [String]]` value.
        s.push_str("    public static let interfaces: [String: [String]] = [:]\n");
    } else {
        s.push_str("    public static let interfaces: [String: [String]] = [\n");
        for (iface, impls) in interfaces {
            let inner = impls
                .iter()
                .map(|n| format!("\"{}\"", n))
                .collect::<Vec<_>>()
                .join(", ");
            s.push_str(&format!("        \"{}\": [{}],\n", iface, inner));
        }
        s.push_str("    ]\n");
    }
    s.push_str("}\n");
    s
}

fn render_enums(enums: &BTreeMap<String, EnumTypeDef>) -> String {
    let mut s = String::new();
    s.push_str("// Generated by cachebay-cli. DO NOT EDIT.\n\n");
    s.push_str("import Cachebay\n\n");
    for (_, t) in enums {
        s.push_str(&format!("public enum {}: String, Codable, Sendable, CaseIterable {{\n", t.name));
        for v in &t.values {
            let ident = swift_identifier(&v.to_lowercased_camel());
            if ident == *v {
                s.push_str(&format!("    case {}\n", ident));
            } else {
                s.push_str(&format!("    case {} = \"{}\"\n", ident, v));
            }
        }
        s.push_str("}\n\n");
    }
    s
}

/// Trait-like helper on String to produce a Swift-friendly case name from an
/// enum value (e.g. `NAME_ASC` → `nameAsc`). We still emit `= "NAME_ASC"` so
/// server serialization is preserved.
trait EnumCaseName { fn to_lowercased_camel(&self) -> String; }
impl EnumCaseName for String {
    fn to_lowercased_camel(&self) -> String {
        let mut out = String::with_capacity(self.len());
        let mut upper_next = false;
        for (i, c) in self.chars().enumerate() {
            if c == '_' { upper_next = true; continue; }
            if i == 0 { out.push(c.to_ascii_lowercase()); }
            else if upper_next { out.push(c); upper_next = false; }
            else { out.push(c.to_ascii_lowercase()); }
        }
        out
    }
}

fn render_inputs(inputs: &BTreeMap<String, InputTypeDef>) -> String {
    let mut s = String::new();
    s.push_str("// Generated by cachebay-cli. DO NOT EDIT.\n\n");
    s.push_str("import Cachebay\n\n");
    for (_, t) in inputs {
        // `@oneOf` members keep plain `Optional` (explicit null is invalid for
        // `@oneOf`); every other nullable input field is tri-state so callers can
        // express OMIT vs explicit-null.
        let tristate = !t.is_one_of;

        s.push_str(&format!("public struct {}: Sendable {{\n", t.name));
        for f in &t.fields {
            s.push_str(&format!(
                "    public var {}: {}\n",
                swift_identifier(&f.name),
                crate::plan::swift_input_type(&f.shape, tristate)
            ));
        }
        // init
        s.push_str("    public init(");
        let args: Vec<String> = t
            .fields
            .iter()
            .map(|f| {
                let ty = crate::plan::swift_input_type(&f.shape, tristate);
                // `= nil` resolves to OMIT for both the tri-state wrapper
                // (`ExpressibleByNilLiteral` → `.none`) and `@oneOf` `Optional`.
                let dflt = if f.shape.nullable { " = nil" } else { "" };
                format!("{}: {}{}", swift_identifier(&f.name), ty, dflt)
            })
            .collect();
        s.push_str(&args.join(", "));
        s.push_str(") {\n");
        for f in &t.fields {
            let ident = swift_identifier(&f.name);
            s.push_str(&format!("        self.{ident} = {ident}\n"));
        }
        s.push_str("    }\n");

        // __cachebay bridge
        s.push_str("    public var __cachebay: Cachebay.JSONValue {\n");
        s.push_str("        var out: [String: Cachebay.JSONValue] = [:]\n");
        for f in &t.fields {
            let ident = swift_identifier(&f.name);
            s.push_str(&emit_input_field("        ", "out", &f.name, &ident, &f.shape, tristate));
        }
        s.push_str("        return .object(out)\n");
        s.push_str("    }\n");
        s.push_str("}\n\n");
    }
    s
}

/// Encode a single leaf binding (`inner`) of `shape`'s kind into a
/// `Cachebay.JSONValue` expression. Ignores nullability/list — the caller
/// handles those.
fn encode_leaf(inner: &str, shape: &TypeShape) -> String {
    match shape.kind {
        TypeKind::Scalar => match shape.named.as_str() {
            "String" | "ID" => format!(".string({inner})"),
            "Int" => format!(".int(Int64({inner}))"),
            "Float" => format!(".double({inner})"),
            "Boolean" => format!(".bool({inner})"),
            _ => "Cachebay.JSONValue.null".into(),
        },
        TypeKind::CustomScalar => inner.to_string(),
        // Typed enum — bridge via rawValue; cachebay stores the server-side string.
        TypeKind::Enum => format!(".string({inner}.rawValue)"),
        TypeKind::InputObject => format!("({inner}).__cachebay"),
    }
}

/// Encode a **present** (non-null) value of `shape` — list wrapping + element
/// nullability + leaf. Field-level optionality (omit / explicit null) is the
/// caller's concern, not this function's.
fn encode_present(ident: &str, shape: &TypeShape) -> String {
    if shape.list {
        let elem = TypeShape { nullable: shape.inner_nullable, list: false, ..shape.clone() };
        let item_expr = if elem.nullable {
            format!("{{ $0.map {{ {} }} ?? .null }}", encode_leaf("$0", &elem))
        } else {
            format!("{{ {} }}", encode_leaf("$0", &elem))
        };
        format!("Cachebay.JSONValue.array({ident}.map {item_expr})")
    } else {
        encode_leaf(ident, shape)
    }
}

/// Emit the `out["key"] = …` assignment for one input/variable field, honouring
/// the three GraphQL input states:
///   • non-null                         → always assign the encoded value;
///   • tri-state (nullable, non-`@oneOf`) → `__cachebayEncode`: `.none` OMITS the
///     key entirely, `.null` writes explicit null, `.some` writes the value —
///     this is what restores omit-vs-null on the wire;
///   • `@oneOf` member (nullable)        → plain `Optional`: `nil` omits, a value
///     forwards unmodified. Explicit null is invalid for `@oneOf` and is
///     unrepresentable (the field is `T?`, not the tri-state wrapper), so the
///     other members stay absent as the spec requires.
fn emit_input_field(indent: &str, out: &str, key: &str, ident: &str, shape: &TypeShape, tristate: bool) -> String {
    if !shape.nullable {
        format!("{indent}{out}[\"{key}\"] = {}\n", encode_present(ident, shape))
    } else if tristate {
        format!(
            "{indent}if let __v = {ident}.__cachebayEncode({{ v in {} }}) {{ {out}[\"{key}\"] = __v }}\n",
            encode_present("v", shape)
        )
    } else {
        format!(
            "{indent}if let {ident} = {ident} {{ {out}[\"{key}\"] = {} }}\n",
            encode_present(ident, shape)
        )
    }
}

fn operation_kind_literal(kind: OpKind) -> &'static str {
    match kind {
        OpKind::Query => ".query",
        OpKind::Mutation => ".mutation",
        OpKind::Subscription => ".subscription",
        OpKind::Fragment => ".fragment",
    }
}

fn render_string_list(xs: &[String]) -> String {
    if xs.is_empty() { return "[]".into(); }
    let inner: Vec<String> = xs.iter().map(|s| format!("\"{}\"", s.replace('"', "\\\""))).collect();
    format!("[{}]", inner.join(", "))
}

fn plan_strict_vars(plan: &Plan) -> Vec<String> {
    let mut out = std::collections::BTreeSet::<String>::new();
    collect_strict_vars_from_fields(&plan.root, &mut out);
    out.into_iter().collect()
}

fn plan_canonical_vars(plan: &Plan) -> Vec<String> {
    let win: std::collections::BTreeSet<String> = collect_window_args(&plan.root).into_iter().collect();
    plan_strict_vars(plan).into_iter().filter(|v| !win.contains(v)).collect()
}

fn collect_strict_vars_from_fields(fields: &[PlanField], out: &mut std::collections::BTreeSet<String>) {
    for f in fields {
        for piece in &f.arg_template {
            if let crate::plan::ArgPiece::Variable(name) = piece { out.insert(name.clone()); }
        }
        collect_strict_vars_from_fields(&f.children, out);
    }
}

fn collect_window_args(fields: &[PlanField]) -> Vec<String> {
    let mut set = std::collections::BTreeSet::<String>::new();
    fn walk(fields: &[PlanField], set: &mut std::collections::BTreeSet<String>) {
        for f in fields {
            if f.is_connection {
                for a in &f.page_args { set.insert(a.clone()); }
            }
            walk(&f.children, set);
        }
    }
    walk(fields, &mut set);
    set.into_iter().collect()
}

fn render_plan_field_literal(f: &PlanField, indent: &str) -> String {
    let mut s = String::new();
    s.push_str(indent);
    s.push_str("PlanField.make(\n");
    s.push_str(&format!("{indent}    responseKey: \"{}\",\n", f.response_key));
    s.push_str(&format!("{indent}    fieldName: \"{}\",\n", f.field_name));
    if let Some(tc) = &f.type_condition {
        s.push_str(&format!("{indent}    typeCondition: \"{}\",\n", tc));
    }
    let args = split_arg_template(&f.arg_template);
    if !args.is_empty() {
        s.push_str(&format!("{indent}    args: [\n"));
        for arg in &args {
            s.push_str(&format!("{indent}        (name: \"{}\", value: {}),\n", arg.name, arg.swift_value));
        }
        s.push_str(&format!("{indent}    ],\n"));
    }
    if f.is_connection {
        s.push_str(&format!("{indent}    isConnection: true,\n"));
        if let Some(k) = &f.connection_key {
            s.push_str(&format!("{indent}    connectionKey: \"{}\",\n", k));
        }
        if !f.connection_filters.is_empty() {
            s.push_str(&format!("{indent}    connectionFilters: {},\n", render_string_list(&f.connection_filters)));
        }
        if let Some(mode) = f.connection_mode {
            let m = match mode {
                crate::plan::ConnectionMode::Infinite => ".infinite",
                crate::plan::ConnectionMode::Page => ".page",
            };
            s.push_str(&format!("{indent}    connectionMode: {},\n", m));
        }
        if !f.page_args.is_empty() {
            s.push_str(&format!("{indent}    pageArgs: {},\n", render_string_list(&f.page_args)));
        }
        // Schema edge type (the `edges` child's named type, e.g.
        // "QueryProjectsConnectionEdge"). The runtime stamps it on the canonical so
        // an optimistic `insertEdge` can give a synthetic edge the authoritative
        // `__typename` — even for an empty connection with no sibling to copy from.
        if let Some(edge_type) = f
            .children
            .iter()
            .find(|c| c.response_key == CONNECTION_EDGES_KEY)
            .map(|e| e.named_type.as_str())
            .filter(|t| !t.is_empty())
        {
            s.push_str(&format!("{indent}    connectionEdgeTypename: \"{}\",\n", edge_type));
        }
    }
    // @skip / @include — emitted as `skipIf: .variable("foo")` /
    // `skipIf: .constant(true)` etc. The runtime evaluates these in
    // `PlanField.shouldInclude(variables:)` to honour spec §3.13.
    if let Some(cond) = &f.skip_if {
        s.push_str(&format!("{indent}    skipIf: {},\n", render_directive_condition(cond)));
    }
    if let Some(cond) = &f.include_if {
        s.push_str(&format!("{indent}    includeIf: {},\n", render_directive_condition(cond)));
    }
    if !f.children.is_empty() {
        s.push_str(&format!("{indent}    children: [\n"));
        for child in &f.children {
            s.push_str(&render_plan_field_literal(child, &format!("{indent}        ")));
        }
        s.push_str(&format!("{indent}    ]\n"));
    }
    s.push_str(indent);
    s.push_str("),\n");
    s
}

fn render_directive_condition(cond: &crate::plan::DirectiveCondition) -> String {
    match cond {
        crate::plan::DirectiveCondition::Variable(name) => format!(".variable(\"{name}\")"),
        crate::plan::DirectiveCondition::Constant(b) => format!(".constant({b})"),
    }
}

struct SplitArg { name: String, swift_value: String }

/// Re-partition `arg_template` (which is already a flat stream of pieces used
/// to stringify args) back into individual `(name, value)` pairs so the
/// emitter can write one `.variable(...)` or `.literal(...)` entry each.
fn split_arg_template(template: &[ArgPiece]) -> Vec<SplitArg> {
    let mut out: Vec<SplitArg> = Vec::new();
    let mut i = 0;
    while i < template.len() {
        // Expect a Raw("\"name\":") marker to introduce each arg.
        let Some(ArgPiece::Raw(name_raw)) = template.get(i) else { i += 1; continue; };
        if !(name_raw.starts_with('"') && name_raw.ends_with(':')) { i += 1; continue; }
        let name = name_raw.trim_start_matches('"').trim_end_matches(":").trim_end_matches('"').to_string();
        i += 1;
        // Collect tokens up to the next Raw(",") or Raw("\"name\":") or end.
        let mut tokens: Vec<&ArgPiece> = Vec::new();
        while i < template.len() {
            match &template[i] {
                ArgPiece::Raw(s) if s == "," => { i += 1; break; }
                ArgPiece::Raw(s) if s.starts_with('"') && s.ends_with(':') => break,
                piece => { tokens.push(piece); i += 1; }
            }
        }
        out.push(SplitArg { name, swift_value: render_arg_value(&tokens) });
    }
    out
}

fn render_arg_value(tokens: &[&ArgPiece]) -> String {
    if tokens.len() == 1 {
        match tokens[0] {
            ArgPiece::Variable(name) => return format!(".variable(\"{name}\")"),
            ArgPiece::Literal(json) => return format!(".literal({})", json_literal_to_swift(json)),
            ArgPiece::Raw(_) => return ".literal(.null)".into(),
        }
    }
    // Composite literal (list or object) — reconstruct the raw JSON fragment
    // and fall back to runtime-parse via a helper on `Cachebay.JSONValue`.
    let mut frag = String::new();
    for t in tokens {
        match t {
            ArgPiece::Literal(s) => frag.push_str(s),
            ArgPiece::Variable(name) => frag.push_str(&format!("\"${}\"", name)),
            ArgPiece::Raw(s) => frag.push_str(s),
        }
    }
    format!(".literal(Cachebay.JSONValue.parseLiteral({:?}))", frag)
}

fn json_literal_to_swift(json: &str) -> String {
    if json == "null" { return ".null".into(); }
    if json == "true" { return ".bool(true)".into(); }
    if json == "false" { return ".bool(false)".into(); }
    if let Some(stripped) = json.strip_prefix('"').and_then(|s| s.strip_suffix('"')) {
        return format!(".string({:?})", stripped);
    }
    if let Ok(i) = json.parse::<i64>() { return format!(".int({})", i); }
    if let Ok(d) = json.parse::<f64>() { return format!(".double({})", d); }
    format!("Cachebay.JSONValue.parseLiteral({:?})", json)
}

fn render_string_literal(s: &str) -> String {
    // Swift """ multi-line literal.
    format!("\"\"\"\n{}\n\"\"\"", s)
}

fn leaf_primitive_swift(named: &str) -> &'static str {
    match named {
        "String" | "ID" => "String",
        "Int" => "Int",
        "Float" => "Double",
        "Boolean" => "Bool",
        _ => "Cachebay.JSONValue",
    }
}

/// Compute the nested Swift type name for an object field. When the
/// field's selection set is a pure fragment spread (`reuse_fragment`
/// set), we reference the fragment's already-emitted `Data` type
/// directly — collapsing per-position duplicate structs across queries
/// that spread the same fragment.
fn nested_type_name(f: &PlanField) -> String {
    match &f.reuse_fragment {
        Some(frag) => format!("{frag}.Data"),
        None => title_case(&f.response_key),
    }
}

fn swift_type_for_field(f: &PlanField) -> String {
    match &f.output_shape {
        OutputShape::Leaf { nullable, list } => {
            let leaf = leaf_primitive_swift(&f.named_type);
            let list_ty = if *list { format!("[{leaf}]") } else { leaf.to_string() };
            if *nullable { format!("{list_ty}?") } else { list_ty }
        }
        OutputShape::Object { nullable, list } => {
            let nested = nested_type_name(f);
            let list_ty = if *list { format!("[{nested}]") } else { nested };
            if *nullable { format!("{list_ty}?") } else { list_ty }
        }
    }
}

// =====================================================================
// v1.0 typed-struct emission (WS6). Emits real `@CachebayData` struct
// shells + `@CachebayInterface` enums; the macros generate the memberwise
// init, eager `init?(_dataDict:)`, `__dataDict()`, `CachebayValue`, and the
// KeyPath field-name table. The CLI only emits the shell + field `let`s +
// conformances + the typename, so this is far smaller than the dict-wrapper
// emitter above.
// =====================================================================

/// True when a concrete struct's whole subtree can be `Codable`: it contains no
/// polymorphic (`@CachebayInterface`) selection, and every fragment-spread field
/// references a fragment whose `Data` is itself Codable. Interface enums aren't
/// `Codable` (deferred), so a struct holding one — directly or transitively —
/// can't be either.
fn is_codable_safe(parent_named_type: &str, children: &[PlanField], safe_fragments: &BTreeSet<String>) -> bool {
    let (shared, _by) = partition_children(parent_named_type, children);
    for child in &shared {
        if let Some(frag) = &child.reuse_fragment {
            if !safe_fragments.contains(frag) {
                return false;
            }
        } else if !child.children.is_empty() {
            let (_cs, cby) = partition_children(&child.named_type, &child.children);
            if !cby.is_empty() {
                return false; // a polymorphic (interface) field → not Codable
            }
            if !is_codable_safe(&child.named_type, &child.children, safe_fragments) {
                return false;
            }
        }
        // A leaf (scalar / GraphQLEnum / JSONValue) is Codable.
    }
    true
}

/// Fixpoint over fragment plans: the set of fragment names whose generated `Data`
/// is `Codable`. A fragment is unsafe if its root is polymorphic (an interface
/// enum) or its subtree references an unsafe fragment — and removing one can make
/// another unsafe, so iterate until stable.
fn compute_safe_fragments(plans: &[Plan]) -> BTreeSet<String> {
    let frags: Vec<&Plan> = plans.iter().filter(|p| matches!(p.operation_kind, OpKind::Fragment)).collect();
    let mut safe: BTreeSet<String> = frags.iter().map(|p| p.name.clone()).collect();
    loop {
        let mut remove: Vec<String> = Vec::new();
        for f in &frags {
            if !safe.contains(&f.name) {
                continue;
            }
            let (_s, by) = partition_children(&f.root_typename, &f.root);
            if !by.is_empty() || !is_codable_safe(&f.root_typename, &f.root, &safe) {
                remove.push(f.name.clone());
            }
        }
        if remove.is_empty() {
            break;
        }
        for n in remove {
            safe.remove(&n);
        }
    }
    safe
}

/// Emit a typed selection type. A polymorphic selection (inline fragments that
/// narrow the parent) becomes a `@CachebayInterface` enum; everything else is a
/// `@CachebayData` struct.
fn render_typed_selection(
    swift_name: &str,
    parent_named_type: &str,
    children: &[PlanField],
    indent: &str,
) -> String {
    render_typed_selection_impl(swift_name, parent_named_type, children, &EmitCtx::bare(), indent)
}

fn render_typed_selection_impl(
    swift_name: &str,
    parent_named_type: &str,
    children: &[PlanField],
    ctx: &EmitCtx,
    indent: &str,
) -> String {
    let (_shared, by_condition) = partition_children(parent_named_type, children);
    if by_condition.is_empty() {
        render_typed_struct_skipping(swift_name, parent_named_type, children, &BTreeSet::new(), ctx, indent)
    } else {
        render_typed_enum_impl(swift_name, parent_named_type, children, ctx, indent)
    }
}

/// Like `swift_type_for_field` but honours a custom scalar's configured Swift
/// type (`@cachebay(swiftType:)`). Used only by the typed emitter — the legacy
/// dict-wrapper accessors still read custom scalars as `JSONValue`.
fn typed_swift_type_for_field(f: &PlanField) -> String {
    // Output enum leaf -> `Cachebay.GraphQLEnum<Enum>` wrapper. Keeps the
    // generated enum closed (`String, CaseIterable`, used verbatim by inputs)
    // while making output decode total: an unknown server value lands in
    // `.unknown(raw)` instead of failing the whole record.
    if let (Some(enum_name), OutputShape::Leaf { nullable, list }) =
        (&f.swift_enum_type, &f.output_shape)
    {
        let base = format!("Cachebay.GraphQLEnum<{enum_name}>");
        let list_ty = if *list { format!("[{base}]") } else { base };
        return if *nullable { format!("{list_ty}?") } else { list_ty };
    }
    if let (Some(ty), OutputShape::Leaf { nullable, list }) = (&f.swift_scalar_type, &f.output_shape) {
        let list_ty = if *list { format!("[{ty}]") } else { ty.clone() };
        return if *nullable { format!("{list_ty}?") } else { list_ty };
    }
    swift_type_for_field(f)
}

/// `@CachebayData` struct shell for a concrete selection.
fn render_typed_struct(
    swift_name: &str,
    parent_named_type: &str,
    children: &[PlanField],
    indent: &str,
) -> String {
    render_typed_struct_skipping(swift_name, parent_named_type, children, &BTreeSet::new(), &EmitCtx::bare(), indent)
}

/// Like `render_typed_struct`, but (1) skips emitting the nested type for any
/// child whose `response_key` is in `skip_nested` (hoisting — see
/// `render_typed_enum`), and (2) adds `Codable` when the struct's subtree is
/// Codable-safe (`safe_fragments` = fragments whose `Data` is Codable). The
/// field's `let` is still emitted — only its nested type definition is omitted.
fn render_typed_struct_skipping(
    swift_name: &str,
    parent_named_type: &str,
    children: &[PlanField],
    skip_nested: &BTreeSet<String>,
    ctx: &EmitCtx,
    indent: &str,
) -> String {
    let (shared, _by_condition) = partition_children(parent_named_type, children);
    let has_typename = shared.iter().any(|c| c.response_key == "__typename");
    let has_id = shared.iter().any(|c| c.response_key == "id");
    // Guard on `__typename` only when it is selected (so a concrete record is
    // validated). Root/inline selections without `__typename` use "" (no guard).
    let typename = if has_typename { parent_named_type } else { "" };

    let mut conformances: Vec<&str> = Vec::new();
    if has_id {
        conformances.push("Identifiable");
    }
    conformances.push("Sendable");
    conformances.push("Hashable");
    if is_codable_safe(parent_named_type, children, ctx.safe_fragments) {
        conformances.push("Codable");
    }
    conformances.push("Cachebay.CachebayValue");
    let conf = conformances.join(", ");

    let mut s = String::new();
    s.push_str(&format!("{indent}@CachebayData(typename: \"{typename}\")\n"));
    s.push_str(&format!("{indent}public struct {swift_name}: {conf} {{\n"));
    for child in &shared {
        let ty = typed_swift_type_for_field(child);
        let default_attr = match &child.default_value {
            Some(lit) => format!("@CachebayDefault({lit}) "),
            None => String::new(),
        };
        s.push_str(&format!("{indent}    {default_attr}public let {}: {ty}\n", child.response_key));
    }
    // Nested object types become nested `@CachebayData`/`@CachebayInterface`,
    // except those hoisted to an enclosing scope (see `skip_nested`).
    for child in &shared {
        if !child.children.is_empty()
            && child.reuse_fragment.is_none()
            && !skip_nested.contains(&child.response_key)
        {
            let name = title_case(&child.response_key);
            s.push('\n');
            s.push_str(&render_typed_selection_impl(
                &name,
                &child.named_type,
                &child.children,
                ctx,
                &format!("{indent}    "),
            ));
        }
    }
    s.push_str(&format!("{indent}}}\n"));
    s
}

/// `@CachebayInterface` enum shell for a polymorphic selection: one case per
/// narrowed variant + `.unknown(Shared)`, plus the nested variant/Shared structs.
fn render_typed_enum(
    swift_name: &str,
    parent_named_type: &str,
    children: &[PlanField],
    indent: &str,
) -> String {
    render_typed_enum_impl(swift_name, parent_named_type, children, &EmitCtx::bare(), indent)
}

/// The interface enum itself is intentionally **not** `Codable` (typename-tagged
/// Codable is deferred); its concrete variant/`Shared`/hoisted structs each get
/// `Codable` when their own subtree is safe.
fn render_typed_enum_impl(
    swift_name: &str,
    parent_named_type: &str,
    children: &[PlanField],
    ctx: &EmitCtx,
    indent: &str,
) -> String {
    let (shared, by_condition) = partition_children(parent_named_type, children);

    // The case set. Default: one per selected inline fragment. Exhaustive: one
    // per SCHEMA implementor (variant fields if the selection inline-fragmented
    // it, else just the interface fields) — so a record/draft typed as a
    // non-selected implementor lands in its own typed case, not `.unknown`.
    // `.unknown(Shared)` always stays, strictly for typenames not in the schema
    // snapshot (true forward-compat: newer server vs older app).
    let variants: Vec<(String, Vec<&PlanField>)> = if ctx.exhaustive {
        if let Some(implementors) = ctx.interfaces.get(parent_named_type) {
            implementors
                .iter()
                .map(|tc| (tc.clone(), by_condition.get(tc.as_str()).cloned().unwrap_or_default()))
                .collect()
        } else {
            // No implementor list (unions: `collect_interface_implementations`
            // excludes them by design) → intentionally keep the non-exhaustive
            // shape. Exhaustive unions are a future extension of the config key.
            by_condition.iter().map(|(tc, f)| (tc.clone(), f.clone())).collect()
        }
    } else {
        by_condition.iter().map(|(tc, f)| (tc.clone(), f.clone())).collect()
    };

    // `Identifiable` requires an `id` member. The macro only lifts an `id`
    // accessor when the interface's shared fields include `id`, so gate the
    // conformance on that — mirroring `render_typed_struct_skipping`. An
    // id-less interface (e.g. the `CookData` union) would otherwise declare
    // `Identifiable` with no `id`, failing to conform.
    let has_id = shared.iter().any(|c| c.response_key == "id");
    let mut conformances: Vec<&str> = Vec::new();
    if has_id {
        conformances.push("Identifiable");
    }
    conformances.push("Sendable");
    conformances.push("Hashable");
    conformances.push("Cachebay.CachebayValue");
    let conf = conformances.join(", ");

    let mut s = String::new();
    s.push_str(&format!("{indent}@CachebayInterface\n"));
    s.push_str(&format!(
        "{indent}public enum {swift_name}: {conf} {{\n"
    ));
    // One case per variant, payload = the variant struct.
    for (tc, _) in &variants {
        s.push_str(&format!("{indent}    case {}({tc})\n", lower_first(tc)));
    }
    s.push_str(&format!("{indent}    case unknown(Shared)\n"));

    // A shared interface field with an inline sub-selection generates one nested
    // type *per variant* if left to `render_typed_struct` (Shared.Derivatives,
    // VideoElement.Derivatives, …) — distinct types the macro's lifted accessor
    // can neither resolve at enum scope nor unify. Hoist each such sub-selection
    // to a single enum-scope nested struct; the per-struct copies are suppressed
    // via `skip_nested`, and bare references resolve outward to the hoisted type.
    let hoist_keys: BTreeSet<String> = shared
        .iter()
        .filter(|c| !c.children.is_empty() && c.reuse_fragment.is_none())
        .map(|c| c.response_key.clone())
        .collect();

    // Shared struct carries the interface-level fields (§3.1).
    let shared_owned: Vec<PlanField> = shared.iter().map(|f| (*f).clone()).collect();
    s.push('\n');
    s.push_str(&render_typed_struct_skipping("Shared", "", &shared_owned, &hoist_keys, ctx, &format!("{indent}    ")));

    // Hoisted shared sub-selections — emitted once at enum scope.
    for child in shared.iter().filter(|c| hoist_keys.contains(&c.response_key)) {
        s.push('\n');
        s.push_str(&render_typed_selection_impl(
            &title_case(&child.response_key),
            &child.named_type,
            &child.children,
            ctx,
            &format!("{indent}    "),
        ));
    }

    // One @CachebayData struct per variant = shared fields + the variant's own
    // fields. A non-selected implementor (exhaustive mode) has no own fields, so
    // its struct carries just the interface fields — typename pinned by the macro.
    for (tc, fields) in &variants {
        let mut variant_children: Vec<PlanField> = shared.iter().map(|f| (*f).clone()).collect();
        variant_children.extend(fields.iter().map(|f| (*f).clone()));
        s.push('\n');
        s.push_str(&render_typed_struct_skipping(tc, tc, &variant_children, &hoist_keys, ctx, &format!("{indent}    ")));
    }

    s.push_str(&format!("{indent}}}\n"));
    s
}

/// Lowercase the first character (e.g. `VideoElement` -> `videoElement`) for case names.
fn lower_first(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => c.to_lowercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

/// Emit a complete typed operation/fragment file. Mirrors `render_plan` but the
/// `Data` is a real `@CachebayData`/`@CachebayInterface` type and the envelope
/// conforms to `CachebayOperation`/`CachebayFragment`. The CachePlan literal,
/// Variables bridge, and network query are unchanged (they're data).
fn render_typed_plan(plan: &Plan) -> String {
    render_typed_plan_impl(plan, &EmitCtx::bare())
}

fn render_typed_plan_impl(plan: &Plan, ctx: &EmitCtx) -> String {
    let mut s = String::new();
    s.push_str("// Generated by cachebay-cli. DO NOT EDIT.\n");
    s.push_str(&format!("// Source: {}\n\n", plan.source_path));
    s.push_str("import Foundation\n");
    s.push_str("import Cachebay\n\n");

    let is_fragment = matches!(plan.operation_kind, OpKind::Fragment);
    let conforms = if is_fragment {
        ": Cachebay.CachebayFragment"
    } else {
        ": Cachebay.CachebayOperation"
    };
    let struct_kind = match plan.operation_kind {
        OpKind::Query => "Query",
        OpKind::Mutation => "Mutation",
        OpKind::Subscription => "Subscription",
        OpKind::Fragment => "Fragment",
    };
    s.push_str(&format!("/// {} {}: {}\n", struct_kind, plan.name, plan.source_path));
    s.push_str(&format!("public struct {}{} {{\n", plan.name, conforms));

    // Variables — same shape/bridge as the dict emitter.
    if !plan.variables.is_empty() {
        s.push_str("    public struct Variables: Cachebay.OperationVariables {\n");
        for v in &plan.variables {
            s.push_str(&format!("        public var {}: {}\n", swift_identifier(&v.name), v.swift_type));
        }
        s.push_str("        public init(");
        let args: Vec<String> = plan
            .variables
            .iter()
            .map(|v| {
                let ident = swift_identifier(&v.name);
                let dflt = if v.nullable { " = nil" } else { "" };
                format!("{}: {}{}", ident, v.swift_type, dflt)
            })
            .collect();
        s.push_str(&args.join(", "));
        s.push_str(") {\n");
        for v in &plan.variables {
            let ident = swift_identifier(&v.name);
            s.push_str(&format!("            self.{ident} = {ident}\n"));
        }
        s.push_str("        }\n");
        s.push_str("        public var __cachebay: [String: Cachebay.JSONValue] {\n");
        s.push_str("            var out: [String: Cachebay.JSONValue] = [:]\n");
        for v in &plan.variables {
            let ident = swift_identifier(&v.name);
            s.push_str(&emit_input_field("            ", "out", &v.name, &ident, &v.shape, true));
        }
        s.push_str("            return out\n        }\n    }\n\n");
    } else {
        s.push_str("    public typealias Variables = Cachebay.EmptyVariables\n\n");
    }

    // Typed Data — a @CachebayData struct or @CachebayInterface enum.
    //
    // Strip the operation root's auto-injected `__typename`: the root (`Query`/
    // `Mutation`/`Subscription`) is not a cacheable entity, so the `@` record has no
    // `__typename`. Keeping it would make the root struct require a field the record
    // never has (eager-decode miss) and add a bogus typename guard. Nested entity
    // structs keep their `__typename` (records have it).
    if !plan.root.is_empty() {
        // Only the operation root (Query/Mutation/Subscription) is a non-entity;
        // a fragment's root IS an entity (`on Spell`) and keeps `__typename`.
        let root_fields: Vec<PlanField> = if is_fragment {
            plan.root.clone()
        } else {
            plan.root
                .iter()
                .filter(|f| f.response_key != "__typename")
                .cloned()
                .collect()
        };
        s.push_str(&render_typed_selection_impl("Data", &plan.root_typename, &root_fields, ctx, "    "));
        s.push('\n');
    }

    s.push_str(&format!("    public static let operationName: String = \"{}\"\n", plan.name));
    s.push_str("    public static let networkQuery: String = ");
    s.push_str(&render_string_literal(&plan.network_query));
    s.push_str("\n\n");
    s.push_str("    public static let cachePlan: CachePlan = CachePlan.make(\n");
    s.push_str(&format!("        operation: {},\n", operation_kind_literal(plan.operation_kind)));
    s.push_str(&format!("        rootTypename: \"{}\",\n", plan.root_typename));
    s.push_str("        root: [\n");
    for f in &plan.root {
        s.push_str(&render_plan_field_literal(f, "            "));
    }
    s.push_str("        ],\n");
    s.push_str("        networkQuery: networkQuery,\n");
    s.push_str(&format!("        strictVars: {},\n", render_string_list(&plan_strict_vars(plan))));
    s.push_str(&format!("        canonicalVars: {},\n", render_string_list(&plan_canonical_vars(plan))));
    s.push_str(&format!("        windowArgs: Set({})\n", render_string_list(&collect_window_args(&plan.root))));
    s.push_str("    )\n\n");
    s.push_str("    public static let document: QueryDocument = .plan(cachePlan)\n");

    if is_fragment {
        s.push_str(&format!("    public static let fragmentName: String = \"{}\"\n", plan.name));
        s.push_str(&format!("    public static let onTypename: String = \"{}\"\n", plan.root_typename));
        s.push_str("    public static var __cachebayFieldNames: [AnyKeyPath: String] { Data.__cachebayFieldNames }\n");
    }

    s.push_str("}\n");
    s
}

/// Partition children into "shared" (no type condition, or condition equal to
/// the parent selection type) and "per-type-case" groups (each condition that
/// narrows the parent). Used for both interface/union polymorphism and for
/// fragment spreads on the same type (which degenerate to shared).
fn partition_children<'a>(parent_named_type: &str, children: &'a [PlanField]) -> (Vec<&'a PlanField>, BTreeMap<String, Vec<&'a PlanField>>) {
    let mut shared: Vec<&PlanField> = Vec::new();
    let mut by_condition: BTreeMap<String, Vec<&PlanField>> = BTreeMap::new();
    for child in children {
        match &child.type_condition {
            None => shared.push(child),
            Some(tc) if tc == parent_named_type || parent_named_type.is_empty() => shared.push(child),
            Some(tc) => by_condition.entry(tc.clone()).or_default().push(child),
        }
    }
    (shared, by_condition)
}

fn title_case(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => c.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

fn swift_identifier(s: &str) -> String {
    // Strip/replace anything Swift won't accept. GraphQL field names are already
    // `[_A-Za-z][_0-9A-Za-z]*`, so leading-digit is the only real concern, and
    // responseKey = alias ?? name means the emitter output tracks the source.
    match s {
        "class" | "struct" | "enum" | "protocol" | "extension" | "func" | "var" | "let"
        | "if" | "else" | "return" | "for" | "while" | "do" | "try" | "catch" | "throw"
        | "switch" | "case" | "default" | "self" | "init" | "deinit" => format!("`{s}`"),
        _ => s.to_string(),
    }
}

// Keep the public symbols used by main.rs reachable.
#[allow(dead_code)]
pub(crate) fn _suppress_unused_warnings(
    _c: ConnectionMode,
    _a: ArgPiece,
) {}

#[cfg(test)]
mod codegen_tests {
    //! Unit coverage for the two ergonomic codegen helpers consumed by
    //! optimistic-patch flows:
    //!
    //!   1. `partial()` — static factory that returns a `Data` populated
    //!      with only `__typename`. Replaces the awkward
    //!      `Data(__data: ["__typename": .string("...")])` idiom and the
    //!      "use `make(...)` with all-`auto` defaults" workaround that
    //!      stomped fields the caller didn't intend to touch.
    //!
    //!   2. `patch<Field>(_ build: (inout SubData) -> Void)` — mutating
    //!      method on a parent `Data` for **inline-container** sub-objects.
    //!      Reads any live draft state for the field, hands the closure an
    //!      `inout` sub-draft, and writes it back. Composes recursively
    //!      for nested inline containers.
    //!
    //! Detection rule for `patch<Field>` emission (the only subtle bit):
    //!
    //!   * Field's output_shape is Object, list: false
    //!   * Children are non-empty
    //!   * Children do **not** include `id` — i.e. this fragment's
    //!     selection on this field is an id-less inline container, not an
    //!     entity reference. The rule is **syntactic on this fragment's
    //!     selection**, not semantic on the schema type. The same schema
    //!     type can appear inline-container-shaped in one fragment and
    //!     entity-ref-shaped in another; the codegen tracks the selection.

    use super::*;
    use crate::plan::{OutputShape, PlanField};

    fn scalar(name: &str, named_type: &str) -> PlanField {
        PlanField {
            response_key: name.into(),
            field_name: name.into(),
            expected_arg_names: vec![],
            arg_template: vec![],
            type_condition: None,
            is_connection: false,
            connection_key: None,
            connection_filters: vec![],
            connection_mode: None,
            page_args: vec![],
            named_type: named_type.into(),
            output_shape: OutputShape::Leaf { nullable: false, list: false },
            sel_id: format!("leaf-{name}"),
            children: vec![],
            reuse_fragment: None,
            skip_if: None,
            include_if: None,
            default_value: None,
            swift_scalar_type: None,
            swift_enum_type: None,
        }
    }

    fn typename_field() -> PlanField { scalar("__typename", "String") }
    fn id_field() -> PlanField { scalar("id", "ID") }
    fn title_scalar() -> PlanField { scalar("title", "String") }

    fn object(name: &str, named_type: &str, children: Vec<PlanField>) -> PlanField {
        PlanField {
            response_key: name.into(),
            field_name: name.into(),
            expected_arg_names: vec![],
            arg_template: vec![],
            type_condition: None,
            is_connection: false,
            connection_key: None,
            connection_filters: vec![],
            connection_mode: None,
            page_args: vec![],
            named_type: named_type.into(),
            output_shape: OutputShape::Object { nullable: false, list: false },
            sel_id: format!("obj-{name}"),
            children,
            reuse_fragment: None,
            skip_if: None,
            include_if: None,
            default_value: None,
            swift_scalar_type: None,
            swift_enum_type: None,
        }
    }

    fn scalar_on(name: &str, named_type: &str, tc: &str) -> PlanField {
        let mut f = scalar(name, named_type);
        f.type_condition = Some(tc.into());
        f
    }

    // MARK: - v1.0 typed emission (WS6)

    #[test]
    fn typed_struct_emits_cachebay_data_shell() {
        let out = render_typed_struct(
            "Spell",
            "Spell",
            &[typename_field(), id_field(), scalar("name", "String")],
            "",
        );
        assert!(out.contains("@CachebayData(typename: \"Spell\")"), "{out}");
        assert!(
            out.contains("public struct Spell: Identifiable, Sendable, Hashable, Codable, Cachebay.CachebayValue {"),
            "{out}"
        );
        assert!(out.contains("public let __typename: String"), "{out}");
        assert!(out.contains("public let id: String"), "{out}");
        assert!(out.contains("public let name: String"), "{out}");
        // No dict wrapper in the typed shape.
        assert!(!out.contains("__data"), "should not emit dict wrapper; {out}");
    }

    #[test]
    fn typed_struct_no_id_no_typename_uses_empty_typename() {
        // An operation-root-like selection with neither id nor __typename.
        let out = render_typed_struct("Data", "Query", &[scalar("name", "String")], "");
        assert!(out.contains("@CachebayData(typename: \"\")"), "{out}");
        assert!(out.contains("public struct Data: Sendable, Hashable, Codable, Cachebay.CachebayValue {"), "{out}");
        assert!(!out.contains("Identifiable"), "{out}");
    }

    #[test]
    fn typed_struct_nested_object() {
        let project = object("project", "Project", vec![typename_field(), id_field(), scalar("name", "String")]);
        let out = render_typed_struct(
            "Cook",
            "Cook",
            &[typename_field(), id_field(), title_scalar(), project],
            "",
        );
        assert!(out.contains("public let project: Project"), "{out}");
        assert!(
            out.contains("public struct Project: Identifiable, Sendable, Hashable, Codable, Cachebay.CachebayValue {"),
            "nested struct emitted; {out}"
        );
    }

    #[test]
    fn typed_interface_emits_enum_with_unknown_and_variants() {
        let children = vec![
            typename_field(),
            id_field(),
            scalar_on("url", "String", "VideoElement"),
            scalar_on("waveformURL", "String", "AudioElement"),
        ];
        let out = render_typed_enum("Element", "Element", &children, "");
        assert!(out.contains("@CachebayInterface"), "{out}");
        assert!(
            out.contains("public enum Element: Identifiable, Sendable, Hashable, Cachebay.CachebayValue {"),
            "{out}"
        );
        assert!(out.contains("case videoElement(VideoElement)"), "{out}");
        assert!(out.contains("case audioElement(AudioElement)"), "{out}");
        assert!(out.contains("case unknown(Shared)"), "{out}");
        // Shared carries interface-level fields with empty typename.
        assert!(out.contains("@CachebayData(typename: \"\")"), "shared struct; {out}");
        // Each variant is a @CachebayData struct = shared + own fields.
        assert!(out.contains("@CachebayData(typename: \"VideoElement\")"), "{out}");
        assert!(out.contains("public let url: String"), "{out}");
    }

    #[test]
    fn typed_enum_hoists_shared_subselection_to_single_nested_struct() {
        // A shared interface field with an inline sub-selection (`derivatives { key }`)
        // must emit ONE nested struct at enum scope — not a duplicate per variant.
        // Per-variant duplicates (Shared.Derivatives, VideoElement.Derivatives, …) are
        // distinct types, so the macro's lifted accessor `[Derivatives]` can neither
        // resolve at enum scope nor unify the switch arms (BUG 2).
        let mut derivatives = object("derivatives", "Cook", vec![typename_field(), id_field(), scalar("key", "String")]);
        derivatives.output_shape = OutputShape::Object { nullable: false, list: true };
        let children = vec![
            typename_field(),
            id_field(),
            derivatives,                                      // shared (no type condition)
            scalar_on("url", "String", "VideoElement"),       // variant-specific
            scalar_on("waveformURL", "String", "AudioElement"),
        ];
        let out = render_typed_enum("Element", "Element", &children, "");

        // Hoisted exactly once (not once per Shared + variant).
        assert_eq!(
            out.matches("struct Derivatives").count(),
            1,
            "shared sub-selection must be hoisted to a single enum-scope nested struct; {out}"
        );
        // Shared + each variant reference the (bare) hoisted type.
        assert!(out.contains("public let derivatives: [Derivatives]"), "{out}");
        // The enum shell is otherwise intact.
        assert!(out.contains("case unknown(Shared)"), "{out}");
        assert!(out.contains("@CachebayData(typename: \"VideoElement\")"), "{out}");
    }

    #[test]
    fn typed_selection_dispatches_struct_vs_enum() {
        // No type conditions -> struct.
        let s = render_typed_selection("Spell", "Spell", &[typename_field(), id_field()], "");
        assert!(s.contains("public struct Spell"), "{s}");
        // Type conditions -> enum.
        let e = render_typed_selection(
            "Element",
            "Element",
            &[typename_field(), id_field(), scalar_on("url", "String", "VideoElement")],
            "",
        );
        assert!(e.contains("public enum Element"), "{e}");
    }

    fn plan_fixture(name: &str, kind: OpKind, root_typename: &str, root: Vec<PlanField>) -> Plan {
        Plan {
            name: name.into(),
            operation_kind: kind,
            root_typename: root_typename.into(),
            variables: vec![],
            root,
            network_query: format!("op {name}"),
            source_path: format!("{name}.graphql"),
        }
    }

    #[test]
    fn typed_plan_operation_envelope() {
        let cook = object("cook", "Cook", vec![typename_field(), id_field(), title_scalar()]);
        let out = render_typed_plan(&plan_fixture("GetCook", OpKind::Query, "Query", vec![cook]));
        assert!(out.contains("import Cachebay"), "{out}");
        assert!(out.contains("public struct GetCook: Cachebay.CachebayOperation {"), "{out}");
        assert!(out.contains("public typealias Variables = Cachebay.EmptyVariables"), "{out}");
        assert!(out.contains("@CachebayData(typename: \"\")"), "root Data empty typename; {out}");
        assert!(out.contains("public let cook: Cook"), "{out}");
        assert!(out.contains("public static let document: QueryDocument = .plan(cachePlan)"), "{out}");
        assert!(!out.contains("OperationData"), "no dict-wrapper conformance; {out}");
    }

    #[test]
    fn typed_plan_fragment_envelope() {
        let out = render_typed_plan(&plan_fixture(
            "CookFields",
            OpKind::Fragment,
            "Cook",
            vec![typename_field(), id_field(), title_scalar()],
        ));
        assert!(out.contains("public struct CookFields: Cachebay.CachebayFragment {"), "{out}");
        assert!(out.contains("public static let fragmentName: String = \"CookFields\""), "{out}");
        assert!(out.contains("public static let onTypename: String = \"Cook\""), "{out}");
        assert!(out.contains("Data.__cachebayFieldNames"), "{out}");
        assert!(out.contains("@CachebayData(typename: \"Cook\")"), "fragment Data guards Cook; {out}");
    }

    #[test]
    fn typed_struct_emits_cachebay_default() {
        let mut rank = scalar("rank", "String");
        rank.default_value = Some("\"a0\"".into());
        let mut speech = scalar("speech", "Float");
        speech.default_value = Some("0.0".into());
        let out = render_typed_struct(
            "Video",
            "VideoElement",
            &[typename_field(), id_field(), rank, speech],
            "",
        );
        assert!(out.contains("@CachebayDefault(\"a0\") public let rank: String"), "{out}");
        assert!(out.contains("@CachebayDefault(0.0) public let speech: Double"), "{out}");
        // Fields without a schema default get no annotation.
        assert!(out.contains("    public let id: String\n"), "{out}");
    }

    #[test]
    fn typed_struct_custom_scalar_uses_configured_type() {
        let mut created = scalar("createdAt", "Date");
        created.swift_scalar_type = Some("Foundation.Date".into());
        let mut deleted = scalar("deletedAt", "Date");
        deleted.swift_scalar_type = Some("Foundation.Date".into());
        deleted.output_shape = OutputShape::Leaf { nullable: true, list: false };
        let out = render_typed_struct("Doc", "Doc", &[typename_field(), id_field(), created, deleted], "");
        assert!(out.contains("public let createdAt: Foundation.Date"), "{out}");
        assert!(out.contains("public let deletedAt: Foundation.Date?"), "{out}");

        // An unconfigured custom scalar still falls back to JSONValue passthrough.
        let raw = scalar("blob", "JSON");
        let out2 = render_typed_struct("D2", "D2", &[typename_field(), id_field(), raw], "");
        assert!(out2.contains("public let blob: Cachebay.JSONValue"), "{out2}");
    }

    fn enum_leaf(name: &str, enum_name: &str, nullable: bool, list: bool) -> PlanField {
        let mut f = scalar(name, enum_name);
        f.swift_enum_type = Some(enum_name.into());
        f.output_shape = OutputShape::Leaf { nullable, list };
        f
    }

    #[test]
    fn typed_struct_output_enum_field_uses_graphql_enum_wrapper() {
        // Output enum leaves are wrapped in `Cachebay.GraphQLEnum<…>` so an
        // unknown server value decodes to `.unknown(raw)` instead of failing
        // the record. Closed enum stays the type *parameter*, not the field type.
        let out = render_typed_struct(
            "V",
            "VideoElement",
            &[
                typename_field(),
                id_field(),
                enum_leaf("intent", "VideoIntent", false, false), // VideoIntent!
                enum_leaf("mood", "VideoIntent", true, false),    // VideoIntent
                enum_leaf("intents", "VideoIntent", false, true), // [VideoIntent!]!
            ],
            "",
        );
        assert!(out.contains("public let intent: Cachebay.GraphQLEnum<VideoIntent>\n"), "non-null enum; {out}");
        assert!(out.contains("public let mood: Cachebay.GraphQLEnum<VideoIntent>?\n"), "nullable enum; {out}");
        assert!(out.contains("public let intents: [Cachebay.GraphQLEnum<VideoIntent>]\n"), "list enum; {out}");
        // The bug: enum leaves must NOT collapse to JSONValue.
        assert!(!out.contains("Cachebay.JSONValue"), "no enum should fall back to JSONValue; {out}");
    }

    #[test]
    fn typed_struct_codable_only_when_subtree_has_no_interface_field() {
        // Concrete subtree (scalars + nested concrete object) -> Codable.
        let project = object("project", "Project", vec![typename_field(), id_field(), scalar("name", "String")]);
        let leaf = render_typed_struct("Cook", "Cook", &[typename_field(), id_field(), scalar("title", "String"), project], "");
        assert!(leaf.contains("public struct Cook: Identifiable, Sendable, Hashable, Codable, Cachebay.CachebayValue {"), "concrete struct should be Codable; {leaf}");
        assert!(leaf.contains("public struct Project: Identifiable, Sendable, Hashable, Codable, Cachebay.CachebayValue {"), "nested concrete should be Codable; {leaf}");

        // A struct holding a polymorphic (interface) field is NOT Codable — the
        // nested @CachebayInterface enum isn't Codable, so the holder can't be.
        let element = object("element", "Element", vec![
            typename_field(), id_field(),
            scalar_on("url", "String", "VideoElement"),   // type condition -> interface enum
        ]);
        let holder = render_typed_struct("Holder", "Holder", &[typename_field(), id_field(), element], "");
        assert!(holder.contains("public struct Holder: Identifiable, Sendable, Hashable, Cachebay.CachebayValue {"), "interface-holding struct must NOT be Codable; {holder}");
        assert!(!holder.contains("public struct Holder: Identifiable, Sendable, Hashable, Codable"), "{holder}");
        assert!(holder.contains("public enum Element:"), "nested interface enum still emitted; {holder}");
        assert!(!holder.contains("public enum Element: Identifiable, Sendable, Hashable, Codable"), "interface enum itself must NOT be Codable; {holder}");
    }

    #[test]
    fn typed_struct_plain_string_field_stays_string() {
        // A schema `String!` field (no enum hint) must NOT be wrapped — these
        // are the `Element.kind/state`, `ChatMessage.status` etc. that the bug
        // report explicitly says to leave as `String`.
        let out = render_typed_struct(
            "E",
            "Element",
            &[typename_field(), id_field(), scalar("kind", "String")],
            "",
        );
        assert!(out.contains("public let kind: String\n"), "{out}");
        assert!(!out.contains("GraphQLEnum"), "non-enum String must not be wrapped; {out}");
    }

    #[test]
    fn namespace_wraps_typed_output() {
        let cook = object("cook", "Cook", vec![typename_field(), id_field()]);
        let plan = plan_fixture("GetCook", OpKind::Query, "Query", vec![cook]);

        let out = wrap_in_namespace(render_typed_plan(&plan), "API");
        assert!(out.contains("extension API {"), "{out}");
        assert!(out.contains("public struct GetCook: Cachebay.CachebayOperation {"), "{out}");
        // Imports stay at file scope (before the extension).
        assert!(
            out.find("import Cachebay").unwrap() < out.find("extension API {").unwrap(),
            "{out}"
        );

        // Empty namespace = top level, no wrapping.
        let bare = wrap_in_namespace(render_typed_plan(&plan), "");
        assert!(!bare.contains("extension API"), "{bare}");

        // The namespace enum is declared in the schema file.
        let schema = render_schema(&std::collections::BTreeMap::new(), "API");
        assert!(schema.contains("public enum API {}"), "{schema}");
    }

    // MARK: - @include / @skip on generated PlanField literal
    //
    // The runtime materializer already evaluates `PlanField.shouldInclude(vars:)`
    // before the per-field read (Documents.swift:811). For that to fire on
    // codegen-emitted plans, `render_plan_field_literal` must emit
    // `includeIf:` / `skipIf:` arguments on `PlanField.make(...)`. Without
    // these emissions, every generated field is unconditional and
    // @include(if:$x) in the source query silently degrades to a runtime
    // "field required" miss whenever $x = false.

    use crate::plan::DirectiveCondition;

    fn project_with_include_var() -> PlanField {
        let mut f = object(
            "project",
            "Project",
            vec![typename_field(), id_field(), scalar("name", "String")],
        );
        f.include_if = Some(DirectiveCondition::Variable("withProject".into()));
        f
    }

    fn project_with_skip_const() -> PlanField {
        let mut f = object(
            "project",
            "Project",
            vec![typename_field(), id_field()],
        );
        f.skip_if = Some(DirectiveCondition::Constant(true));
        f
    }

    #[test]
    fn plan_literal_emits_includeIf_variable() {
        let literal = render_plan_field_literal(&project_with_include_var(), "");
        assert!(
            literal.contains("includeIf: .variable(\"withProject\")"),
            "render_plan_field_literal must emit includeIf for fields with @include directive; output:\n{literal}"
        );
    }

    #[test]
    fn plan_literal_emits_skipIf_constant() {
        let literal = render_plan_field_literal(&project_with_skip_const(), "");
        assert!(
            literal.contains("skipIf: .constant(true)"),
            "render_plan_field_literal must emit skipIf for fields with @skip(if: true); output:\n{literal}"
        );
    }

    #[test]
    fn plan_literal_omits_directive_keys_when_absent() {
        // A field with no @include / @skip must NOT emit either key (so
        // existing generated files stay byte-identical for fields that
        // don't use the directives).
        let plain = object("project", "Project", vec![typename_field(), id_field()]);
        let literal = render_plan_field_literal(&plain, "");
        assert!(
            !literal.contains("includeIf"),
            "directiveless field must not emit includeIf:; output:\n{literal}"
        );
        assert!(
            !literal.contains("skipIf"),
            "directiveless field must not emit skipIf:; output:\n{literal}"
        );
    }

    #[test]
    fn plan_literal_emits_includeIf_constant_false() {
        let mut f = object("project", "Project", vec![typename_field(), id_field()]);
        f.include_if = Some(DirectiveCondition::Constant(false));
        let literal = render_plan_field_literal(&f, "");
        assert!(
            literal.contains("includeIf: .constant(false)"),
            "render_plan_field_literal must support literal Boolean args; output:\n{literal}"
        );
    }

    /// A connection field emits its schema edge type (the `edges` child's named
    /// type) so the runtime can stamp it on the canonical — letting an optimistic
    /// insert give a synthetic edge the authoritative `__typename` even when the
    /// connection is empty (the empty-list-after-create fix, schema as truth).
    #[test]
    fn plan_literal_connection_emits_edge_typename() {
        let edges = object(
            CONNECTION_EDGES_KEY,
            "QueryProjectsConnectionEdge",
            vec![typename_field(), scalar("cursor", "String")],
        );
        let mut conn = object("projects", "QueryProjectsConnection", vec![edges]);
        conn.is_connection = true;
        conn.connection_key = Some("projects".into());
        let literal = render_plan_field_literal(&conn, "");
        assert!(
            literal.contains("connectionEdgeTypename: \"QueryProjectsConnectionEdge\""),
            "connection field must emit its edge type name; output:\n{literal}"
        );
    }

    /// A non-connection field must NOT emit the key (keeps generated files lean).
    #[test]
    fn plan_literal_nonConnection_omits_edge_typename() {
        let plain = object("project", "Project", vec![typename_field(), id_field()]);
        let literal = render_plan_field_literal(&plain, "");
        assert!(!literal.contains("connectionEdgeTypename"), "output:\n{literal}");
    }

    // MARK: - Unmapped-scalar warning (decode-hardening)

    /// An unmapped custom scalar (emitted as `Cachebay.JSONValue`) produces ONE
    /// warning per scalar — not per field — carrying the blast-radius counts
    /// (total uses + non-null uses, the fake-optionality sites).
    #[test]
    fn unmapped_custom_scalar_warns_once_per_scalar_with_counts() {
        let created = scalar("createdAt", "ISO8601DateTime"); // unmapped, non-null
        let updated = scalar("updatedAt", "ISO8601DateTime"); // unmapped, non-null
        let mut deleted = scalar("deletedAt", "ISO8601DateTime");
        deleted.output_shape = OutputShape::Leaf { nullable: true, list: false }; // unmapped, nullable
        // Explicitly mapped to JSONValue — the "I mean it" silencer.
        let mut blob = scalar("metadata", "JSON");
        blob.swift_scalar_type = Some("Cachebay.JSONValue".into());

        let post = object(
            "post",
            "Post",
            vec![id_field(), title_scalar(), created, updated, deleted, blob],
        );
        let plan = plan_fixture("GetPost", OpKind::Query, "Query", vec![post]);

        let warnings = collect_unmapped_scalar_warnings(&[plan]);
        assert_eq!(warnings.len(), 1, "one warning per scalar, not per field: {warnings:?}");
        assert_eq!(warnings[0].scalar, "ISO8601DateTime");
        assert_eq!(warnings[0].uses, 3);
        assert_eq!(warnings[0].non_null, 2);
    }

    /// No warning for built-in scalars, scalars mapped to a real type, or the
    /// explicit `Cachebay.JSONValue` silencer.
    #[test]
    fn no_scalar_warning_for_builtins_mapped_or_jsonvalue_silencer() {
        let mut dt = scalar("at", "ISO8601DateTime");
        dt.swift_scalar_type = Some("Foundation.Date".into()); // mapped to a real type
        let mut blob = scalar("meta", "JSON");
        blob.swift_scalar_type = Some("Cachebay.JSONValue".into()); // explicit JSONValue silencer
        let post = object(
            "post",
            "Post",
            vec![
                id_field(),               // ID  (built-in)
                title_scalar(),           // String (built-in)
                scalar("count", "Int"),   // Int (built-in)
                scalar("score", "Float"), // Float (built-in)
                dt,
                blob,
            ],
        );
        let plan = plan_fixture("X", OpKind::Query, "Query", vec![post]);
        assert!(collect_unmapped_scalar_warnings(&[plan]).is_empty());
    }

    // MARK: - Atomic output reconcile (decode-hardening)

    fn fresh_test_dir(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("cachebay_reconcile_{name}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A no-op regen must not rewrite byte-identical files — stable mtimes keep
    /// the generated SwiftPM target out of the rebuild graph.
    #[test]
    fn reconcile_skips_unchanged_files() {
        let dir = fresh_test_dir("skip");
        std::fs::write(dir.join("A.graphql.swift"), "X").unwrap();
        let files = BTreeMap::from([("A.graphql.swift".to_string(), "X".to_string())]);
        let stats = reconcile_output_dir(&dir, &files).unwrap();
        assert_eq!(stats.written, 0, "identical content must not be rewritten");
        assert_eq!(stats.skipped, 1);
        assert_eq!(std::fs::read_to_string(dir.join("A.graphql.swift")).unwrap(), "X");
    }

    /// On success: changed files rewritten, stale `.graphql.swift` swept, foreign
    /// files left alone (the delete-then-write virtue survives the refactor).
    #[test]
    fn reconcile_rewrites_changed_deletes_stale_keeps_foreign() {
        let dir = fresh_test_dir("rewrite");
        std::fs::write(dir.join("A.graphql.swift"), "old").unwrap();
        std::fs::write(dir.join("Stale.graphql.swift"), "orphan").unwrap();
        std::fs::write(dir.join("README.md"), "keep").unwrap();
        let files = BTreeMap::from([("A.graphql.swift".to_string(), "new".to_string())]);
        let stats = reconcile_output_dir(&dir, &files).unwrap();
        assert_eq!(std::fs::read_to_string(dir.join("A.graphql.swift")).unwrap(), "new");
        assert!(!dir.join("Stale.graphql.swift").exists(), "stale .graphql.swift must be swept");
        assert!(dir.join("README.md").exists(), "foreign files must be preserved");
        assert_eq!(stats.written, 1);
        assert_eq!(stats.deleted, 1);
    }

    /// A mid-run write failure must leave existing output untouched — writes run
    /// before deletes, so a failed write never reaches the stale sweep.
    #[test]
    fn reconcile_failed_write_does_not_delete_stale() {
        let dir = fresh_test_dir("fail");
        // Force the write of A to fail: target path is a non-empty directory.
        std::fs::create_dir(dir.join("A.graphql.swift")).unwrap();
        std::fs::write(dir.join("A.graphql.swift").join("blocker"), "x").unwrap();
        std::fs::write(dir.join("Stale.graphql.swift"), "orphan").unwrap();
        let files = BTreeMap::from([("A.graphql.swift".to_string(), "new".to_string())]);
        assert!(reconcile_output_dir(&dir, &files).is_err(), "writing onto a dir must fail");
        assert!(
            dir.join("Stale.graphql.swift").exists(),
            "a failed run must not delete stale files (writes precede deletes)"
        );
    }

    // MARK: - Exhaustive interface cases (decode-hardening)

    fn element_children() -> Vec<PlanField> {
        // Interface selection that inline-fragments ONLY VideoElement.
        vec![typename_field(), id_field(), scalar_on("url", "String", "VideoElement")]
    }

    fn element_implementors() -> BTreeMap<String, Vec<String>> {
        BTreeMap::from([(
            "Element".to_string(),
            vec![
                "VideoElement".to_string(),
                "AudioElement".to_string(),
                "ImageElement".to_string(),
                "LottieElement".to_string(),
            ],
        )])
    }

    /// Flag ON: a case per schema implementor (4) + unknown. Non-selected
    /// implementors get a typename-pinned struct carrying the interface fields.
    #[test]
    fn interface_exhaustive_emits_case_per_schema_implementor() {
        let children = element_children();
        let interfaces = element_implementors();
        let safe: BTreeSet<String> = BTreeSet::new();
        let ctx = EmitCtx { safe_fragments: &safe, interfaces: &interfaces, exhaustive: true };
        let out = render_typed_enum_impl("Element", "Element", &children, &ctx, "");

        for case in ["videoElement(VideoElement)", "audioElement(AudioElement)",
                     "imageElement(ImageElement)", "lottieElement(LottieElement)"] {
            assert!(out.contains(&format!("case {case}")), "missing case {case}:\n{out}");
        }
        assert!(out.contains("case unknown(Shared)"), "{out}");
        // Non-selected implementor → typename-pinned struct (the draft-can't-lie property).
        assert!(out.contains("@CachebayData(typename: \"AudioElement\")"), "{out}");
        // Selected implementor keeps its variant field.
        assert!(out.contains("public let url: String"), "{out}");
    }

    /// Flag OFF (default): only inline-fragmented variants — the old shape.
    #[test]
    fn interface_nonExhaustive_emits_only_selected_variants() {
        let out = render_typed_enum("Element", "Element", &element_children(), "");
        assert!(out.contains("case videoElement(VideoElement)"), "{out}");
        assert!(!out.contains("audioElement"), "non-exhaustive must not add unselected implementors:\n{out}");
        assert!(out.contains("case unknown(Shared)"), "{out}");
    }

    /// Under exhaustive, an inline fragment that narrows via ANOTHER interface
    /// (not a concrete implementor) would silently drop its fields — so it's a
    /// hard error, not a quiet loss.
    #[test]
    fn exhaustive_rejects_non_implementor_inline_fragment() {
        let narrowing = scalar_on("caption", "String", "Captionable"); // another interface
        let elements = object("elements", "Element", vec![typename_field(), id_field(), narrowing]);
        let plan = plan_fixture("Q", OpKind::Query, "Query", vec![elements]);
        let interfaces = element_implementors(); // Element -> 4 concrete types, no Captionable
        let err = validate_exhaustive(&[plan], &interfaces).unwrap_err().to_string();
        assert!(err.contains("Captionable") && err.contains("Element"), "{err}");
    }

    /// Concrete-implementor inline fragments are fine.
    #[test]
    fn exhaustive_allows_concrete_implementor_inline_fragments() {
        let v = scalar_on("url", "String", "VideoElement");
        let elements = object("elements", "Element", vec![typename_field(), id_field(), v]);
        let plan = plan_fixture("Q", OpKind::Query, "Query", vec![elements]);
        assert!(validate_exhaustive(&[plan], &element_implementors()).is_ok());
    }

    // MARK: - Tri-state nullable input encoding (GraphQLNullable)

    fn ishape(named: &str, kind: TypeKind, nullable: bool, list: bool, inner_nullable: bool) -> TypeShape {
        TypeShape { named: named.into(), kind, nullable, list, inner_nullable }
    }
    fn ifield(name: &str, shape: TypeShape) -> InputField {
        InputField { name: name.into(), graphql_type: String::new(), shape }
    }
    fn itype(name: &str, is_one_of: bool, fields: Vec<InputField>) -> BTreeMap<String, InputTypeDef> {
        let mut m = BTreeMap::new();
        m.insert(name.into(), InputTypeDef { name: name.into(), fields, is_one_of });
        m
    }

    /// A schema-nullable input field must become the tri-state wrapper, default
    /// to `nil` (= OMIT), and OMIT-vs-null via `__cachebayEncode` — never the old
    /// `?? .null` that forced explicit null and could never omit.
    #[test]
    fn nullable_input_field_is_tristate_and_omits() {
        let out = render_inputs(&itype(
            "UpdateInput",
            false,
            vec![ifield("name", ishape("String", TypeKind::Scalar, true, false, false))],
        ));
        assert!(out.contains("public var name: Cachebay.GraphQLNullable<String>"), "type: {out}");
        assert!(out.contains("name: Cachebay.GraphQLNullable<String> = nil"), "default: {out}");
        assert!(
            out.contains("if let __v = name.__cachebayEncode({ v in .string(v) }) { out[\"name\"] = __v }"),
            "encoder: {out}"
        );
        assert!(!out.contains("?? .null"), "must not force explicit null: {out}");
    }

    /// Non-null input fields are bare and always emit (no omit, no wrapper).
    #[test]
    fn nonnull_input_field_is_bare_and_always_emits() {
        let out = render_inputs(&itype(
            "CreateInput",
            false,
            vec![ifield("id", ishape("ID", TypeKind::Scalar, false, false, false))],
        ));
        assert!(out.contains("public var id: String\n"), "type: {out}");
        assert!(!out.contains("id: String = nil"), "no nil default: {out}");
        assert!(out.contains("out[\"id\"] = .string(id)"), "encoder: {out}");
        assert!(!out.contains("GraphQLNullable"), "no wrapper on non-null: {out}");
    }

    /// A nullable list `[String!]` wraps the list as a whole: `GraphQLNullable<[String]>`.
    #[test]
    fn nullable_list_input_field_wraps_the_list() {
        let out = render_inputs(&itype(
            "FilterInput",
            false,
            vec![ifield("tags", ishape("String", TypeKind::Scalar, true, true, false))],
        ));
        assert!(out.contains("public var tags: Cachebay.GraphQLNullable<[String]>"), "type: {out}");
        assert!(
            out.contains("if let __v = tags.__cachebayEncode({ v in Cachebay.JSONValue.array(v.map { .string($0) }) }) { out[\"tags\"] = __v }"),
            "encoder: {out}"
        );
    }

    /// `@oneOf` members keep plain `Optional` — explicit null is invalid there,
    /// so `nil` = omit and the value forwards unmodified (existing `if let`).
    #[test]
    fn oneof_input_field_stays_optional_not_tristate() {
        let out = render_inputs(&itype(
            "SearchBy",
            true,
            vec![ifield("email", ishape("String", TypeKind::Scalar, true, false, false))],
        ));
        assert!(out.contains("public var email: String?"), "type: {out}");
        assert!(!out.contains("GraphQLNullable"), "oneOf must not be tristate: {out}");
        assert!(
            out.contains("if let email = email { out[\"email\"] = .string(email) }"),
            "encoder: {out}"
        );
        assert!(!out.contains("?? .null"), "{out}");
    }
}
