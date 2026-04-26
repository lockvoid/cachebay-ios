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
                swift_type: swift_type_for_shape(&shape),
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
        network_query: frag.serialize().to_string(),
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
                    out.extend(lowered.into_iter().map(|mut f| {
                        f.type_condition = Some(frag.type_condition().to_string());
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
                    f.type_condition = Some(type_cond.clone());
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

    let children = if f.selection_set.selections.is_empty() {
        Vec::new()
    } else {
        let nested_parent = f.ty().inner_named_type().to_string();
        lower_selection_set(&f.selection_set, &nested_parent, ctx, exec_doc)
    };

    let output_shape = shape_for_type(&f.ty(), !children.is_empty());
    let named_type = f.ty().inner_named_type().to_string();

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
    }
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
    let mut nullable = true;
    let mut list = false;
    let mut cursor = ty.clone();
    loop {
        cursor = match cursor {
            Type::NonNullNamed(inner) => { nullable = false; Type::Named(inner) }
            Type::NonNullList(inner) => { nullable = false; Type::List(inner) }
            Type::List(inner) => { list = true; *inner }
            Type::Named(_) => break,
        };
    }
    if has_children { OutputShape::Object { nullable, list } } else { OutputShape::Leaf { nullable, list } }
}

/// Map a resolved `TypeShape` to a Swift type string, honouring
/// nullability and list wrapping and using the generated struct name for
/// user-defined input objects / enums.
pub fn swift_type_for_shape(shape: &TypeShape) -> String {
    use crate::schema::TypeKind;
    // Always qualify `JSONValue` with the `Cachebay.` module prefix so that
    // host apps which also import other GraphQL clients (Apollo's
    // `JSONValue` is a frequent collision during migration) get an
    // unambiguous type lookup.
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
    let inner = if shape.list {
        if shape.inner_nullable { format!("[{base}?]") } else { format!("[{base}]") }
    } else {
        base
    };
    if shape.nullable { format!("{inner}?") } else { inner }
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
    // Strategy (matches Swift `buildNetworkQuery`): serialize the operation +
    // required named fragments with `@connection` removed. apollo-compiler's
    // `serialize()` gives us a byte-identical round trip, so we post-process.
    let serialized = op.serialize().to_string();
    let mut pieces = vec![strip_connection_directive(&serialized)];
    // Attach every referenced fragment definition used (transitively).
    let referenced = collect_referenced_fragments(op, exec_doc);
    for frag_name in referenced {
        if let Some(frag) = exec_doc.fragments.get(&frag_name) {
            let s = frag.serialize().to_string();
            pieces.push(strip_connection_directive(&s));
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
