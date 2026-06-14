//! Walk the validated schema to collect the transitive closure of input
//! object types referenced by any operation's variables. Emitted as a
//! shared `Inputs.graphql.swift` file.

use std::collections::BTreeMap;

use apollo_compiler::ast::Type;
use apollo_compiler::executable::{Selection, SelectionSet};
use apollo_compiler::schema::ExtendedType;
use apollo_compiler::Schema;

use crate::load::CompilerContext;
use apollo_compiler::ExecutableDocument;

#[derive(Debug, Clone)]
pub struct EnumTypeDef {
    pub name: String,
    pub values: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct InputTypeDef {
    pub name: String,
    pub fields: Vec<InputField>,
    /// `true` when the schema declares this input as `@oneOf`. Exactly
    /// one field must be provided to the server, and the others MUST be
    /// omitted (the server rejects `null` siblings — see `@oneOf` spec).
    /// The emitter encodes these inputs by branching on the present
    /// field instead of writing every key.
    pub is_one_of: bool,
}

#[derive(Debug, Clone)]
pub struct InputField {
    pub name: String,
    pub graphql_type: String,
    pub shape: TypeShape,
    /// `true` when `cachebay.config.json`'s `explicitNullable` lists
    /// `"<InputType>.<field>"` — this field's `null` ≠ absent on the server, so
    /// it emits the tri-state `GraphQLNullable<T>` rather than omit-on-nil.
    /// `@oneOf` members ignore this (explicit null is invalid there).
    pub explicit_nullable: bool,
}

#[derive(Debug, Clone)]
pub struct TypeShape {
    /// Unwrapped named type (e.g. "String", "SpellFilter", "Int").
    pub named: String,
    /// Kind of the named type.
    pub kind: TypeKind,
    /// Outer nullable flag — the top-level type accepts null?
    pub nullable: bool,
    /// Outer list flag — is the top-level a list?
    pub list: bool,
    /// Inner nullable — if list, are individual items nullable?
    pub inner_nullable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TypeKind {
    /// GraphQL built-in scalars: String, Int, Float, Boolean, ID
    Scalar,
    /// User-defined scalar (emitted as JSONValue).
    CustomScalar,
    /// GraphQL enum (emitted as Swift String for now; real enum codegen later).
    Enum,
    /// GraphQL input object (typed struct generated alongside).
    InputObject,
}

/// Collect every enum type generated code needs. Two sources:
///   * **Inputs** — operation variables, transitively chasing input-object
///     fields (`input X { color: Color }`).
///   * **Outputs** — every field selected in an operation/fragment whose named
///     type is an enum (`{ video { intent } }`). Without this, an output-only
///     enum (never used as an input) is never emitted, so typing an output
///     field as it would reference a nonexistent Swift symbol.
pub fn collect_referenced_enums(ctx: &CompilerContext) -> BTreeMap<String, EnumTypeDef> {
    let mut queue: Vec<String> = Vec::new();
    let schema: &Schema = &ctx.schema;

    // Seed from every operation variable (input side).
    for op in ctx.document.operations.iter() {
        for v in op.variables.iter() {
            queue.push(v.ty.inner_named_type().to_string());
        }
    }

    // Seed from every output selection set (output side). Fragment definitions
    // are walked independently, so a spread doesn't need to be chased inline.
    for op in ctx.document.operations.iter() {
        collect_enums_from_selection_set(&op.selection_set, &mut queue);
    }
    for (_, frag) in ctx.document.fragments.iter() {
        collect_enums_from_selection_set(&frag.selection_set, &mut queue);
    }

    let mut out: BTreeMap<String, EnumTypeDef> = BTreeMap::new();
    let mut visited: std::collections::BTreeSet<String> = Default::default();

    while let Some(name) = queue.pop() {
        if !visited.insert(name.clone()) { continue; }
        match schema.types.get(name.as_str()) {
            Some(ExtendedType::Enum(e)) => {
                let values = e.values.iter().map(|(n, _)| n.to_string()).collect();
                out.insert(name.clone(), EnumTypeDef { name, values });
            }
            Some(ExtendedType::InputObject(input)) => {
                // Walk into input object fields so enums reachable through
                // `input X { color: Color }` are discovered too.
                for (_, f) in input.fields.iter() {
                    queue.push(f.ty.inner_named_type().to_string());
                }
            }
            _ => {}
        }
    }
    out
}

/// Push every field's named type from an output selection set onto `queue` (the
/// main loop keeps the ones that resolve to enums) and recurse into nested
/// selections + inline fragments. Fragment *spreads* are skipped here — the
/// caller walks every fragment definition's own selection set, so chasing the
/// spread inline would only double-visit.
fn collect_enums_from_selection_set(sel: &SelectionSet, queue: &mut Vec<String>) {
    for selection in sel.selections.iter() {
        match selection {
            Selection::Field(f) => {
                queue.push(f.ty().inner_named_type().to_string());
                collect_enums_from_selection_set(&f.selection_set, queue);
            }
            Selection::InlineFragment(inline) => {
                collect_enums_from_selection_set(&inline.selection_set, queue);
            }
            Selection::FragmentSpread(_) => {}
        }
    }
}

/// Walk every `type X implements Y` in the schema to build the
/// `interface name → [implementer typename]` map the runtime needs to
/// resolve interface-typed selection sets against concrete records.
/// Without this map, `CachebayClient`'s `selectionApplies` rejects
/// every interface-level field during normalisation and the cache
/// loses `id`/`track`/etc. on polymorphic records.
///
/// Unions are intentionally excluded: their members behave the same
/// runtime-wise but the schema models the relation differently and
/// the codegen doesn't currently emit field-level selection sets
/// against unions.
pub fn collect_interface_implementations(ctx: &CompilerContext) -> BTreeMap<String, Vec<String>> {
    let mut out: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (typename, ty) in ctx.schema.types.iter() {
        if let ExtendedType::Object(obj) = ty {
            for iface in obj.implements_interfaces.iter() {
                out.entry(iface.to_string())
                    .or_default()
                    .push(typename.to_string());
            }
        }
    }
    for impls in out.values_mut() {
        impls.sort();
    }
    out
}

pub fn collect_referenced_input_types(ctx: &CompilerContext) -> BTreeMap<String, InputTypeDef> {
    let mut queue: Vec<String> = Vec::new();
    collect_input_types_from_doc(&ctx.document, &mut queue);
    let mut out: BTreeMap<String, InputTypeDef> = BTreeMap::new();
    let schema: &Schema = &ctx.schema;
    while let Some(name) = queue.pop() {
        if out.contains_key(&name) { continue; }
        if let Some(ExtendedType::InputObject(input)) = schema.types.get(name.as_str()) {
            let mut fields = Vec::with_capacity(input.fields.len());
            for (fname, f) in input.fields.iter() {
                let shape = shape_of(schema, &f.ty);
                if shape.kind == TypeKind::InputObject {
                    queue.push(shape.named.clone());
                }
                let explicit_nullable = ctx
                    .explicit_nullable
                    .contains(&format!("{name}.{fname}"));
                fields.push(InputField {
                    name: fname.to_string(),
                    graphql_type: f.ty.to_string(),
                    shape,
                    explicit_nullable,
                });
            }
            let is_one_of = input.directives.iter().any(|d| d.name.as_str() == "oneOf");
            out.insert(name.clone(), InputTypeDef { name, fields, is_one_of });
        }
    }
    out
}

fn collect_input_types_from_doc(doc: &ExecutableDocument, out: &mut Vec<String>) {
    for op in doc.operations.iter() {
        for v in op.variables.iter() {
            collect_input_types_from_type(&v.ty, out);
        }
    }
}

fn collect_input_types_from_type(ty: &Type, out: &mut Vec<String>) {
    // Only the named type matters; wrapping List/NonNull doesn't change identity.
    let named = ty.inner_named_type();
    // We don't know here whether it's an input object — the caller checks via schema.
    // So we just push every named type; the main loop filters.
    out.push(named.to_string());
}

pub fn shape_of(schema: &Schema, ty: &Type) -> TypeShape {
    // Walk the wrapping to determine nullability + list flag.
    let mut nullable = true;
    let mut list = false;
    let mut inner_nullable = true;
    let mut cursor = ty.clone();
    // Walk only the *outermost* wrapping. Once we identify the list/non-null
    // shell, the inner type's own NonNull/List wrapping is already captured
    // in `inner_nullable` — continuing to step deeper would let an inner
    // `NonNullNamed` overwrite `nullable`, flipping a nullable list of
    // non-null items into a non-null list. The bug surfaced on
    // `[UpsertClipInput!]`: the outer list is nullable but `nullable` was
    // ending up false because the inner `!` got read as outer non-null.
    loop {
        cursor = match cursor {
            Type::NonNullNamed(inner) => { nullable = false; Type::Named(inner) }
            Type::NonNullList(inner) => {
                nullable = false; list = true;
                let peeked = *inner.clone();
                inner_nullable = match peeked { Type::NonNullNamed(_) | Type::NonNullList(_) => false, _ => true };
                break;
            }
            Type::List(inner) => {
                list = true;
                let peeked = *inner.clone();
                inner_nullable = match peeked { Type::NonNullNamed(_) | Type::NonNullList(_) => false, _ => true };
                break;
            }
            Type::Named(_) => break,
        };
    }
    let named = ty.inner_named_type().to_string();
    let kind = kind_for_named(schema, &named);
    TypeShape { named, kind, nullable, list, inner_nullable }
}

fn kind_for_named(schema: &Schema, name: &str) -> TypeKind {
    match name {
        "String" | "Int" | "Float" | "Boolean" | "ID" => TypeKind::Scalar,
        _ => match schema.types.get(name) {
            Some(ExtendedType::Enum(_)) => TypeKind::Enum,
            Some(ExtendedType::InputObject(_)) => TypeKind::InputObject,
            Some(ExtendedType::Scalar(_)) => TypeKind::CustomScalar,
            _ => TypeKind::Scalar,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::load::CompilerContext;
    use apollo_compiler::{ast, Schema};

    fn ctx_from(schema_src: &str, op_src: &str) -> CompilerContext {
        let schema =
            Schema::parse_and_validate(schema_src, "schema.graphql").expect("schema should validate");
        let document = ast::Document::parse(op_src, "op.graphql")
            .expect("op should parse")
            .to_executable_validate(&schema)
            .expect("op should validate");
        let scalar_types = crate::plan::collect_sdl_scalar_types(&schema);
        CompilerContext {
            schema,
            document,
            file_paths: Default::default(),
            diagnostics: Vec::new(),
            scalar_types,
            explicit_nullable: Default::default(),
        }
    }

    // VideoIntent / WidgetKind are output-only (never an input). ProjectOrderBy
    // is input-only (reached via `$filter: Filter`). The bug: the registry
    // seeded only from variables + input objects, so the two output-only enums
    // were never generated — and any field typed as them would reference a
    // nonexistent Swift symbol.
    const SCHEMA: &str = r#"
        type Query { video(filter: Filter): Video }
        type Video { id: ID! intent: VideoIntent! widget: Widget }
        type Widget { id: ID! kind: WidgetKind! }
        enum VideoIntent { ROLL STORY VIBE }
        enum WidgetKind { CHAT GALLERY }
        enum ProjectOrderBy { NAME DATE }
        input Filter { order: ProjectOrderBy }
    "#;

    const OP: &str = r#"
        query Q($filter: Filter) {
          video(filter: $filter) {
            id
            intent
            ...WidgetBits
          }
        }
        fragment WidgetBits on Video {
          widget { id kind }
        }
    "#;

    #[test]
    fn collects_output_enum_directly_selected() {
        let enums = collect_referenced_enums(&ctx_from(SCHEMA, OP));
        assert!(
            enums.contains_key("VideoIntent"),
            "output enum field `intent: VideoIntent!` must be collected; got {:?}",
            enums.keys().collect::<Vec<_>>()
        );
    }

    #[test]
    fn collects_output_enum_reached_through_fragment() {
        let enums = collect_referenced_enums(&ctx_from(SCHEMA, OP));
        assert!(
            enums.contains_key("WidgetKind"),
            "output enum reached via fragment spread (`widget.kind`) must be collected; got {:?}",
            enums.keys().collect::<Vec<_>>()
        );
    }

    #[test]
    fn still_collects_input_enum_via_variable() {
        // Regression guard: the existing input-side path must keep working.
        let enums = collect_referenced_enums(&ctx_from(SCHEMA, OP));
        assert!(
            enums.contains_key("ProjectOrderBy"),
            "input enum via $filter: Filter{{ order: ProjectOrderBy }} must still be collected; got {:?}",
            enums.keys().collect::<Vec<_>>()
        );
    }
}
