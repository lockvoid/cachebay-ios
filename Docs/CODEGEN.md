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
public struct MyQuery: Sendable {
    public struct Variables: Sendable {
        public var id: String
        public init(id: String) { self.id = id }
        public var __cachebay: [String: JSONValue] { /* ... */ }
    }

    public struct Data: Sendable {
        public let __data: [String: JSONValue]
        public var post: Post? { /* typed accessor */ }
        public struct Post: Sendable {
            public var id: String
            public var title: String
            public var author: Author?
            public struct Author: Sendable { /* … */ }
        }
    }

    public static let operationName: String = "MyQuery"
    public static let networkQuery: String = "query MyQuery($id: ID!) { ... }"
    public static let cachePlan: CachePlan = CachePlan.make(...)   // pre-baked
    public static let document: QueryDocument = .plan(cachePlan)
}
```

Plus, in shared files:

- `Inputs.graphql.swift` — typed structs for every `input` referenced by your operations (with `__cachebay: JSONValue` bridges).
- `Enums.graphql.swift` — typed `enum X: String, Sendable, CaseIterable` for every `enum` used.

## Build & install

```sh
cd cli
cargo build --release
# binary at: cli/target/release/cachebay-cli
```

Pre-built binaries: GitHub Releases (planned).

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

```swift
// 1) Construct typed Variables.
let vars = ListPosts.Variables(
    first: 20,
    after: nil,
    filter: PostFilter(query: nil, sort: .createDateDesc)
)

// 2) Hand off to the runtime via the pre-baked plan.
let result = try await client.executeQuery(
    query: ListPosts.networkQuery,
    variables: vars.__cachebay,
    cachePolicy: .cacheAndNetwork
)

// 3) Decode typed Data.
if let data = result.data {
    let typed = ListPosts.Data(__data: data.object ?? [:])
    for edge in typed.posts?.edges ?? [] {
        print(edge.node.title)
    }
}
```

In a watcher:

```swift
let handle = try client.watchQuery(
    query: ListPosts.networkQuery,
    options: WatchQueryOptions(
        variables: vars.__cachebay,
        immediate: true,
        onData: { json in
            let typed = ListPosts.Data(__data: json.object ?? [:])
            // ... update UI
        }
    )
)
```

## Currently supported

- Typed `Variables` with `__cachebay: [String: JSONValue]` bridge.
- Typed input objects (`input X` → `struct X: Sendable`) with their own `__cachebay`.
- Typed enums (`enum X` → `enum X: String, Sendable, CaseIterable`).
- Pre-baked `CachePlan` literals — runtime skips parse/lower entirely.
- Typed `Data` struct tree per operation + standalone fragment.
- Interface / union type-case downcasts: `... on Dog { … }` emits `asDog: AsDog?` accessors gated on `__typename`.

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

## Next steps

- [SETUP.md](./SETUP.md) — wire transports + identity + storage.
- [OPERATIONS.md](./OPERATIONS.md) — execute APIs.
- [RELAY_CONNECTIONS.md](./RELAY_CONNECTIONS.md) — `@connection` directive specifics.
