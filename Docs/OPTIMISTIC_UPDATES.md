# Optimistic Updates

Cachebay's optimistic engine is **layered** and **reconstructive**. Each `modifyOptimistic` call opens a layer that applies immediately. You can `commit` the layer (drop it, optionally promoting with server data) or `revert` only that layer — cachebay restores the **committed baseline** for every record the layer touched, then **replays** the surviving layers in order. State stays correct and deterministic.

Works for **entities** and **Relay connections**. No edge-list churn; updates are O(1) on connection size via the node index.

---

## TL;DR

```swift
// Open a layer.
let tx = client.modifyOptimistic { b, ctx in
    // 1) Typed entity merge — only the touched field lands in the patch.
    b.patch(fragment: PostFields.self, id: "p1") { draft in
        draft.title = "Draft…"
    }

    // 2) Typed connection prepend — closure builds the optimistic node;
    //    `__typename` is seeded from PostFields.onTypename so the closure
    //    only sets domain fields.
    let c = b.connection(ConnectionSelector(key: "posts"))
    c.addNode(fragment: PostFields.self, options: AddNodeOptions(position: .start)) { draft in
        draft.id = ctx.data?["id"]?.string ?? "temp:1"
        draft.title = "Draft…"
    }

    // 3) Connection-level patch (JSON-shaped — no fragment surface
    //    needed for `pageInfo` / `totalCount`).
    c.patch([
        "pageInfo": .object(["hasNextPage": .bool(false)]),
        "totalCount": .int(42)
    ])
}

// Success — promote with server payload.
tx.commit(serverPayload)

// Failure — roll back this layer; siblings keep their effects.
tx.revert()
```

---

## Builder API

