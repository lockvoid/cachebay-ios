//! Transform apollo-compiler's HIR into a cachebay `CachePlan` IR that the
//! emitter serializes to Swift. Mirrors the lowering pass in
//! `Sources/Cachebay/Compiler/Lowering.swift` but runs at build time.

use apollo_compiler::ast::{DirectiveList, OperationType, Type, Value};
use apollo_compiler::executable::{Field, Fragment, Operation, Selection, SelectionSet};
use apollo_compiler::{ExecutableDocument, Name, Node};

use crate::load::CompilerContext;
use crate::schema::{shape_of, TypeShape};

#[derive(Debug, Clone)]
pub struct Plan {
    pub name: String,
    pub operation_kind: OpKind,
    pub root_typename: String,
    pub variables: Vec<VarDef>,
    pub root: Vec<PlanField>,
    pub network_query: String,
    pub source_path: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OpKind {
    Query,
    Mutation,
    Subscription,
    Fragment,
}

#[derive(Debug, Clone)]
pub struct VarDef {
    pub name: String,
    pub graphql_type: String,
    pub swift_type: String,
    pub nullable: bool,
    pub has_default: bool,
    /// Resolved type shape — used by the emitter to pick the right JSONValue bridge.
    pub shape: TypeShape,
}

#[derive(Debug, Clone)]
pub struct PlanField {
    pub response_key: String,
    pub field_name: String,
    pub expected_arg_names: Vec<String>,
    /// Serialized argument AST (variable refs preserved) for runtime key-building.
    pub arg_template: Vec<ArgPiece>,
    pub type_condition: Option<String>,
    pub is_connection: bool,
    pub connection_key: Option<String>,
    pub connection_filters: Vec<String>,
    pub connection_mode: Option<ConnectionMode>,
    pub page_args: Vec<String>,
    /// Named type (unwrapped) of this field's result; "" if not applicable.
    pub named_type: String,
    /// Swift-level nullability/list shape for the emitter.
    pub output_shape: OutputShape,
    pub sel_id: String,
    pub children: Vec<PlanField>,
    /// Codegen-only: when this field's selection set is *exactly* one
    /// fragment spread (no extra fields), the named fragment whose
    /// `Data` should be reused as this field's typed shape. Lets the
    /// emitter skip a duplicate nested struct and reference
    /// `FragmentName.Data` instead — collapsing the per-position type
    /// duplication that forced consumers to write a converter per
    /// query that spreads the same fragment.
    pub reuse_fragment: Option<String>,
    /// `@skip(if: ...)` argument when present on this field. Evaluated
    /// at runtime by `PlanField.shouldInclude(variables:)` — when the
    /// condition resolves to `true`, the field is excluded from the
    /// selection (no read, no write, no dep).
    pub skip_if: Option<DirectiveCondition>,
    /// `@include(if: ...)` argument when present. When the condition
    /// resolves to `false`, the field is excluded.
    pub include_if: Option<DirectiveCondition>,
    /// Construction default (a Swift literal like `"a0"` / `0.0` / `true`) from
    /// the schema field's `@cachebay(default: …)` directive. Emitted as
    /// `@CachebayDefault(<literal>)` in the typed struct (proposal §6).
    pub default_value: Option<String>,
    /// Swift type for a custom-scalar leaf, from the scalar's
    /// `@cachebay(swiftType: "…")` directive (e.g. `Foundation.Date`). When unset,
    /// custom scalars fall back to `Cachebay.JSONValue` (raw passthrough).
    pub swift_scalar_type: Option<String>,
    /// Generated Swift enum name when this leaf's named type is a GraphQL enum.
    /// The typed emitter wraps it as `Cachebay.GraphQLEnum<Name>` (forward-compat
    /// output decode); `None` for non-enum leaves.
    pub swift_enum_type: Option<String>,
}

#[derive(Debug, Clone)]
pub enum ArgPiece {
    /// Literal JSON-encodable value, already serialized to Swift `JSONValue` shape.
    Literal(String),
    /// Reference to a variable by name — resolved at runtime by `buildArgs`.
    Variable(String),
    /// `name: value` separator string.
    Raw(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionMode {
    Infinite,
    Page,
}

/// Argument to `@skip(if: ...)` / `@include(if: ...)`. Mirrors the
/// Swift-side `DirectiveCondition` enum — either a literal Boolean
/// (`@include(if: true)`) or a Boolean variable reference
/// (`@include(if: $withProject)`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DirectiveCondition {
    Variable(String),
    Constant(bool),
}

#[derive(Debug, Clone)]
pub enum OutputShape {
    /// Scalar / enum / custom scalar; no children.
    Leaf { nullable: bool, list: bool },
    /// Object / interface / union; has `children`.
    Object { nullable: bool, list: bool },
}

pub fn build_plans(ctx: &CompilerContext) -> anyhow::Result<Vec<Plan>> {
    let mut plans = Vec::new();
    let exec_doc = &ctx.document;
    for op in exec_doc.operations.iter() {
        plans.push(build_operation_plan(op, ctx)?);
    }
    for (_, frag) in exec_doc.fragments.iter() {
        plans.push(build_fragment_plan(frag, ctx)?);
    }
    Ok(plans)
}

fn build_operation_plan(
    op: &Node<Operation>,
    ctx: &CompilerContext,
) -> anyhow::Result<Plan> {
    let exec_doc: &ExecutableDocument = &ctx.document;
    let name = op.name.as_ref().map(|n| n.to_string()).unwrap_or_else(|| "Anonymous".to_string());
    let kind = match op.operation_type {
        OperationType::Query => OpKind::Query,
        OperationType::Mutation => OpKind::Mutation,
        OperationType::Subscription => OpKind::Subscription,
    };
    let root_typename = match op.operation_type {
        OperationType::Query => "Query".to_string(),
        OperationType::Mutation => "Mutation".to_string(),
        OperationType::Subscription => "Subscription".to_string(),
    };

    let variables = op
        .variables
        .iter()
        .map(|v| {
            let shape = shape_of(&ctx.schema, &v.ty);
            VarDef {
                name: v.name.to_string(),
                graphql_type: v.ty.to_string(),
                // Operation variables are top-level input positions and never
                // `@oneOf` members, so a nullable variable is always tri-state.
                swift_type: swift_input_type(&shape, true),
                nullable: shape.nullable,
                has_default: v.default_value.is_some(),
                shape,
            }
        })
        .collect();

    let root = lower_selection_set(&op.selection_set, &root_typename, ctx, exec_doc);
    let network_query = render_network_query(op, exec_doc);

    Ok(Plan {
        name,
        operation_kind: kind,
        root_typename,
        variables,
        root,
        network_query,
        source_path: ctx.source_path_for(op.location()),
    })
}

fn build_fragment_plan(
    frag: &Node<Fragment>,
    ctx: &CompilerContext,
) -> anyhow::Result<Plan> {
    let exec_doc: &ExecutableDocument = &ctx.document;
    let root_typename = frag.type_condition().to_string();
    let root = lower_selection_set(&frag.selection_set, &root_typename, ctx, exec_doc);
    Ok(Plan {
        name: frag.name.to_string(),
        operation_kind: OpKind::Fragment,
        root_typename,
        variables: Vec::new(),
        root,
        network_query: inject_typename(&strip_connection_directive(&frag.serialize().to_string()), false),
        source_path: ctx.source_path_for(frag.location()),
    })
}

fn lower_selection_set(
    sel_set: &SelectionSet,
    parent_typename: &str,
    ctx: &CompilerContext,
    exec_doc: &ExecutableDocument,
) -> Vec<PlanField> {
    let mut out = Vec::new();
    let mut seen_typename = false;
    for selection in &sel_set.selections {
        match selection {
            Selection::Field(f) => {
                if f.name.as_str() == "__typename" {
                    if seen_typename { continue; }
                    seen_typename = true;
                }
                out.push(lower_field(f, parent_typename, ctx, exec_doc));
            }
            Selection::FragmentSpread(spread) => {
                if let Some(frag) = exec_doc.fragments.get(&spread.fragment_name) {
                    let lowered = lower_selection_set(&frag.selection_set, frag.type_condition().as_str(), ctx, exec_doc);
                    let frag_tc = frag.type_condition().to_string();
                    out.extend(lowered.into_iter().map(|mut f| {
                        // Preserve a narrower type condition that the inner
                        // selection already attached (e.g. fields inside
                        // `... on VideoElement` keep `"VideoElement"`).
                        // Only stamp the fragment's own condition when none
                        // was set by a deeper selection.
                        if f.type_condition.is_none() {
                            f.type_condition = Some(frag_tc.clone());
                        }
                        f
                    }));
                }
            }
            Selection::InlineFragment(inline) => {
                let type_cond = inline
                    .type_condition
                    .as_ref()
                    .map(|n| n.to_string())
                    .unwrap_or_else(|| parent_typename.to_string());
                let lowered = lower_selection_set(&inline.selection_set, &type_cond, ctx, exec_doc);
                out.extend(lowered.into_iter().map(|mut f| {
                    if f.type_condition.is_none() {
                        f.type_condition = Some(type_cond.clone());
                    }
                    f
                }));
            }
        }
    }
    // Ensure __typename on every object selection set (matches Swift Compiler.injectRecursive).
    let has_typename_after_merge = out.iter().any(|f| f.field_name == "__typename");
    if !seen_typename && !has_typename_after_merge && parent_typename != "" && !out.is_empty() {
        out.push(synthetic_typename_field());
    }
    // Dedupe respecting polymorphism: shared fields (no type condition, or
    // condition matching the parent) take precedence and exclude any
    // identically-named field from a narrower type case. Within the per-type
    // groups, dedupe by `(response_key, type_condition)` so each `As<Type>`
    // struct sees its full field set.
    //
    // Naïvely deduping by `response_key` alone collapsed every type case
    // into the first one encountered — e.g. `...VideoClipFields` would
    // survive but `...SpeechClipFields` and `...MusicClipFields` got
    // silently dropped, so only `asVideoClip` accessors were emitted.
    let mut shared_keys: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for f in &out {
        let is_shared = match &f.type_condition {
            None => true,
            Some(tc) => tc == parent_typename,
        };
        if is_shared {
            shared_keys.insert(f.response_key.clone());
        }
    }
    let mut seen_pairs: std::collections::BTreeSet<(String, Option<String>)> =
        std::collections::BTreeSet::new();
    out.retain(|f| {
        let is_shared = match &f.type_condition {
            None => true,
            Some(tc) => tc == parent_typename,
        };
        if is_shared {
            // Shared keys: dedupe by name only (collapsing identical fields
            // pulled in by multiple fragment spreads on the parent type).
            seen_pairs.insert((f.response_key.clone(), None))
        } else {
            // Drop type-narrowed entries that the parent already surfaces as
            // shared — the AsX struct will inherit them via the shared list.
            if shared_keys.contains(&f.response_key) {
                return false;
            }
            seen_pairs.insert((f.response_key.clone(), f.type_condition.clone()))
        }
    });
    out
}

fn lower_field(f: &Field, parent_typename: &str, ctx: &CompilerContext, exec_doc: &ExecutableDocument) -> PlanField {
    let _ = parent_typename; // reserved for future type-condition inference
    let response_key = f.response_key().to_string();
    let field_name = f.name.to_string();
    let expected_arg_names: Vec<String> = f.arguments.iter().map(|a| a.name.to_string()).collect();
    let arg_template = build_arg_template(f);

    // @connection
    let (is_connection, connection_key, connection_filters, connection_mode, page_args) =
        parse_connection_directive(&f.directives, &field_name, &expected_arg_names);

    // @skip / @include — spec-mandated; honoured at runtime by the
    // materializer (`PlanField.shouldInclude(variables:)`).
    let (skip_if, include_if) = parse_skip_include_directives(&f.directives);

    // Pure-fragment-spread provenance MUST be detected against the AST
    // BEFORE lowering, since lowering inlines the fragment's selections
    // and the "exactly one spread" property is irrecoverable afterwards.
    let reuse_fragment = detect_pure_fragment_spread(&f.selection_set);

    let children = if f.selection_set.selections.is_empty() {
        Vec::new()
    } else {
        let nested_parent = f.ty().inner_named_type().to_string();
        lower_selection_set(&f.selection_set, &nested_parent, ctx, exec_doc)
    };

    let output_shape = shape_for_type(&f.ty(), !children.is_empty());
    let named_type = f.ty().inner_named_type().to_string();

    // `@cachebay(default: …)` lives on the SCHEMA field definition (not the
    // selection), so read it off the resolved field definition.
    let default_value = parse_cachebay_default(&f.definition.directives);
    // Effective scalar swiftType (in-SDL `@cachebay(swiftType:)` ⊕ config),
    // precomputed onto the context before plan building.
    let swift_scalar_type = ctx.scalar_types.get(named_type.as_str()).cloned();
    // When the leaf's named type is a GraphQL enum, the typed emitter wraps it
    // in `Cachebay.GraphQLEnum<…>` instead of collapsing to `JSONValue`.
    let swift_enum_type = lookup_enum_swift_type(&ctx.schema, &named_type);

    let sel_id = fingerprint_field(
        &response_key,
        &field_name,
        None,
        is_connection,
        &expected_arg_names,
        &children,
    );

    PlanField {
        response_key,
        field_name,
        expected_arg_names,
        arg_template,
        type_condition: None,
        is_connection,
        connection_key,
        connection_filters,
        connection_mode,
        page_args,
        named_type,
        output_shape,
        sel_id,
        children,
        reuse_fragment,
        skip_if,
        include_if,
        default_value,
        swift_scalar_type,
        swift_enum_type,
    }
}

/// Returns the Swift enum type name when `named_type` is a GraphQL enum. The
/// Swift name equals the GraphQL name (matching the input typer's
/// `TypeKind::Enum => shape.named`); the typed emitter wraps output enum leaves
/// in `Cachebay.GraphQLEnum<…>`. `None` for scalars / objects / interfaces.
fn lookup_enum_swift_type(schema: &apollo_compiler::Schema, named_type: &str) -> Option<String> {
    use apollo_compiler::schema::ExtendedType;
    match schema.types.get(named_type) {
        Some(ExtendedType::Enum(_)) => Some(named_type.to_string()),
        _ => None,
    }
}

/// Reads `@cachebay(swiftType: "…")` off a scalar type definition, mapping a
/// custom scalar (e.g. `Date`) to a Swift type (e.g. `Foundation.Date`). The
/// consumer is responsible for conforming that type to `CachebayValue`
/// (Cachebay ships conformances for `URL`/`Date`).
/// In-SDL `@cachebay(swiftType:)` mappings for every scalar type. Merged with the
/// `cachebay.config.json` scalar map (see `effective_scalar_types`).
pub fn collect_sdl_scalar_types(
    schema: &apollo_compiler::Schema,
) -> std::collections::BTreeMap<String, String> {
    use apollo_compiler::schema::ExtendedType;
    let mut out = std::collections::BTreeMap::new();
    for (name, ty) in schema.types.iter() {
        let ExtendedType::Scalar(scalar) = ty else { continue };
        let Some(dir) = scalar.directives.iter().find(|d| d.name.as_str() == "cachebay") else { continue };
        for arg in dir.arguments.iter() {
            if arg.name.as_str() == "swiftType" {
                if let Value::String(s) = &*arg.value {
                    if !s.is_empty() {
                        out.insert(name.to_string(), s.to_string());
                    }
                }
            }
        }
    }
    out
}

/// Effective scalar → Swift-type map: in-SDL `@cachebay(swiftType:)` directives
/// merged with the config `scalars`, hard-erroring on disagreement (no silent
/// precedence). Stored on `CompilerContext.scalar_types` before plan building.
pub fn effective_scalar_types(
    schema: &apollo_compiler::Schema,
    config: &std::collections::BTreeMap<String, String>,
) -> anyhow::Result<std::collections::BTreeMap<String, String>> {
    crate::config::merge_scalar_types(&collect_sdl_scalar_types(schema), config)
}

/// Reads a `@cachebay(default: …)` construction default off a schema field's
/// directive list and renders it as a Swift literal (`"a0"` / `0.0` / `true`).
fn parse_cachebay_default(directives: &DirectiveList) -> Option<String> {
    let dir = directives.iter().find(|d| d.name.as_str() == "cachebay")?;
    for arg in dir.arguments.iter() {
        if arg.name.as_str() == "default" {
            return value_to_swift_literal(&arg.value);
        }
    }
    None
}

fn value_to_swift_literal(v: &Value) -> Option<String> {
    match v {
        Value::String(s) => Some(format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))),
        Value::Boolean(b) => Some(b.to_string()),
        Value::Int(i) => Some(i.to_string()),
        Value::Float(f) => Some(f.to_string()),
        Value::Enum(name) => Some(format!(".{name}")),
        _ => None,
    }
}

