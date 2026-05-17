# Relay Connections

First-class cursor-based pagination via the `@connection` directive. Edge dedup, page merging, and a stable canonical record per `(parent + field + filters + key)`.

## `@connection`

```graphql
query Posts($category: String, $first: Int, $after: String) {
  posts(category: $category, first: $first, after: $after)
    @connection(mode: "infinite", filters: ["category"]) {
    pageInfo { startCursor endCursor hasNextPage hasPreviousPage }
    edges    { cursor node { id title } }
  }
}
```

Options:

| Arg       | Effect                                                                 |
| --------- | ---------------------------------------------------------------------- |
| `mode`    | `"infinite"` (append/prepend, default) or `"page"` (replace).          |
| `filters` | Argument names that define the connection's identity. Cursor args are excluded automatically. |
| `key`     | Optional explicit name when you want multiple views of the same field. |

Identity rule: `parent + field + filters (+ key)`. Cursor args (`first/last/after/before`) do **not** affect identity.

## Multiple views of the same field

```graphql
posts(category: $category, first: $first, after: $after)
  @connection(key: "feed",   mode: "infinite", filters: ["category"]) { ... }

posts(category: $category, first: $first, after: $after)
  @connection(key: "search", mode: "page",     filters: ["category"]) { ... }
```

Two distinct canonical records (`@connection.feed.posts(...)` + `@connection.search.posts(...)`); they don't collide.

## Merge modes

### `mode: "infinite"` (append/prepend)

- New edges append (or prepend) to the canonical list.
- Existing nodes by `__typename:id` are de-duplicated via the **node index**; their edge meta (cursor, score, etc.) is **refreshed in place** without reordering.
- `pageInfo` shallow-merges; boundary fields follow Relay rules — prepended pages update `startCursor` + `hasPreviousPage`, appended pages update `endCursor` + `hasNextPage`.
- Connection-level fields (e.g. `totalCount`) shallow-merge on the canonical record.

### `mode: "page"` (replace)

- The canonical's edge list is **replaced** by the latest page.
- `pageInfo` reflects that page; connection-level fields shallow-merge.
- Same canonical key → same record across page navigations, so watchers don't re-subscribe.

## Cache policies

Any policy works with either mode. Common combinations:

| UX                              | Policy             | Mode      |
| ------------------------------- | ------------------ | --------- |
| Infinite scroll                 | `cacheAndNetwork`  | `infinite`|
| Strict pagination               | `cacheFirst`       | `page`    |
| Pull-to-refresh                 | `networkOnly`      | either    |

---

## Recipes

### Infinite feed (append)

```swift
struct PostsList: View {
    @State private var endCursor: String? = nil
    @State private var rows: [PostRow] = []
    @State private var hasNext = true

    var body: some View {
        List(rows) { PostRowView(row: $0) }
            .task { await loadMore() }
            .refreshable { restart() }
    }

    private func restart() { rows = []; endCursor = nil; hasNext = true; Task { await loadMore() } }

    private func loadMore() async {
        guard hasNext else { return }
        let result = try? await client.executeQuery(
            query: ListPosts.networkQuery,
            variables: [
                "first": 20,
                "after": endCursor.map(JSONValue.string) ?? .null,
                "filter": .null
            ],
            cachePolicy: endCursor == nil ? .cacheAndNetwork : .networkOnly
        )
        if let posts = result?.data?["posts"]?.object {
            // Merge into rows, update endCursor + hasNext from pageInfo.
            ...
        }
    }
}
```

### Infinite feed (prepend / load previous)

Use `last` + `before` and the same `@connection` declaration. The canonical record handles append + prepend in one list.

### Strict paging (replace)

```graphql
posts(...) @connection(mode: "page", filters: ["category"]) { … }
```

Each new page replaces the visible window. The canonical key is identical across pages so the watcher feeds the UI continuously.

---

## Mutating connections

> **Two stores, two APIs.** Connection mutations manage the **structure** of a connection — the edge refs that link to entities, edge meta (cursor, score), and the canonical's pageInfo. They **never write to the entity store**. Entity records (`Post:p1`, `User:u1`, …) are owned exclusively by `documents.normalize` (auto from query / mutation / subscription responses) or by an explicit `b.writeFragment` / `b.patch`. See [OPTIMISTIC_UPDATES.md](./OPTIMISTIC_UPDATES.md) for the framing in detail.

The link primitive takes an `EntityRef` (identity), not a node dict (data) — the API surface itself enforces the contract: there is no scalar parameter that *could* leak onto the entity record.

```swift
let tx = client.modifyOptimistic { b in
    let c = b.connection(ConnectionSelector(key: "posts"))

    // Server-cycle case: the mutation's normalize already wrote the
    // entity record. Just link by typed node — Cachebay extracts
    // identity (__typename + id) and forwards an EntityRef.
    c.linkNode(node: created, options: LinkNodeOptions(position: .start))

    // Optimistic-create case: write the entity FIRST, then link.
    let tempId = UUID().uuidString
    b.writeFragment(fragment: PostFields.self, id: tempId, data: draft)
    c.linkNode(fragment: PostFields.self, id: tempId,
               options: LinkNodeOptions(position: .start))

    // Typed remove keyed by bare entity id.
    c.unlinkNode(fragment: PostFields.self, id: deletedId)
}
tx.dispose()              // server normalize already wrote canonical state
// or tx.commit(serverPayload) for temp-id swaps
// or tx.revert() on failure
```

Why this split kills a class of bugs by construction: a deferred handler that captures a stale payload and later replays it through `linkNode` cannot clobber later normalize state — there are no scalars to clobber with. Subscription pipelines auto-normalize each frame *before* the user's `for await` body runs, so by the time a deferred re-link executes, the entity may already hold newer state from a subsequent frame; the link primitive is structural-only and safe to retry.

---

## Inspecting connections

`client.inspect.getConnectionKeys(...)` lists every canonical key matching a parent/field selector. Useful for fanning out optimistic updates to all visible lists:

```swift
let keys = client.inspect.getConnectionKeys(parent: .root, key: "posts")
// [ "@connection.posts({})", "@connection.posts({\"category\":\"tech\"})", ... ]

client.modifyOptimistic { b in
    for key in keys {
        b.connection(key: key).linkNode(node, options: .init(position: .start))
    }
}
```

You can also pass a custom `argsFilter` predicate to narrow by raw arg JSON.

## Performance

- `linkNode` / `unlinkNode` are **O(1)** regardless of canonical size — `ConnectionIndex` (a `nodeKey → edgeKey` map per canonical) replaces what used to be linear scans.
- `pageInfo` updates touch a single record; canonical-level extras shallow-merge in place.
- See `Tests/CachebayTests/PerformanceTests.swift` for measured numbers (typical M-series Mac, release build):

  | Workload                      | Throughput        |
  | ----------------------------- | ----------------- |
  | linkNode + commit (empty)     | ~233k ops/s       |
  | linkNode @ preload=5 000      | ~12k ops/s (86 µs)|
  | p99 / p50 (preload=5k)        | < 5×              |

---

## Next steps

- [Optimistic Updates](./OPTIMISTIC_UPDATES.md) — `connection.linkNode` / `unlinkNode` / `patch`.
- [Mutations](./MUTATIONS.md) — server-driven connection updates + optimistic patterns.
- [Subscriptions](./SUBSCRIPTIONS.md) — live-prepend new items into an infinite list.