The runtime exposes both **typed** overloads (driven by codegen — preferred for everyday use) and **JSON-shaped** primitives (escape hatch for cases the typed shape can't express, like cross-variant interface patches).

### Typed (codegen-driven)

```swift
public extension OptimisticBuilder {
    // Entity patch via fragment + bare id. Only fields the closure
    // touches end up in the patch; setters write through to `__data`.
    func patch<F: Fragment, ID: LosslessStringConvertible>(
        fragment: F.Type,
        id: ID,
        mode: EntityPatchMode = .merge,
        _ build: (inout F.Data) -> Void
    )

    // Entity delete keyed by typed id.
    func delete<F: Fragment, ID: LosslessStringConvertible>(
        fragment: F.Type,
        id: ID
    )
}

public extension ConnectionAPI {
    // Typed node from a server response (or anywhere with a complete typed Data).
    func addNode<N: OperationData>(node: N, options: AddNodeOptions)

    // Typed closure-builder for optimistic nodes (no server data yet).
    // `__typename` is seeded from F.onTypename so callers only set domain fields.
    func addNode<F: Fragment>(
        fragment: F.Type,
        options: AddNodeOptions,
        _ build: (inout F.Data) -> Void
    )

    // Typed remove keyed by bare id.
    func removeNode<F: Fragment, ID: LosslessStringConvertible>(
        fragment: F.Type,
        id: ID
    )
}
```

### JSON-shaped (primitives)

```swift
public protocol OptimisticBuilder: AnyObject, Sendable {
    func patch(_ target: EntityRef, _ patch: [String: JSONValue], mode: EntityPatchMode)
    func delete(_ target: EntityRef)
    func connection(_ selector: ConnectionSelector) -> ConnectionAPI
    func connection(key canonicalKey: CacheKey) -> ConnectionAPI
}

public protocol ConnectionAPI: AnyObject, Sendable {
    var key: CacheKey { get }
    func addNode(_ node: [String: JSONValue], options: AddNodeOptions)
    func removeNode(_ ref: EntityRef)
    func patch(_ update: [String: JSONValue])
}
```

### `EntityRef` resolves

| Ref form                                         | Result                                              |
| ------------------------------------------------ | --------------------------------------------------- |
| `.key("Post:p1")`                                | direct                                              |
| `.object(["__typename": "Post", "id": "p1"])`    | identified via your `KeyFunction` / `id` fallback   |

### Builder context

Your builder closure receives `(builder, ctx)`. `ctx.phase` is `.optimistic` on the initial call and `.commit` when `commit(data:)` re-runs it.

```swift
let tx = client.modifyOptimistic { b, ctx in
    let id = ctx.data?["id"]?.string ?? "temp:1"
    b.patch(.key("Post:\(id)"), ["title": "X"], mode: .merge)
}
tx.commit(.object(["id": "real-id"]))
```

The `.commit` re-run lets you swap the temp id for the server-assigned one and rebuild the same effects against the real record.

---

## Entities

### `b.patch(target, patch, mode:)`

- `.merge` (default): shallow-merge fields into the existing snapshot. Setting a field to `.undefined` removes it.
- `.replace`: write exactly the provided fields, drop everything else.

```swift
b.patch(.key("Post:p1"), ["title": "Renaming…"], mode: .merge)
b.patch(.key("Post:p1"), ["__typename": "Post", "id": "p1", "title": "Fresh"], mode: .replace)
```

### `b.delete(target)`

```swift
b.delete(.key("Post:p1"))
```

Removes the record snapshot. Edges referencing it are not auto-removed — use `connection.removeNode` for that.

---

## Connections

### Get a handle

```swift
let c = b.connection(
    ConnectionSelector(
        parent: .root,                    // or .key("User:u1") / .object(user)
        key: "posts",
        filters: ["category": "tech"]
    )
)
// or by canonical key directly:
let c2 = b.connection(key: "@connection.posts({\"category\":\"tech\"})")
```

`b.connection(.init(parent:key:filters:))` builds the canonical key the same way the runtime does, so it matches whatever was populated by `executeQuery`.

### `c.addNode(node, options:)`

```swift
c.addNode(node, options: AddNodeOptions(
    position: .start,                  // .start | .end | .before | .after
    anchor: .key("Post:42"),           // required for .before / .after
    edge: ["cursor": "cur42"]          // edge-level metadata
))
```

- De-dup by entity key — re-adding refreshes edge meta in place without reordering.
- `.before` / `.after` with no anchor or a missing one: `.before` ⇒ start, `.after` ⇒ end.
- Inserts are O(1) regardless of connection size.

### `c.removeNode(ref)`

```swift
c.removeNode(.key("Post:p1"))
c.removeNode(.object(["__typename": "Post", "id": "p1"]))
```

Removes the first occurrence of that node. The underlying entity record is untouched.

### `c.patch(update)`

```swift
c.patch([
    "pageInfo": .object(["hasNextPage": .bool(false)]),
    "totalCount": .int(10)
])
```

Shallow-merges into the canonical record. If `pageInfo` is included, it's merged field-by-field on the linked PageInfo record.

---

## Helpers

`client.inspect.getConnectionKeys(...)` finds matching canonicals so a single mutation can fan out:

```swift
for key in client.inspect.getConnectionKeys(parent: .root, key: "posts") {
    b.connection(key: key).addNode(node, options: .init(position: .start))
}
```

Filter by parent (`.root`, `.entity("User:u1")`, `.entityObject(typename:id:)`), by field name, or by a raw-args predicate.

---

## Recipes

### Add (with fanout)

```swift
let tx = client.modifyOptimistic { b, ctx in
    let id = ctx.data?["id"]?.string ?? "temp:\(UUID().uuidString)"
    let node: [String: JSONValue] = [
        "__typename": "Post",
        "id": .string(id),
        "title": .string(input.title)
    ]
    for key in client.inspect.getConnectionKeys(parent: .root, key: "posts") {
        b.connection(key: key).addNode(node, options: AddNodeOptions(position: .start))
    }
}

do {
    let result = try await client.executeMutation(query: CreatePost.networkQuery, variables: ...)
    tx.commit(result.data?["createPost"]?["post"])
} catch {
    tx.revert()
}
```

### Delete

```swift
let tx = client.modifyOptimistic { b, _ in
    for key in client.inspect.getConnectionKeys(parent: .root, key: "posts") {
        b.connection(key: key).removeNode(.key("Post:\(id)"))
    }
}
do {
    _ = try await client.executeMutation(query: DeletePost.networkQuery, variables: ["input": .object(["id": .string(id)])])
    tx.commit(nil)
    // Optional: drop the entity from the graph too.
    let cleanup = client.modifyOptimistic { b, _ in b.delete(.key("Post:\(id)")) }
    cleanup.commit(nil)
} catch { tx.revert() }
```

### Patch (entity)

```swift
let tx = client.modifyOptimistic { b, ctx in
    let id = "Post:\(input.id)"
    if let server = ctx.data {
        b.patch(.key(id), server.object ?? [:], mode: .merge)
    } else {
        b.patch(.key(id), ["title": .string(input.title)], mode: .merge)
    }
}
do {
    let result = try await client.executeMutation(query: UpdatePost.networkQuery, variables: ...)
    tx.commit(result.data?["updatePost"]?["post"])
} catch { tx.revert() }
```

---

## Layering semantics

Layers apply in insertion order:

```
Base:                         [A]
L1: addNode B (start)     →   [B*, A]
L2: patch A.title         →   [B*, A'*]
revert(L1)                →   [A'*]      // L2 still applied on top of base
revert(L2)                →   [A]        // back to base
```

`*` = optimistic.

The implementation:

1. On the first touch of any record, the **committed baseline** (the pre-optimistic snapshot) is captured globally — once per record across all layers.
2. On `revert(L)` or `commit(L, data:)`, the layer is removed from the pending list, the committed baseline is restored for every record the layer touched, and surviving layers' ops are replayed in id order on those records.
3. Connection ops follow the same pattern — the canonical's pre-layer state is captured once, and surviving layers' addNode/removeNode/patch calls re-apply on top.

This is why reverting a *middle* layer is safe: cachebay always rebuilds from the committed baseline, never from a layer-specific delta that could go stale.

---

## Performance

Verified by `Tests/CachebayTests/PerformanceTests.swift` on a typical M-series Mac (release build):

| Scenario                              | Throughput        | Per-op  |
| ------------------------------------- | ----------------- | ------- |
| Entity patch apply+revert             | ~530k ops/s       | 1.9 µs  |
| Connection addNode + commit (empty)   | ~233k ops/s       | 4.3 µs  |
| Connection addNode @ preload=5 000    | ~12k ops/s        | 86 µs   |
| Mixed patch+addNode apply+revert      | ~86k ops/s        | 11.6 µs |
| Revert bottom-of-1000 (per survivor)  | ~0.34 µs          | —       |

Tail latency at preload=5 000 stays p99/p50 < 5×; no hidden spikes hide in the amortised mean.

---

## Next steps

- [Storage](./STORAGE.md) — optimistic state is **not** persisted; only committed records replicate to disk.
- [Relay Connections](./RELAY_CONNECTIONS.md) — `addNode` / `removeNode` reference.
- [Mutations](./MUTATIONS.md) — full server-side patterns.