/// Detects whether a field's selection set is a "pure" fragment spread —
/// exactly one `...FragmentName` reference, with no other fields or
/// inline fragments at the same scope. Pure-spread positions can reuse
/// the fragment's already-emitted `Data` type instead of generating a
/// fresh nested struct, deduplicating consumer-side converters across
/// queries that spread the same fragment.
///
/// `__typename` field selections at the parent scope are tolerated:
/// users sometimes write them explicitly, and cachebay auto-injects
/// them anyway. They don't make the position non-pure.
fn detect_pure_fragment_spread(sel_set: &SelectionSet) -> Option<String> {
    let mut spread_name: Option<String> = None;
    for selection in &sel_set.selections {
        match selection {
            Selection::Field(f) => {
                // Tolerate user-written `__typename` — same field gets
                // auto-injected anyway. Anything else (`id`, `title`,
                // …) is an extra and disqualifies the position.
                if f.name.as_str() != "__typename" {
                    return None;
                }
            }
            Selection::FragmentSpread(s) => {
                if spread_name.is_some() {
                    // Multiple spreads can't collapse to one type.
                    return None;
                }
                spread_name = Some(s.fragment_name.to_string());
            }
            Selection::InlineFragment(_) => {
                // Inline fragments add fields beyond the spread.
                return None;
            }
        }
    }
    spread_name
}

