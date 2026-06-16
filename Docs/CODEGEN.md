# Codegen — `cachebay-cli`

Cachebay-iOS generates typed Swift code at build time from your GraphQL schema + operation files. The runtime never parses GraphQL — every operation it sees is a pre-baked `CachePlan` literal.

```
cachebay-cli codegen \
  --schema   path/to/schema.graphql \
  --operations path/to/queries/ \
  --output   Sources/App/Generated/
```

## What it generates

For each operation file (`MyQuery.graphql`):

```swift
public struct MyQuery: Cachebay.Operation {
    public struct Variables: Cachebay.OperationVariables {
        public var id: String
        public init(id: String) { self.id = id }
        public var __cachebay: [String: JSONValue] { /* ... */ }
    }

    public struct Data: Cachebay.OperationData {
        public var __data: [String: JSONValue]
        public var post: Post? { get { … } set { … } }     // get/set round-trips through __data
        public struct Post: Cachebay.OperationData {
            public var id: String
            public var title: String
            public var author: Author? { get { … } set { … } }
            public struct Author: Cachebay.OperationData { /* … */ }
        }
    }

    public static let operationName: String = "MyQuery"
    public static let networkQuery: String = "query MyQuery($id: ID!) { ... }"
    public static let cachePlan: CachePlan = CachePlan.make(...)   // pre-baked
    public static let document: QueryDocument = .plan(cachePlan)
}
```

Fragments emit the same shape but conform to `Cachebay.Fragment` instead of `Cachebay.Operation`, plus two extra statics:

- `fragmentName` — disambiguates when a source string ships multiple fragment definitions.
- `onTypename` — the GraphQL type the fragment is declared on (`fragment X on Y { … }` → `"Y"`). Typed APIs (`readFragment<F>`, `b.patch(fragment:id:)`, `b.connection.unlinkNode(fragment:id:)`) build the canonical cache key from this + the bare entity id.

Connection mutations go through `modifyOptimistic { b.connection(...).linkNode/unlinkNode/patch }` — there are no codegen-emitted helpers on `Data.Posts`. See [OPTIMISTIC_UPDATES.md](./OPTIMISTIC_UPDATES.md).

Plus, in shared files:

- `Inputs.graphql.swift` — typed structs for every `input` referenced by your operations (with `__cachebay: JSONValue` bridges).
- `Enums.graphql.swift` — typed `enum X: String, Sendable, CaseIterable` for every `enum` used.

## Build & install

```sh
cd cli
cargo build --release
# binary at: cli/target/release/cachebay-cli
```

