# Queries

**Reading data** with Cachebay.

- High-level: `executeQuery` (respects policies, hits the network).
- Low-level: `readQuery` / `writeQuery` / `watchQuery`.

---

## `executeQuery`

Full lifecycle: cache check → policy decision → network if needed → normalise → notify.

```swift
let result = try await client.executeQuery(
    query: GetPost.networkQuery,
    variables: ["id": "p1"],
    cachePolicy: .cacheAndNetwork
)

if let data = result.data {
    let typed = GetPost.Data(__data: data.object ?? [:])
    print(typed.post?.title ?? "—")
}

result.meta?.source     // .cache | .network
```

See [OPERATIONS.md](./OPERATIONS.md#executequery) for the full signature.

---

## Low-level helpers

For manual cache control without going through the network.

### `readQuery`

Materialise from cache only.

```swift
let json = client.readQuery(query: GetPost.networkQuery, variables: ["id": "p1"])
if let typed = json.map({ GetPost.Data(__data: $0.object ?? [:]) }) {
    print(typed.post?.title ?? "—")
}
```

Returns `nil` on a cache miss (no exception).

### `writeQuery`

Write raw data into the cache using a query shape — the same path as a network response.

```swift
try client.writeQuery(
    query: GetPost.networkQuery,
    variables: ["id": "p1"],
    data: .object([
        "post": .object([
            "__typename": "Post", "id": "p1", "title": "Hello"
        ])
    ])
)
```

Watchers and fragments tracking `Post:p1` fire automatically on the next graph flush.

### `watchQuery`

Watch a query and re-emit when dependent records change.

```swift
let handle = try client.watchQuery(
    query: GetPost.networkQuery,
    options: WatchQueryOptions(
        variables: ["id": "p1"],
        immediate: true,    // emit current cache value if present
        onData: { json in
            let typed = GetPost.Data(__data: json.object ?? [:])
            // ... update UI on main thread
        },
        onError: { err in
            // network error or partial-data misery
        }
    )
)

// Later — change the variables (re-runs through the cache, no extra fetch):
handle.update(["id": "p2"], true)

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
    query: ListPosts.networkQuery,
    variables: ["first": 20, "after": .null, "filter": .null],
    cachePolicy: .cacheAndNetwork
)

// Load more.
_ = try await client.executeQuery(
    query: ListPosts.networkQuery,
    variables: ["first": 20, "after": "cursor-20", "filter": .null]
)
```

Watchers don't need to re-subscribe — they observe the canonical, which grows on every new page.

Deep dive: [RELAY_CONNECTIONS.md](./RELAY_CONNECTIONS.md).

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
                    query: ListPosts.networkQuery,
                    options: WatchQueryOptions(
                        immediate: true,
                        onData: { data in
                            Task { @MainActor in
                                rows = parse(data)
                            }
                        }
                    )
                )
                _ = try? await client.executeQuery(query: ListPosts.networkQuery)
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