fn synthetic_typename_field() -> PlanField {
    PlanField {
        response_key: "__typename".into(),
        field_name: "__typename".into(),
        expected_arg_names: vec![],
        arg_template: vec![],
        type_condition: None,
        is_connection: false,
        connection_key: None,
        connection_filters: vec![],
        connection_mode: None,
        page_args: vec![],
        named_type: "String".into(),
        output_shape: OutputShape::Leaf { nullable: false, list: false },
        sel_id: "__typename:__typename".into(),
        children: vec![],
        reuse_fragment: None,
        skip_if: None,
        include_if: None,
        default_value: None,
        swift_scalar_type: None,
        swift_enum_type: None,
    }
}

/// Parse `@skip(if: …)` and `@include(if: …)` from a field's directive
/// list. Other directives are ignored at this layer (only `@connection`
/// has dedicated handling).
///
/// Spec §3.13: the `if` argument is `Boolean!` — either a Boolean
/// literal or a Boolean variable reference. Other shapes are
/// validation errors server-side; we simply skip them (the emitter
/// won't write a directive arg, and the runtime treats absent as
/// "include").
fn parse_skip_include_directives(
    directives: &DirectiveList,
) -> (Option<DirectiveCondition>, Option<DirectiveCondition>) {
    let mut skip_if: Option<DirectiveCondition> = None;
    let mut include_if: Option<DirectiveCondition> = None;
    for dir in directives.iter() {
        let cond = match dir.arguments.iter().find(|a| a.name.as_str() == "if") {
            Some(a) => directive_condition_from_value(&a.value),
            None => None,
        };
        match dir.name.as_str() {
            "skip" => skip_if = cond,
            "include" => include_if = cond,
            _ => {}
        }
    }
    (skip_if, include_if)
}

