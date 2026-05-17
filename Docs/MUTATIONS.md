# Mutations

**Writing data** with Cachebay.

- Core API: `executeMutation`
- Optimistic helper: `modifyOptimistic`

---

## `executeMutation`

Sends a write to the server and merges the result into the cache.

```swift
let result = try await client.executeMutation(
    mutation: CreatePost.self,
    variables: .init(input: .init(title: "Hello", category: "General"))
)
print(result.data?.createPost?.post?.id ?? "—")
```

The JSON-shaped overload (`query: String`, `variables: [String: JSONValue]`) is also available; see [OPERATIONS.md#executemutation](./OPERATIONS.md#executemutation).

Notes:

- Partial responses are still written — useful fields are kept even when `error` is non-nil.
- Watchers update automatically via dependency tracking on entities the mutation merges into.
- The mutation result is also normalised under a synthetic `@mutation.N` rootId so re-reading from there gives back a clean per-call snapshot.

---

## Optimistic at a glance

For instant UI feedback before the network responds, wrap the mutation in `modifyOptimistic`:

```swift
let tx = client.modifyOptimistic { b in
    b.patch(fragment: PostFields.self, id: "p1") { d in
        d.title = "Draft…"
    }
}

do {
    let result = try await client.executeMutation(
        mutation: UpdatePost.self,
        variables: .init(input: .init(id: "p1", title: "Real Title"))
    )
    if result.error != nil { tx.revert(); throw … }
    tx.dispose()                                        // server normalize wrote canonical state
} catch {
    tx.revert()                                         // roll back
    throw error
}
```

Three lifecycle methods, pick the right one:

- **`tx.dispose()`** — server response is authoritative for touched records (~80% of update mutations). `executeMutation`'s normalize already wrote the canonical state; the optimistic ops can be discarded without restoring baseline.
- **`tx.commit { b in … }`** — your commit-time ops differ from the optimistic ones, typically for temp-id swaps. The commit closure captures typed server data from outer scope (no `ctx.data` plumbing).
- **`tx.revert()`** — the mutation failed.

Full layering + lifecycle reference: [OPTIMISTIC_UPDATES.md](./OPTIMISTIC_UPDATES.md).

---

## Pattern: create — single-phase

You don't have an authoritative id until the server responds, so there's no temp/optimistic state to project. Await the mutation, then write the result through the builder API in a single pass:

```swift
let result = try await client.executeMutation(
    mutation: CreatePost.self,
    variables: .init(input: .init(title: title))
)
if let err = result.error { throw … }
guard let created = result.data?.createPost else { throw … }

client.modifyOptimistic(autoCommit: true) { b in
    for key in client.inspect.getConnectionKeys(parent: .root, key: "posts") {
        b.connection(key: key).linkNode(node: created, fragment: PostFields.self,
                                        options: LinkNodeOptions(position: .start))
    }
}
```

`autoCommit: true` skips the `.optimistic` phase and runs the closure once at `.commit`, applying ops directly to base graph (no layer recorded, no double-write).

`linkNode(node:fragment:options:)` is **plan-aware**: it walks the fragment plan to (a) initialize nested `@connection` canonicals, (b) stamp `__typename` from `F.onTypename`, (c) strip selection-set fields from the entity-record patch so existing ref/refList links survive a merge.

`getConnectionKeys` finds every canonical that matches `parent + key + filters`, so a single mutation can fan out across multiple visible lists (e.g. an "All posts" + a "My posts" feed).

---

## Pattern: optimistic remove

```swift
let tx = client.modifyOptimistic { b in
    for key in client.inspect.getConnectionKeys(parent: .root, key: "posts") {
        b.connection(key: key).unlinkNode(fragment: PostFields.self, id: id)
    }
}

do {
    _ = try await client.executeMutation(
        mutation: DeletePost.self,
        variables: .init(input: .init(id: id))
    )
    tx.dispose()  // optimistic unlinkNode is the desired final state
} catch {
    tx.revert()
}
```

After dispose, you may also `b.delete(fragment: PostFields.self, id: id)` to drop the entity itself so any other watcher reading it falls into a `nil` state.

---

## Pattern: optimistic patch

Merge known fields immediately; the server response normalizes into the cache via `executeMutation`. After success, `dispose()` drops the layer cleanly without reverting server-side updates.

```swift
let tx = client.modifyOptimistic { b in
    b.patch(fragment: PostFields.self, id: input.id) { d in
        if let v = input.title { d.title = v }
        d.updatedAt = Date().iso8601String
    }
}

do {
    let result = try await client.executeMutation(
        mutation: UpdatePost.self,
        variables: .init(input: input)
    )
    if result.error != nil { tx.revert(); throw … }
    tx.dispose()  // server normalize already wrote canonical Post:id
} catch {
    tx.revert()
    throw error
}
```

`mode: .merge` (default) keeps existing fields; `mode: .replace` writes exactly what's in the patch and drops everything else from the record.

---

## Next steps

- [Subscriptions](./SUBSCRIPTIONS.md) — streaming live updates.
- [Optimistic Updates](./OPTIMISTIC_UPDATES.md) — full builder API + layering.
- [Relay Connections](./RELAY_CONNECTIONS.md) — `linkNode` / `unlinkNode` / `patch` against canonicals.
