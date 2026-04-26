# cachebay-cli

GraphQL codegen for the [Cachebay](../) Swift runtime.

Built in Rust on top of [`apollo-compiler`](https://crates.io/crates/apollo-compiler) for spec-compliant parsing, validation, and diagnostics.

## Build

```sh
cargo build --release
```

Binary lands in `target/release/cachebay-cli`.

## Usage

```sh
cachebay-cli codegen \
  --schema path/to/schema.graphql \
  --operations path/to/queries/ \
  --output Sources/App/Generated/
```

Inputs:
- `--schema` — SDL file defining types the operations reference.
- `--operations` — one or more files or directories (recursively scanned for `*.graphql` / `*.gql`).
- `--output` — output directory for generated Swift files (one file per operation/fragment).
- `--module` — optional namespace name (reserved, unused in MVP emitter).

## What it emits

Per operation:
- Typed `Variables` struct with a `__cachebay: [String: JSONValue]` bridge.
- Typed `Data` struct tree with nested `Sendable` structs and property accessors.
- Pre-stripped `networkQuery` string (with `@connection` directives removed).
- A `QueryDocument` the runtime can execute directly.

Currently supported:
- Typed `Variables` with a `__cachebay: [String: JSONValue]` bridge.
- Typed input objects (`input X` → `struct X: Sendable`) with their own `__cachebay` bridge.
- Typed enums (`enum X` → `enum X: String, Sendable, CaseIterable`).
- Pre-baked `CachePlan` Swift literal — runtime skips parse/lower entirely.
- Typed `Data` struct tree per operation + fragment.
- Interface / union type-case downcasts — `... on Dog { … }` emits `asDog: AsDog?`
  accessors gated on `__typename`.

## Why Rust

The Swift runtime has zero GraphQL-parser dependencies — every operation it sees is already validated and lowered by this CLI at build time. Running the parser in Rust gives us apollo-compiler's diagnostics for free; shipping a CLI binary (not a linked library) means no xcframework, no FFI, no runtime cost on the app side.