fn directive_condition_from_value(v: &Node<Value>) -> Option<DirectiveCondition> {
    match v.as_ref() {
        Value::Boolean(b) => Some(DirectiveCondition::Constant(*b)),
        Value::Variable(name) => Some(DirectiveCondition::Variable(name.to_string())),
        _ => None,
    }
}

fn parse_connection_directive(
    directives: &DirectiveList,
    field_name: &str,
    field_arg_names: &[String],
) -> (bool, Option<String>, Vec<String>, Option<ConnectionMode>, Vec<String>) {
    static PAGINATION: &[&str] = &["first", "last", "after", "before"];

    let dir = directives.iter().find(|d| d.name.as_str() == "connection");
    let Some(dir) = dir else {
        return (false, None, vec![], None, vec![]);
    };
    let mut key = None;
    let mut filters: Option<Vec<String>> = None;
    let mut mode = None;
    for arg in dir.arguments.iter() {
        match arg.name.as_str() {
            "key" => {
                if let Value::String(s) = &*arg.value {
                    if !s.is_empty() { key = Some(s.clone()); }
                }
            }
            "filters" => {
                if let Value::List(items) = &*arg.value {
                    let xs: Vec<String> = items.iter().filter_map(|v| {
                        if let Value::String(s) = &**v { Some(s.clone()) } else { None }
                    }).collect();
                    filters = Some(xs);
                }
            }
            "mode" => {
                if let Value::String(s) = &*arg.value {
                    mode = match s.as_str() {
                        "infinite" => Some(ConnectionMode::Infinite),
                        "page" => Some(ConnectionMode::Page),
                        _ => None,
                    };
                }
            }
            _ => {}
        }
    }
    let connection_key = key.or_else(|| Some(field_name.to_string()));
    let connection_filters = filters.unwrap_or_else(|| {
        field_arg_names.iter().filter(|n| !PAGINATION.contains(&n.as_str())).cloned().collect()
    });
    let page_args: Vec<String> = field_arg_names.iter().filter(|n| PAGINATION.contains(&n.as_str())).cloned().collect();
    (true, connection_key, connection_filters, mode, page_args)
}

