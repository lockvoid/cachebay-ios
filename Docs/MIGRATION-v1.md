# Migrating to Cachebay v1.0 (typed structs)

v1.0 replaces the `[String: JSONValue]` dict-wrapper generated types with **real Swift
structs and sum-type enums**, produced by macros. Reads become direct field loads,
value-diffing is the synthesized `Equatable`, and polymorphic types switch exhaustively.

This is a **breaking** change for codegen consumers. The v0.15.x line keeps shipping.

## Requirements

- **iOS 18+** / macOS 15 / tvOS 18 / watchOS 11 / visionOS 2.
- **Swift 6.2 / Xcode 26** (the macro plugin uses `swift-syntax` 602).

## What changed at a glance

| Area | v0.x (dict wrapper) | v1.0 (typed) |
|---|---|---|
| Concrete type | `struct Data { let __data: [String: JSONValue]; var x: T { __data["x"]... } }` | `@CachebayData struct …: CachebayValue { let x: T }` |
| Interface | `var asVideoElement: AsVideoElement?` views | `@CachebayInterface enum …` with `.unknown(Shared)` (§3.1) |
| Operation | `: Operation`, `Data: OperationData` | `: CachebayOperation`, `Data: CachebayValue` |
| Read | lazy per-access (~15–60 ns) | eager at materialize, then ~1 ns reads |
| Mutation | `b.patch(.key("Post:1"), ["title": .string("x")], mode: .merge)` | `b.patch(fragment: PostFields.self, id: "1") { $0.set(\.title, "x") }` |
| Client read | `client.readQuery(query:variables:)` | `client.read(_:variables:)` / `watch` / `execute` |

The cache (`[String: JSONValue]`, normalized, optimistic layers, type reducers, SQLite) is
**unchanged** — only the boundary at `materialize` and the generated type shape change.

## 1. Regenerate

```sh
cachebay-cli codegen --schema schema.graphql --operations ./GraphQL --output ./Generated
```

On the 1.x line the CLI emits the typed v1.0 shapes — there is no dict-wrapper option
(use the 0.x CLI/branch if you need the old shape). Generated files now
`import Foundation`, `import Cachebay`, `import CachebayMacros`.

## 2. Mechanical search-replaces (per call site)

```swift
// Optional chaining stays, but the result is the real value, not a dict view:
data.posts?.first?.title ?? ""        →  data.posts?.first?.title ?? ""   // (type is String? now)

// Interface downcasts → exhaustive switch:
if let v = element.asVideoElement { … }   →   if case .video(let v) = element { … }

// …or a full switch (compiler-enforced exhaustiveness):
switch element {
case .video(let v):   renderVideo(v.url, duration: v.duration)
case .audio(let a):   renderAudio(a.waveformURL)
case .image(let i):   renderImage(i.thumbnailURL)
case .unknown(let s): renderPlaceholder(id: s.id)   // §3.1 — carries interface-level fields
}

// Typed reads / watches / executes:
client.readQuery(query: GetCook.self, variables: v)   →   client.read(GetCook.self, variables: v)
client.watchQuery(query: …) { data in … }             →   client.watch(GetCook.self, variables: v) { data in … }

// KeyPath patch builder (fragment top-level fields only):
b.patch(.key("Post:1"), ["title": .string("x")], mode: .merge)
  →  b.patch(fragment: PostFields.self, id: "1") { $0.set(\.title, "x") }
```

Patch a **nested** entity by targeting its own fragment + id — deep paths (`\.author.name`)
are intentionally unsupported (the cache is entity-keyed).

## 3. Delete shadow model types

`AnyElement`, manual `into()` converters, and hand-written draft helpers are now the
generated types. Local construction uses the public memberwise init:

```swift
let draft = Element.video(.init(id: "temp_\(UUID().uuidString)", name: "Take 1"))
//   __typename + @CachebayDefault fields + optionals all defaulted.
```

## 4. Local-draft defaults — `@CachebayDefault`

Wire data has no defaults, so drafts need per-field defaults (§6). Add them via the schema
directive `field: String! @cachebay(default: "a0")` (or the codegen config) so the generator
emits `@CachebayDefault("a0") let rank: String`. One-time, per type.

> Construction-only (decision D6): a `@CachebayDefault` does **not** soften decode — a record
> missing a required field is still a miss (§7). Use `field: T?` for genuinely-optional wire data.

## 5. Failure semantics (§7) — usually a no-op for you

Eager decode means a missing/malformed **required** field is a whole-record miss — surfaced
through the **existing** `strictOK = false` path (cache-only → `nil`, cache-and-network →
refetch). Identical to today's miss behaviour. Optional fields decode missing/malformed → `nil`.

## 6. ⚠️ Audit fragments for over-selection (read this)

v1.0 does **not** change watcher churn from over-selecting fragments — that discipline is
unchanged. The shape of the consumer-facing type is orthogonal to *what you select*. If a
screen re-renders too often after migrating, the cause is almost certainly a fragment that
selects fields it doesn't need — a pre-existing issue v1.0 merely makes more visible. Do not
blame v1.0 for churn that was already there; audit the selection set.

## 7. Escape hatch

`@_spi(Cachebay) init?(_dataDict:)` / `__dataDict()` expose the raw `[String: JSONValue]` for
debug tooling or an opposite (wide-but-narrow-read) workload. Gate with
`@_spi(Cachebay) import Cachebay`.

## Codegen options (typed mode)

```sh
cachebay-cli codegen --schema schema.graphql --operations ./GraphQL --output ./Generated \
  --namespace API
```

- **`--namespace API`** — wrap models in `extension API { … }` (→ `API.GetCook`) so they don't
  collide with `Image`/`Video`/`Color`/etc. Empty (default) = top level. **Recommended on.**
- **`@cachebay(default: …)`** schema directive → `@CachebayDefault(…)` (construction defaults, §6).
- **`scalar Date @cachebay(swiftType: "Foundation.Date")`** → maps the custom scalar's fields to
  that Swift type (must conform to `CachebayValue`; Cachebay ships `URL`/`Date`). Unconfigured custom
  scalars stay `Cachebay.JSONValue` (raw passthrough). Declare the directive once in your schema:
  `directive @cachebay(default: CachebayDefaultValue, swiftType: String) on FIELD_DEFINITION | SCALAR`.

## Internal migration checklist (this repo)

- [x] Macros, typed runtime path (`read`/`watch`/`execute`), KeyPath patch builder.
- [x] CLI emits typed by default (no flag); dict-wrapper emitter removed (1.x is typed-only).
- [x] CLI typed emission: structs + sum-type enums + envelope + `--namespace` +
  `@CachebayDefault` from schema + custom-scalar config. Validated: regen compiles + decodes
  (`Tests/CachebayMacrosTests/GeneratedSmoke/`).
- [x] `@CachebayQuery` SwiftUI wrapper (`CachebayUI` target).
- [x] Demo app migrated to the typed API (drops the `SpellRow`/`SpellData` shadow structs;
  segmented Declarative|Imperative list). `xcodebuild` BUILD SUCCEEDED; app launches + renders
  on the iOS 18 simulator (`@CachebayQuery` lifecycle validated).
- [ ] Migrate internal test fixtures that assert via `__data` to the typed shape (the untyped
  runtime tests are unaffected — they exercise `JSONValue` directly). *Optional cleanup.*
