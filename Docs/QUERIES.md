# Queries

**Reading data** with Cachebay.

- High-level: `executeQuery` (respects policies, hits the network).
- Low-level: `readQuery` / `writeQuery` / `watchQuery`.

Each one ships in **typed** and **JSON-shaped** flavours — typed is recommended; the JSON shape is the underlying primitive.

> Cache mutations go through `modifyOptimistic` (entity patches via `b.patch(fragment:id:_:)`, connection mutations via `b.connection.linkNode(...)` / `unlinkNode`). See [OPTIMISTIC_UPDATES.md](./OPTIMISTIC_UPDATES.md). `writeQuery` here is for non-layered seeding (test fixtures, SSR restore) — it bypasses the commit/revert machinery.

---

## `executeQuery`

Full lifecycle: cache check → policy decision → network if needed → normalise → notify.

```swift
let result = try await client.executeQuery(
    query: GetPost.self,
    variables: .init(id: "p1"),
    cachePolicy: .cacheAndNetwork
)
print(result.data?.post?.title ?? "—")
result.meta?.source     // .cache | .network
```

JSON-shaped variant accepts `query: String` + `[String: JSONValue]`. See [OPERATIONS.md](./OPERATIONS.md#executequery) for the full signature.

A **sync overload** with the same `onCacheData` / `onNetworkData` / `onError` callbacks is also available — same surface, no `async throws`, returns a `CachebayToken` for cancellation:

```swift
client.executeQuery(
    query: GetPost.self,
    variables: .init(id: "p1"),
    cachePolicy: .cacheAndNetwork,
    onCacheData: { data, willFetch in /* render cache hit */ },
    onNetworkData: { data in /* render network response */ },
    onError: { err in /* … */ }
)
```

Use the sync form from view actions and other sync contexts where wrapping in `Task { await … }` would defer same-tick work. See [OPERATIONS.md#sync-overloads](./OPERATIONS.md#sync-overloads).

---

## Low-level helpers

For manual cache control without going through the network.

### `readQuery`

Materialise from cache only.

```swift
let data = client.readQuery(query: GetPost.self, variables: .init(id: "p1"))
print(data?.post?.title ?? "—")
```

Returns `nil` on a cache miss (no exception).

### `writeQuery`

Write typed data into the cache using a query shape — same normalisation path as a network response.

```swift
try client.writeQuery(
    query: GetPost.self,
    variables: .init(id: "p1"),
    data: GetPost.Data(__data: [
        "post": .object([
            "__typename": .string("Post"),
            "id": .string("p1"),
            "title": .string("Hello"),
        ])
    ])
)
```

Watchers and fragments tracking `Post:p1` fire automatically on the next graph flush.

### `watchQuery`

Watch a query and re-emit when dependent records change. The typed overload hands `onData` a typed `Op.Data` directly:

```swift
let handle = try client.watchQuery(
    query: GetPost.self,
    variables: .init(id: "p1"),
    immediate: true,
    onData: { data in
        // `data` is typed `GetPost.Data` — no JSON unwrap.
    },
    onError: { err in
        // network error or partial-data misery
    }
)

// Later — change the variables (re-runs through the cache, no extra fetch):
handle.update(["id": .string("p2")], true)

// On scope exit:
handle.unsubscribe()
```

Behaviour:

- Tracks dependencies via the materialiser's record-touch set + the plan's coarse dependency hints (so writes to a record the watcher hasn't yet seen still trigger).
- Re-materialises on `onChange`, recycles unchanged subtrees by fingerprint (`recycleSnapshots`), emits only when the data actually differs.
- Mutations and subscriptions feed watchers directly via signature, bypassing the dep-flush — emissions stay coalesced.

See [SETUP.md#concurrency-model](./SETUP.md#concurrency-model) for how watchers are invoked safely off the lock.

---

## Pagination & variable changes

For Relay-style `@connection` queries, change `variables` (e.g. `after: endCursor`) and pass the same query — cachebay uses the canonical key (filters minus pagination) to merge new pages into the existing canonical list.

```swift
// Initial load.
_ = try await client.executeQuery(
    query: ListPosts.self,
    variables: .init(first: 20),
    cachePolicy: .cacheAndNetwork
)

// Load more.
_ = try await client.executeQuery(
    query: ListPosts.self,
    variables: .init(first: 20, after: "cursor-20")
)
```

Watchers don't need to re-subscribe — they observe the canonical, which grows on every new page.

Deep dive: [RELAY_CONNECTIONS.md](./RELAY_CONNECTIONS.md).

---

## Conditional fields with `@include` and `@skip`

GraphQL's two spec-mandated field directives ([§3.13.1–2](https://spec.graphql.org/October2021/#sec--skip)) work the way you'd expect: the directive is sent to the server **and** evaluated by the cache. A field excluded by `@include(if: false)` or `@skip(if: true)` is treated as not-in-selection — no cache miss, no spurious refetch.

```graphql
query GetCook($id: ID!, $withProject: Boolean!) {
  cook(id: $id) {
    id
    title
    project @include(if: $withProject) { id name }
  }
}
```

Call with `withProject: true` and the project comes through. Call with `withProject: false` and:

- The wire payload omits `project` (the server obeys the directive).
- Normalize doesn't write `project` (Cachebay drops it defensively if it appears).
- A subsequent read with `withProject: false` is a **cache hit** with `project` absent from the result — same record, different shape, no network call.
- A subsequent read with `withProject: true` on the same cook is a cache miss (the project genuinely isn't there) and triggers a network fetch.

### Conflict rule

When both directives apply to the same field, `@skip` wins — the field is excluded if either votes for exclusion:

```graphql
project @skip(if: $hide) @include(if: $show) { id name }
```

| `$hide` | `$show` | Result |
|---|---|---|
| `true` | `true` | excluded (`@skip` wins) |
| `true` | `false` | excluded |
| `false` | `true` | included |
| `false` | `false` | excluded (`@include(false)`) |

### Literal Boolean arguments

Both `@include(if: $var)` and `@include(if: false)` are supported. The literal form is rare but spec-allowed; useful for codegen-driven scenarios.

### What this lets you do

The pattern works well for "lazy" sub-selections — e.g. a list query that pulls a cheap row shape by default and asks for an expensive nested object only for the entry the user opened:

```graphql
query Cooks($id: ID!, $withProject: Boolean!) {
  cooks {
    edges {
      node {
        id title
        project @include(if: $withProject) { id name posterUrl }
      }
    }
  }
}
```

The list query (`withProject: false`) lands every cook without the project payload. The detail query (`withProject: true`) for one specific cook lands its project. Both share the same generated `Data` type and same plan; the cache distinguishes them by signature, the underlying entity records are unified.

---

## SwiftUI integration

Cachebay doesn't ship a SwiftUI wrapper, but the demo app shows the canonical pattern:

```swift
struct PostsList: View {
    @State private var rows: [PostRow] = []
    @State private var watcher: WatchQueryHandle? = nil

    var body: some View {
        List(rows) { row in PostRowView(row: row) }
            .task {
                watcher = try? client.watchQuery(
                    query: ListPosts.self,
                    variables: .init(),
                    immediate: true,
                    onData: { data in
                        Task { @MainActor in
                            rows = parse(data)
                        }
                    }
                )
                _ = try? await client.executeQuery(query: ListPosts.self, variables: .init())
            }
            .onDisappear { watcher?.unsubscribe() }
    }
}
```

Always hop to `@MainActor` before mutating SwiftUI `@State`. The watcher's `onData` is invoked off the cache lock but on whatever thread fired the change.

---

## Next steps

- [Fragments](./FRAGMENTS.md) — typed reads on individual entities.
- [Relay Connections](./RELAY_CONNECTIONS.md) — pagination + dedup.
- [Mutations](./MUTATIONS.md) — writes + optimistic.