fn build_arg_template(f: &Field) -> Vec<ArgPiece> {
    if f.arguments.is_empty() {
        return Vec::new();
    }
    let mut out = Vec::new();
    for (i, arg) in f.arguments.iter().enumerate() {
        if i > 0 {
            out.push(ArgPiece::Raw(",".into()));
        }
        out.push(ArgPiece::Raw(format!("\"{}\":", arg.name)));
        serialize_value(&arg.value, &mut out);
    }
    out
}

fn serialize_value(v: &Value, out: &mut Vec<ArgPiece>) {
    match v {
        Value::Null => out.push(ArgPiece::Literal("null".into())),
        Value::Boolean(b) => out.push(ArgPiece::Literal(if *b { "true".into() } else { "false".into() })),
        Value::Int(i) => out.push(ArgPiece::Literal(i.as_str().to_string())),
        Value::Float(f) => out.push(ArgPiece::Literal(f.as_str().to_string())),
        Value::String(s) => out.push(ArgPiece::Literal(format!("\"{}\"", escape_json(s)))),
        Value::Enum(e) => out.push(ArgPiece::Literal(format!("\"{}\"", e))),
        Value::Variable(v) => out.push(ArgPiece::Variable(v.to_string())),
        Value::List(items) => {
            out.push(ArgPiece::Raw("[".into()));
            for (i, item) in items.iter().enumerate() {
                if i > 0 { out.push(ArgPiece::Raw(",".into())); }
                serialize_value(item, out);
            }
            out.push(ArgPiece::Raw("]".into()));
        }
        Value::Object(fields) => {
            out.push(ArgPiece::Raw("{".into()));
            for (i, (name, value)) in fields.iter().enumerate() {
                if i > 0 { out.push(ArgPiece::Raw(",".into())); }
                out.push(ArgPiece::Raw(format!("\"{}\":", name)));
                serialize_value(value, out);
            }
            out.push(ArgPiece::Raw("}".into()));
        }
    }
}

