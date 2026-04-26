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
