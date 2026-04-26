//! GraphQL introspection → SDL.
//!
//! `apollo-ios-cli` was the previous source of `schema.graphqls` for the
//! Ferment Cuts iOS app. Its SDL output didn't preserve `@oneOf`, so the
//! downstream codegen couldn't tell oneOf-input types from regular ones
//! and emitted `null` for the absent variants — which the server rejected.
//!
//! This subcommand replaces that pipeline: fetch the introspection JSON,
//! walk every `__Schema.types` node, emit the SDL we need (preserving
//! `@oneOf`, preserving the directive declarations the codegen reads,
//! preserving description docstrings). Re-introspecting always carries
//! `@oneOf` through to the SDL on disk, so the codegen's
//! `InputObjectType.directives` check stays accurate.
//!
//! The emitted SDL is a strict subset of GraphQL spec — enough to round
//! through `apollo-compiler` (the validator the codegen already uses)
//! and far short of a general-purpose printer. We only emit what the
//! Cachebay codegen consumes: object/interface/input/enum/scalar/union
//! type definitions plus directive declarations.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use serde::Deserialize;

const INTROSPECTION_QUERY: &str = r#"
query IntrospectionQuery {
  __schema {
    queryType { name }
    mutationType { name }
    subscriptionType { name }
    types { ...FullType }
    directives {
      name
      description
      isRepeatable
      locations
      args { ...InputValue }
    }
  }
}
fragment FullType on __Type {
  kind
  name
  description
  isOneOf
  fields(includeDeprecated: true) {
    name
    description
    args { ...InputValue }
    type { ...TypeRef }
    isDeprecated
    deprecationReason
  }
  inputFields { ...InputValue }
  interfaces { ...TypeRef }
  enumValues(includeDeprecated: true) {
    name
    description
    isDeprecated
    deprecationReason
  }
  possibleTypes { ...TypeRef }
}
fragment InputValue on __InputValue {
  name
  description
  type { ...TypeRef }
  defaultValue
}
fragment TypeRef on __Type {
  kind
  name
  ofType {
    kind
    name
    ofType {
      kind
      name
      ofType {
        kind
        name
        ofType {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
              ofType { kind name }
            }
          }
        }
      }
    }
  }
}
"#;

#[derive(Debug, Deserialize)]
struct IntrospectionResponse {
    data: Option<DataRoot>,
    errors: Option<Vec<serde_json::Value>>,
}

#[derive(Debug, Deserialize)]
struct DataRoot {
    #[serde(rename = "__schema")]
    schema: SchemaIntro,
}

#[derive(Debug, Deserialize)]
struct SchemaIntro {
    #[serde(rename = "queryType")]
    query_type: Option<NameRef>,
    #[serde(rename = "mutationType")]
    mutation_type: Option<NameRef>,
    #[serde(rename = "subscriptionType")]
    subscription_type: Option<NameRef>,
    types: Vec<TypeIntro>,
    directives: Vec<DirectiveIntro>,
}

#[derive(Debug, Deserialize)]
struct NameRef {
    name: String,
}

#[derive(Debug, Deserialize, Clone)]
struct TypeIntro {
    kind: String,
    name: Option<String>,
    description: Option<String>,
    #[serde(rename = "isOneOf")]
    is_one_of: Option<bool>,
    fields: Option<Vec<FieldIntro>>,
    #[serde(rename = "inputFields")]
    input_fields: Option<Vec<InputValueIntro>>,
    interfaces: Option<Vec<TypeRefIntro>>,
    #[serde(rename = "enumValues")]
    enum_values: Option<Vec<EnumValueIntro>>,
    #[serde(rename = "possibleTypes")]
    possible_types: Option<Vec<TypeRefIntro>>,
}