fn shape_for_type(ty: &Type, has_children: bool) -> OutputShape {
    // Outer nullability and list-ness come from the OUTERMOST wrapper ONLY. The
    // previous loop also let an inner element's non-null clobber `nullable`, so
    // `[T!]` (a NULLABLE list of non-null elements) was mis-typed as non-optional
    // `[T]` — a server `null` then failed to decode and cascaded the parent to
    // nil. `[T!]` is `[T]?`; only the outermost `!` removes the optional.
    // (Element-level nullability isn't tracked here — OutputShape carries a single
    // `list` flag, matching the prior behavior.)
    let (nullable, list) = match ty {
        Type::NonNullNamed(_) => (false, false),
        Type::Named(_) => (true, false),
        Type::NonNullList(_) => (false, true),
        Type::List(_) => (true, true),
    };
    if has_children { OutputShape::Object { nullable, list } } else { OutputShape::Leaf { nullable, list } }
}

#[cfg(test)]
mod shape_for_type_tests {
    use super::*;

    fn named(s: &str) -> Name {
        Name::new(s).unwrap()
    }
    fn outer_nullable(s: OutputShape) -> bool {
        match s {
            OutputShape::Leaf { nullable, .. } | OutputShape::Object { nullable, .. } => nullable,
        }
    }
    fn is_list(s: OutputShape) -> bool {
        match s {
            OutputShape::Leaf { list, .. } | OutputShape::Object { list, .. } => list,
        }
    }

    /// `[Sub!]` — the LIST is nullable; the element's `!` must NOT flip the list's
    /// nullability. Today it does (→ `[Sub]` instead of `[Sub]?`, so a server
    /// `null` fails to decode and cascades the parent to nil).
    #[test]
    fn nullable_list_of_nonnull_element_is_outer_nullable() {
        let ty = Type::List(Box::new(Type::NonNullNamed(named("Sub")))); // [Sub!]
        let shape = shape_for_type(&ty, true);
        assert!(is_list(shape.clone()), "{shape:?}");
        assert!(outer_nullable(shape.clone()), "[Sub!] is a NULLABLE list → [Sub]?; got {shape:?}");
    }

    /// `[Sub!]!` — non-null list → not optional.
    #[test]
    fn nonnull_list_is_not_outer_nullable() {
        let ty = Type::NonNullList(Box::new(Type::NonNullNamed(named("Sub")))); // [Sub!]!
        let shape = shape_for_type(&ty, true);
        assert!(is_list(shape.clone()) && !outer_nullable(shape.clone()), "{shape:?}");
    }

    /// `[Sub]` — nullable list of nullable elements → still outer-nullable.
    #[test]
    fn nullable_list_of_nullable_element_is_outer_nullable() {
        let ty = Type::List(Box::new(Type::Named(named("Sub")))); // [Sub]
        let shape = shape_for_type(&ty, true);
        assert!(is_list(shape.clone()) && outer_nullable(shape.clone()), "{shape:?}");
    }

    /// Bare named: `Sub!` → not nullable, not a list; `Sub` → nullable.
    #[test]
    fn bare_named_nullability() {
        assert!(!outer_nullable(shape_for_type(&Type::NonNullNamed(named("Sub")), false)));
        assert!(outer_nullable(shape_for_type(&Type::Named(named("Sub")), false)));
        assert!(!is_list(shape_for_type(&Type::NonNullNamed(named("Sub")), false)));
    }
}