Pre-built binaries are not currently distributed — build from source. The Rust toolchain is the only prerequisite (`brew install rust` or [rustup.rs](https://rustup.rs)).

## Project integration

The simplest setup is a `Makefile` invoked manually or via Xcode build phase:

```makefile
CLI := ../../cli/target/release/cachebay-cli
SCHEMA := ../server/schema.graphql
OPS := MyApp/GraphQL
OUT := MyApp/Generated

gen:
	@mkdir -p $(OUT)
	$(CLI) codegen --schema $(SCHEMA) --operations $(OPS) --output $(OUT)
```

Run `make gen` whenever you add/modify a `.graphql` file. Add `MyApp/Generated/*.swift` to your Xcode target and check it into git.

## File layout

```
MyApp/
├── GraphQL/
│   ├── ListPosts.graphql
│   ├── PostDetail.graphql
│   └── CreatePost.graphql
└── Generated/
    ├── Enums.graphql.swift
    ├── Inputs.graphql.swift
    ├── ListPosts.graphql.swift
    ├── PostDetail.graphql.swift
    └── CreatePost.graphql.swift
```

## Schema

A standard GraphQL SDL file. Cachebay's `@connection` directive is auto-injected — you don't need to declare it. Example minimum:

```graphql
type Query {
  post(id: ID!): Post
  posts(first: Int, after: String, filter: PostFilter): PostConnection!
}

type Post {
  id: ID!
  title: String!
  author: User
}

type PostConnection {
  edges: [PostEdge!]!
  pageInfo: PageInfo!
  totalCount: Int!
}

type PostEdge { cursor: String!  node: Post! }
type PageInfo { hasNextPage: Boolean!  endCursor: String }

input PostFilter { query: String  sort: PostSort }
enum PostSort { NAME_ASC  CREATE_DATE_DESC }
```

## Operations

One operation (or fragment) per `.graphql` file. Use `@connection` for paginated lists:

```graphql
query ListPosts($first: Int, $after: String, $filter: PostFilter) {
  posts(first: $first, after: $after, filter: $filter)
    @connection(mode: "infinite", filters: ["filter"]) {
    totalCount
    edges { cursor node { id title } }
    pageInfo { hasNextPage endCursor }
  }
}

fragment PostFields on Post { id title author { id name } }
```

apollo-compiler validates against the schema with full diagnostics — typos, missing fields, type mismatches, unused fragments are all reported with line/column.

## Using generated code

The runtime ships typed overloads for every cache operation — pass `Op.self` (or `Fragment.self`) and a typed `Variables` struct, get back a typed `Data` shape directly. Callers don't touch `JSONValue` for the hot path.

```swift
// 1) Execute — typed Variables in, typed result out.
let result = try await client.executeQuery(
    query: ListPosts.self,
    variables: .init(first: 20, filter: PostFilter(query: nil, sort: .createDateDesc)),
    cachePolicy: .cacheAndNetwork
)
for edge in result.data?.posts?.edges ?? [] {
    print(edge.node.title)
}
```

In a watcher:

```swift
let handle = try client.watchQuery(
    query: ListPosts.self,
    variables: .init(first: 20),
    immediate: true,
    onData: { data in
        // `data` is typed `ListPosts.Data` — no JSON unwrap.
    }
)
```

Read sync against the cache:

```swift
let cached = client.readQuery(query: ListPosts.self, variables: .init(first: 20))
let post = client.readFragment(fragment: PostFields.self, id: 42, variables: .init())
```

Mutations — both entity patches and connection inserts/removes — go through `modifyOptimistic`, which gives you the layered commit/revert flow:

```swift
let tx = client.modifyOptimistic { b in
    // Typed entity patch.
    b.patch(fragment: PostFields.self, id: 42) { draft in
        draft.title = "renamed"
    }
    // Typed connection prepend (server-confirmed node):
    b.connection(ConnectionSelector(key: "posts"))
     .linkNode(node: newlyCreated, options: LinkNodeOptions(position: .start))
}
// Server response normalize already wrote the canonical state.
tx.dispose()   // or tx.revert() on failure
```

See [OPTIMISTIC_UPDATES.md](./OPTIMISTIC_UPDATES.md) for the full builder API.

Subscriptions yield typed events:

```swift
let stream = try client.executeSubscription(subscription: PostUpdated.self, variables: .init(id: "p1"))
for try await event in stream {
    if let post = event.data?.postUpdated { /* … */ }
}
```

## Currently supported

- Typed `Variables` with `__cachebay: [String: JSONValue]` bridge — `OperationVariables` conformance.
- Typed input objects (`input X` → `struct X: Sendable`) with their own `__cachebay`. `@oneOf` inputs encode only the supplied variant.
- Typed enums (`enum X` → `enum X: String, Sendable, CaseIterable`).
- Pre-baked `CachePlan` literals — runtime skips parse/lower entirely.
- Typed `Data` struct tree per operation/fragment, every selection struct conforming to `OperationData` (mutable `var __data`, `init(__data:)`).
- Every accessor emits `get`/`set` pairs so the typed `b.patch(fragment:id:_:)` closure-builder (and the `linkNode(fragment:options:_:)` form) can write through to `__data` — only fields the closure touches end up in the patch.
- Interface / union type-case downcasts: `... on Dog { … }` emits `asDog: AsDog?` accessors gated on `__typename`.
- `CachebaySchema.interfaces` — interface→implementers map for runtime polymorphism (pass to `CachebayOptions.interfaces`).
- Operation/fragment conformance: queries/mutations/subscriptions conform to `Cachebay.Operation`; fragments conform to `Cachebay.Fragment` (and expose `static let fragmentName` + `static let onTypename`).

## Diagnostics

Errors are reported by `apollo-compiler` with source locations:

```
HarryPotterDemo/GraphQL/ListSpells.graphql:3:24: Error: cannot query field `creatorr` on type `Spell`
   ╭─[ ListSpells.graphql:3:24 ]
 3 │   spell(id: $id) { id creatorr title }
   │                       ──┬─────
   │                         ╰── unknown field
```

## Why a separate Rust binary?

The codegen is a build-time tool. Apple's iOS apps don't need the parser at runtime; every operation is pre-baked here. By keeping the codegen out-of-process:

- The Swift runtime stays small (no GraphQL parser bundled).
- We get `apollo-compiler`'s spec-compliant validation + great diagnostics for free.
- No xcframework — the CLI is a regular Mac binary, distributed via Homebrew/Releases like `swiftgen` or `swiftlint`.

## SwiftPM plugin — `swift package cachebay-codegen`

You don't have to install `cachebay-cli` by hand. It ships as a prebuilt
`binaryTarget` artifact bundle driven by the **`CachebayCodegen` command
plugin** (the SwiftLint / Mozilla `rust-components` pattern), so consumers run
codegen with zero install:

```sh
swift package --allow-writing-to-package-directory cachebay-codegen \
  --schema path/to/schema.graphql \
  --operations path/to/GraphQL \
  --output path/to/Generated \
  [--namespace API] [--config path/to/cachebay.config.json]
```

SwiftPM downloads the notarized CLI that matches the package version (Xcode:
right-click → **cachebay-codegen**). Because the binary is pinned in
`Package.swift`, the CLI and runtime can never drift.

The mode is chosen by the `CACHEBAY_CLI` env var — `off` (default: plugin
absent, `swift build`/`test` untouched), `local` (use a locally-built
`Artifacts/cachebay-cli.artifactbundle` via `scripts/build-cli-bundle.sh`), or
`release` (download from the GitHub Release). During CLI development set
`CACHEBAY_CLI_PATH=cli/target/release/cachebay-cli` to skip the bundle entirely.

The full two-case workflow + the release-pipeline runbook (GitHub Action,
signing/notarization, the checksum chicken-and-egg) live in
**[TOOLCHAIN.md](./TOOLCHAIN.md)**.

## Next steps

- [SETUP.md](./SETUP.md) — wire transports + identity + storage.
- [OPERATIONS.md](./OPERATIONS.md) — execute APIs.
- [RELAY_CONNECTIONS.md](./RELAY_CONNECTIONS.md) — `@connection` directive specifics.