#[derive(Debug, Deserialize, Clone)]
struct FieldIntro {
    name: String,
    description: Option<String>,
    args: Vec<InputValueIntro>,
    #[serde(rename = "type")]
    field_type: TypeRefIntro,
    #[serde(rename = "isDeprecated")]
    is_deprecated: bool,
    #[serde(rename = "deprecationReason")]
    deprecation_reason: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
struct InputValueIntro {
    name: String,
    description: Option<String>,
    #[serde(rename = "type")]
    value_type: TypeRefIntro,
    #[serde(rename = "defaultValue")]
    default_value: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
struct TypeRefIntro {
    kind: String,
    name: Option<String>,
    #[serde(rename = "ofType")]
    of_type: Option<Box<TypeRefIntro>>,
}

#[derive(Debug, Deserialize, Clone)]
struct EnumValueIntro {
    name: String,
    description: Option<String>,
    #[serde(rename = "isDeprecated")]
    is_deprecated: bool,
    #[serde(rename = "deprecationReason")]
    deprecation_reason: Option<String>,
}

#[derive(Debug, Deserialize, Clone)]
struct DirectiveIntro {
    name: String,
    description: Option<String>,
    #[serde(rename = "isRepeatable", default)]
    is_repeatable: bool,
    locations: Vec<String>,
    args: Vec<InputValueIntro>,
}

/// Fetch introspection JSON from `endpoint`, render to SDL, write to `output`.
/// `auth_header` is forwarded verbatim as the `Authorization` header when
/// non-empty (some staging environments require a bearer token to even
/// run introspection).
pub fn run(endpoint: &str, output: &Path, auth_header: Option<&str>) -> anyhow::Result<()> {
    let body = serde_json::json!({ "query": INTROSPECTION_QUERY });

    let mut request = ureq::post(endpoint).set("Content-Type", "application/json");
    if let Some(token) = auth_header {
        request = request.set("Authorization", token);
    }
    let response = request
        .send_json(body)
        .map_err(|e| anyhow::anyhow!("introspection request to {endpoint} failed: {e}"))?;
    let intro: IntrospectionResponse = response
        .into_json()
        .map_err(|e| anyhow::anyhow!("decoding introspection response: {e}"))?;

    if let Some(errors) = intro.errors {
        if !errors.is_empty() {
            anyhow::bail!(
                "introspection returned GraphQL errors: {}",
                serde_json::to_string_pretty(&errors).unwrap_or_default()
            );
        }
    }
    let data = intro
        .data
        .ok_or_else(|| anyhow::anyhow!("introspection response had no `data` field"))?;
    let sdl = render_sdl(&data.schema);

    if let Some(parent) = output.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(output, sdl)?;
    println!(
        "cachebay-cli: introspected {} → {}",
        endpoint,
        output.display()
    );
    Ok(())
}

// MARK: - SDL printer
//
// The output is alphabetised by type name within each kind, kinds in a
// stable order (scalars, enums, interfaces, unions, inputs, objects, then
// schema/directive declarations). This keeps `git diff` of regenerated
// schemas readable — minor field reorderings on the server don't churn
// the SDL on disk.

fn render_sdl(schema: &SchemaIntro) -> String {
    let mut out = String::new();

    // Custom directives the codegen / app rely on. Built-in directives
    // (`include`/`skip`/`deprecated`/`specifiedBy`) are emitted by the
    // server; we filter the obvious ones out only when the schema would
    // otherwise re-introduce duplicates.
    let mut directives: Vec<&DirectiveIntro> = schema
        .directives
        .iter()
        .filter(|d| !is_builtin_directive(&d.name))
        .collect();
    directives.sort_by(|a, b| a.name.cmp(&b.name));
    for d in directives {
        out.push_str(&render_directive_definition(d));
        out.push('\n');
    }

    // Group types by kind so the file order matches the previous
    // apollo-ios-cli output (scalars/enums first, then interfaces,
    // unions, inputs, objects). Anonymous (`__`-prefixed) types are
    // introspection metadata — leave them out of the dump.
    let mut by_kind: BTreeMap<&str, Vec<&TypeIntro>> = BTreeMap::new();
    for t in &schema.types {
        if t
            .name
            .as_deref()
            .map(|n| n.starts_with("__"))
            .unwrap_or(true)
        {
            continue;
        }
        by_kind.entry(t.kind.as_str()).or_default().push(t);
    }
    for ts in by_kind.values_mut() {
        ts.sort_by(|a, b| a.name.cmp(&b.name));
    }

    let kind_order: &[&str] = &[
        "SCALAR",
        "ENUM",
        "INTERFACE",
        "UNION",
        "INPUT_OBJECT",
        "OBJECT",
    ];
    for kind in kind_order {
        if let Some(types) = by_kind.get(*kind) {
            for t in types {
                if let Some(rendered) = render_type(t) {
                    out.push_str(&rendered);
                    out.push('\n');
                }
            }
        }
    }

    // Schema block — only emitted when the operation root names diverge
    // from the GraphQL defaults. Apollo's SDL output omits this when
    // they match, and downstream tooling tolerates either form.
    let needs_schema_block = schema
        .query_type
        .as_ref()
        .map(|n| n.name != "Query")
        .unwrap_or(false)
        || schema
            .mutation_type
            .as_ref()
            .map(|n| n.name != "Mutation")
            .unwrap_or(false)
        || schema
            .subscription_type
            .as_ref()
            .map(|n| n.name != "Subscription")
            .unwrap_or(false);
    if needs_schema_block {
        out.push_str("schema {\n");
        if let Some(q) = &schema.query_type {
            out.push_str(&format!("  query: {}\n", q.name));
        }
        if let Some(m) = &schema.mutation_type {
            out.push_str(&format!("  mutation: {}\n", m.name));
        }
        if let Some(s) = &schema.subscription_type {
            out.push_str(&format!("  subscription: {}\n", s.name));
        }
        out.push_str("}\n");
    }
    out
}

fn is_builtin_directive(name: &str) -> bool {
    matches!(
        name,
        "include" | "skip" | "deprecated" | "specifiedBy" | "defer" | "stream"
    )
}

fn render_directive_definition(d: &DirectiveIntro) -> String {
    let mut s = String::new();
    if let Some(desc) = &d.description {
        s.push_str(&render_description(desc, ""));
    }
    s.push_str(&format!("directive @{}", d.name));
    if !d.args.is_empty() {
        s.push_str("(\n");
        for arg in &d.args {
            if let Some(desc) = &arg.description {
                s.push_str(&render_description(desc, "  "));
            }
            s.push_str(&format!(
                "  {}: {}",
                arg.name,
                render_type_ref(&arg.value_type)
            ));
            if let Some(def) = &arg.default_value {
                s.push_str(&format!(" = {}", def));
            }
            s.push('\n');
        }
        s.push(')');
    }
    if d.is_repeatable {
        s.push_str(" repeatable");
    }
    s.push_str(&format!(" on {}", d.locations.join(" | ")));
    s.push('\n');
    s
}

fn render_type(t: &TypeIntro) -> Option<String> {
    let name = t.name.as_deref()?;
    let mut s = String::new();
    if let Some(desc) = &t.description {
        s.push_str(&render_description(desc, ""));
    }
    match t.kind.as_str() {
        "SCALAR" => {
            // Skip GraphQL built-ins; they don't appear in user SDL.
            if matches!(name, "String" | "Int" | "Float" | "Boolean" | "ID") {
                return None;
            }
            s.push_str(&format!("scalar {}\n", name));
        }
        "ENUM" => {
            s.push_str(&format!("enum {} {{\n", name));
            if let Some(values) = &t.enum_values {
                for v in values {
                    if let Some(desc) = &v.description {
                        s.push_str(&render_description(desc, "  "));
                    }
                    s.push_str(&format!("  {}", v.name));
                    if v.is_deprecated {
                        s.push_str(&render_deprecated(v.deprecation_reason.as_deref()));
                    }
                    s.push('\n');
                }
            }
            s.push_str("}\n");
        }
        "INTERFACE" => {
            s.push_str(&format!("interface {}", name));
            s.push_str(" {\n");
            render_fields(t.fields.as_deref().unwrap_or(&[]), &mut s);
            s.push_str("}\n");
        }
        "UNION" => {
            s.push_str(&format!("union {}", name));
            if let Some(possible) = &t.possible_types {
                let names: Vec<String> = possible
                    .iter()
                    .filter_map(|p| p.name.clone())
                    .collect();
                if !names.is_empty() {
                    s.push_str(" = ");
                    s.push_str(&names.join(" | "));
                }
            }
            s.push('\n');
        }
        "INPUT_OBJECT" => {
            s.push_str(&format!("input {}", name));
            // The whole point of this binary: preserve `@oneOf`.
            if t.is_one_of.unwrap_or(false) {
                s.push_str(" @oneOf");
            }
            s.push_str(" {\n");
            if let Some(inputs) = &t.input_fields {
                for f in inputs {
                    if let Some(desc) = &f.description {
                        s.push_str(&render_description(desc, "  "));
                    }
                    s.push_str(&format!("  {}: {}", f.name, render_type_ref(&f.value_type)));
                    if let Some(def) = &f.default_value {
                        s.push_str(&format!(" = {}", def));
                    }
                    s.push('\n');
                }
            }
            s.push_str("}\n");
        }
        "OBJECT" => {
            s.push_str(&format!("type {}", name));
            if let Some(interfaces) = &t.interfaces {
                let names: Vec<String> = interfaces
                    .iter()
                    .filter_map(|i| i.name.clone())
                    .collect();
                if !names.is_empty() {
                    s.push_str(" implements ");
                    s.push_str(&names.join(" & "));
                }
            }
            s.push_str(" {\n");
            render_fields(t.fields.as_deref().unwrap_or(&[]), &mut s);
            s.push_str("}\n");
        }
        _ => return None,
    }
    Some(s)
}

fn render_fields(fields: &[FieldIntro], out: &mut String) {
    for f in fields {
        if let Some(desc) = &f.description {
            out.push_str(&render_description(desc, "  "));
        }
        out.push_str(&format!("  {}", f.name));
        if !f.args.is_empty() {
            out.push('(');
            let parts: Vec<String> = f
                .args
                .iter()
                .map(|a| {
                    let mut p = format!("{}: {}", a.name, render_type_ref(&a.value_type));
                    if let Some(def) = &a.default_value {
                        p.push_str(&format!(" = {}", def));
                    }
                    p
                })
                .collect();
            out.push_str(&parts.join(", "));
            out.push(')');
        }
        out.push_str(&format!(": {}", render_type_ref(&f.field_type)));
        if f.is_deprecated {
            out.push_str(&render_deprecated(f.deprecation_reason.as_deref()));
        }
        out.push('\n');
    }
}

fn render_type_ref(t: &TypeRefIntro) -> String {
    match t.kind.as_str() {
        "NON_NULL" => format!(
            "{}!",
            t.of_type
                .as_ref()
                .map(|i| render_type_ref(i))
                .unwrap_or_default()
        ),
        "LIST" => format!(
            "[{}]",
            t.of_type
                .as_ref()
                .map(|i| render_type_ref(i))
                .unwrap_or_default()
        ),
        _ => t.name.clone().unwrap_or_default(),
    }
}

fn render_description(desc: &str, indent: &str) -> String {
    if desc.contains('\n') {
        format!("{indent}\"\"\"\n{}\n{indent}\"\"\"\n", desc)
    } else {
        let escaped = desc.replace('\\', "\\\\").replace('"', "\\\"");
        format!("{indent}\"{}\"\n", escaped)
    }
}

fn render_deprecated(reason: Option<&str>) -> String {
    match reason {
        Some(r) => format!(" @deprecated(reason: \"{}\")", r.replace('"', "\\\"")),
        None => " @deprecated".to_string(),
    }
}