/// Map a resolved `TypeShape` to a Swift type string, honouring
/// nullability and list wrapping and using the generated struct name for
/// user-defined input objects / enums.
/// The base + list type WITHOUT field-level optionality — the `Inner` of an
/// input position's `Inner?` / `Cachebay.GraphQLNullable<Inner>`.
///
/// Always qualifies `JSONValue` with the `Cachebay.` module prefix so host apps
/// that also import another GraphQL client (Apollo's `JSONValue` is a frequent
/// collision during migration) get an unambiguous type lookup.
fn inner_swift_type(shape: &TypeShape) -> String {
    use crate::schema::TypeKind;
    let base: String = match shape.kind {
        TypeKind::Scalar => match shape.named.as_str() {
            "String" | "ID" => "String".into(),
            "Int" => "Int".into(),
            "Float" => "Double".into(),
            "Boolean" => "Bool".into(),
            _ => "Cachebay.JSONValue".into(),
        },
        TypeKind::CustomScalar => "Cachebay.JSONValue".into(),
        TypeKind::Enum => shape.named.clone(),
        TypeKind::InputObject => shape.named.clone(),
    };
    if shape.list {
        if shape.inner_nullable { format!("[{base}?]") } else { format!("[{base}]") }
    } else {
        base
    }
}

/// Map a resolved `TypeShape` to a Swift type string, honouring nullability and
/// list wrapping (plain `Optional` form — used where the omit-vs-explicit-null
/// distinction is irrelevant).
pub fn swift_type_for_shape(shape: &TypeShape) -> String {
    let inner = inner_swift_type(shape);
    if shape.nullable { format!("{inner}?") } else { inner }
}

/// Swift type for an **input position** (input-object field or operation
/// variable). A schema-nullable position becomes the tri-state
/// `Cachebay.GraphQLNullable<Inner>` so callers can distinguish OMIT (`nil` /
/// `.none`) from explicit null (`.null`) — the GraphQL spec treats an absent
/// input field and an `= null` field differently. The one exception is `@oneOf`
/// members (`tristate == false`): explicit null is invalid there, so they stay
/// plain `Optional` where `nil` simply means omit. Non-null positions are bare.
pub fn swift_input_type(shape: &TypeShape, tristate: bool) -> String {
    let inner = inner_swift_type(shape);
    if !shape.nullable {
        inner
    } else if tristate {
        format!("Cachebay.GraphQLNullable<{inner}>")
    } else {
        format!("{inner}?")
    }
}

fn escape_json(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn fingerprint_field(
    response_key: &str,
    field_name: &str,
    type_condition: Option<&str>,
    is_connection: bool,
    arg_names: &[String],
    children: &[PlanField],
) -> String {
    let mut parts = vec![response_key.to_string(), field_name.to_string()];
    if let Some(tc) = type_condition { parts.push(format!("@{tc}")); }
    if is_connection { parts.push("@connection".into()); }
    if !arg_names.is_empty() {
        let mut names = arg_names.to_vec();
        names.sort();
        parts.push(format!("({})", names.join(",")));
    }
    if !children.is_empty() {
        let mut sorted = children.to_vec();
        sorted.sort_by(|a, b| a.response_key.cmp(&b.response_key).then(a.field_name.cmp(&b.field_name)));
        let child_fps: Vec<String> = sorted.iter().map(|c| c.sel_id.clone()).collect();
        parts.push(format!("{{{}}}", child_fps.join(",")));
    }
    parts.join(":")
}

fn render_network_query(op: &Operation, exec_doc: &ExecutableDocument) -> String {
    // Strategy (matches Swift `buildNetworkQuery` + `Typename.injectNested`):
    // serialize the operation + required named fragments, strip
    // `@connection`, and inject `__typename` into every nested selection
    // set. apollo-compiler's `serialize()` gives us a byte-identical
    // round trip, so we post-process. The injection contract MUST match
    // `CachePlan.networkQuery`'s docstring ("Network-safe query string
    // (with `__typename` added, `@connection` stripped)") — without
    // it the iOS runtime sends a query with no `__typename`, the server
    // omits it from the response, and `graph.identify` falls back to
    // synthetic record paths instead of `Type:id` keys.
    let serialized = op.serialize().to_string();
    let mut pieces = vec![inject_typename(&strip_connection_directive(&serialized), true)];
    // Attach every referenced fragment definition used (transitively).
    let referenced = collect_referenced_fragments(op, exec_doc);
    for frag_name in referenced {
        if let Some(frag) = exec_doc.fragments.get(&frag_name) {
            let s = frag.serialize().to_string();
            pieces.push(inject_typename(&strip_connection_directive(&s), false));
        }
    }
    pieces.join("\n\n")
}

fn collect_referenced_fragments(op: &Operation, exec_doc: &ExecutableDocument) -> Vec<Name> {
    let mut out = Vec::new();
    let mut stack = vec![&op.selection_set];
    while let Some(ss) = stack.pop() {
        for sel in &ss.selections {
            match sel {
                Selection::Field(f) => stack.push(&f.selection_set),
                Selection::InlineFragment(i) => stack.push(&i.selection_set),
                Selection::FragmentSpread(s) => {
                    if !out.contains(&s.fragment_name) { out.push(s.fragment_name.clone()); }
                    if let Some(frag) = exec_doc.fragments.get(&s.fragment_name) {
                        stack.push(&frag.selection_set);
                    }
                }
            }
        }
    }
    out
}

/// Inject `__typename` into every selection set that opens with `{`,
/// mirroring Swift `Typename.injectNested` / `injectRecursive`.
///
/// `skip_first_brace = true` for **operation** definitions (`query`/
/// `mutation`/`subscription`) — Swift's `injectNested` does not add
/// `__typename` to the root selection set because root types' typename
/// is fixed (`"Query"`/`"Mutation"`/`"Subscription"`).
/// `skip_first_brace = false` for **fragment** definitions — Swift's
/// `injectRecursive` injects `__typename` into the top-level selection
/// set as well as every nested one (fragments are spread anywhere, so
/// the typename of the spread context matters).
///
/// Selection-set braces are distinguished from argument-literal braces
/// by tracking parenthesis depth: any `{` reached while
/// `paren_depth == 0` opens a selection set; braces inside `(...)` are
/// argument input objects and are left alone.
///
/// Idempotent — if the immediate selection set already opens with
/// `__typename` (textual lookup), no injection happens.
fn inject_typename(src: &str, skip_first_brace: bool) -> String {
    let bytes = src.as_bytes();
    let mut out = Vec::with_capacity(bytes.len() + 32);
    let mut paren_depth: i32 = 0;
    let mut brace_count: usize = 0;
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if paren_depth > 0 {
            // Inside argument literal — pass through, only adjust paren
            // depth on `(` / `)`. Braces here are input-object literals.
            if b == b'(' { paren_depth += 1; }
            else if b == b')' { paren_depth -= 1; }
            out.push(b);
            i += 1;
            continue;
        }
        if b == b'(' {
            paren_depth += 1;
            out.push(b);
            i += 1;
            continue;
        }
        if b == b'{' {
            out.push(b);
            i += 1;
            brace_count += 1;
            // Decide whether to inject. Operations skip brace #1 (the
            // operation body); fragments inject at every brace.
            let should_inject = !(skip_first_brace && brace_count == 1);
            if should_inject {
                // Peek ahead to see if the first non-whitespace token in
                // this selection set is already `__typename` — if so,
                // skip to keep idempotency.
                let mut j = i;
                while j < bytes.len() && (bytes[j] == b' ' || bytes[j] == b'\t' || bytes[j] == b'\n' || bytes[j] == b'\r') {
                    j += 1;
                }
                let already = bytes[j..].starts_with(b"__typename");
                if !already {
                    // Insert a leading newline + indent, then the field,
                    // then a trailing space so the next character spaces
                    // away from `__typename`.
                    out.extend_from_slice(b"\n  __typename ");
                }
            }
            continue;
        }
        out.push(b);
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| src.to_string())
}

fn strip_connection_directive(src: &str) -> String {
    // Cheap textual strip; the directive name is unique in executable docs.
    // Replace " @connection(...)" with "" using a small state machine for
    // balanced parens.
    let bytes = src.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i..].starts_with(b"@connection") {
            // consume @connection
            i += "@connection".len();
            // optional whitespace
            while i < bytes.len() && (bytes[i] == b' ' || bytes[i] == b'\t') { i += 1; }
            // optional (...)
            if i < bytes.len() && bytes[i] == b'(' {
                let mut depth = 1i32;
                i += 1;
                while i < bytes.len() && depth > 0 {
                    match bytes[i] {
                        b'(' => depth += 1,
                        b')' => depth -= 1,
                        _ => {}
                    }
                    i += 1;
                }
            }
            // collapse any trailing space that was preceded by nothing.
            while out.last() == Some(&b' ') { out.pop(); }
            out.push(b' ');
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| src.to_string())
}
