# Optimistic Updates

Cachebay's optimistic engine is **layered** and **reconstructive**. Each `modifyOptimistic` call opens a layer that applies immediately. You finish a layer with one of three lifecycle methods:

| Method            | Effect                                                                                          | When to use                                                                |
| ----------------- | ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `tx.dispose()`    | Drop the layer; **don't** restore baselines, **don't** re-run the builder.                      | The server response normalized into the cache is authoritative. **Most update-style mutations.** |
| `tx.commit(data)` | Restore baselines for touched records, replay surviving layers, **re-run the builder** at `.commit`. | You need the closure to re-execute with `ctx.data` set (e.g. temp-id swap). |
| `tx.revert()`     | Restore baselines for touched records, replay surviving layers. Drop the layer.                 | The mutation failed.                                                        |

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

    // 2) Plan-aware typed connection prepend — initializes nested
    //    @connection canonicals from the fragment plan and strips
    //    selection-set fields from the entity patch so existing
    //    ref/refList links survive a merge.
    let c = b.connection(ConnectionSelector(key: "posts"))
    c.addNode(node: created, fragment: PostFields.self,
              options: AddNodeOptions(position: .start))
}

let result = try await client.executeMutation(...)

// Success — the server response is the full Post (PostFields). Normalize
// already wrote it into Post:p1; just drop the layer.
tx.dispose()

// Failure — roll back this layer; siblings keep their effects.
// tx.revert()
```

---

## Lifecycle: dispose vs commit vs revert

The default mental model from cachebay-web is *"commit on success, revert on failure"*. iOS adds **`dispose()`** because the typical iOS flow awaits the server BEFORE finalizing the layer:

```swift
let tx = client.modifyOptimistic { b, _ in
    b.patch(fragment: PostFields.self, id: id) { d in d.title = optimisticTitle }
}

let result = try await client.executeMutation(...)
//                       ^ this also normalizes the response into the graph,
//                         updating `Post:id` with all server-authoritative fields.

if result.error != nil { tx.revert(); throw ... }

tx.dispose()  // ← server normalize already wrote the canonical state.
              //   commit(...) here would replaceRecord(Post:id, preOptimisticBaseline)
              //   and wipe any server-side fields the patch didn't touch
              //   (e.g. server-bumped `updatedAt`, server-replaced `clips`).
```

`commit(_:)` is still useful when you genuinely want the closure to re-run with `ctx.data` — the canonical "temp-id swap" pattern. But for mutations where the server returns the full entity (or any superset of the optimistic patch), prefer `dispose()`.

### When to use each

- **`dispose()`** — server response is authoritative for the touched records. Examples: `updateProject`, `updateClip`, `deleteProject`, `upsertElement`. ~80% of real mutations.
- **`commit(data)`** — your closure needs to re-execute against server data, typically because the optimistic phase wrote a temp id and the commit phase needs the real id.
- **`revert()`** — the mutation failed.

The asymmetry is pinned by `OptimisticDisposeTests.test_commit_restoresPreOptimisticBaseline_wipingServerUpdates` — locks in the bug we use `dispose()` to avoid.

---

## Single-phase variant: `autoCommit`

When you've **already awaited** the server response and only want to write the result through the builder API, use the single-phase form:

```swift
let result = try await client.executeMutation(mutation: CreateProject.self, ...)
guard let created = result.data?.createProject else { throw ... }

client.modifyOptimistic(autoCommit: true) { b, _ in
    let keys = client.inspect.getConnectionKeys(parent: .root, key: "projects")
    for key in keys {
        b.connection(key: key).addNode(node: created, fragment: ProjectFields.self,
                                        options: AddNodeOptions(position: .start))
    }
}
// Already applied — no transaction returned.
```

This skips the `.optimistic` phase entirely and runs the builder **once** at `.commit` phase, applying ops directly to the base graph without recording a layer. Compared to the standard form + `dispose()`:

| Standard + dispose                         | autoCommit                          |
| ------------------------------------------ | ----------------------------------- |
| Closure runs twice (.optimistic + .commit) | Closure runs once (.commit)         |
| Layer recorded, then dropped               | No layer ever recorded              |
| Returns `OptimisticTransaction`            | Returns `Void`                      |

Use `autoCommit` for create-style mutations where you already have the server payload (no temp/optimistic state to project). Use the standard two-phase form for instant-UI mutations (rename, delete, mute, …).

---

## Builder API

The runtime exposes both **typed** overloads (driven by codegen — preferred for everyday use) and **JSON-shaped** primitives (escape hatch for cases the typed shape can't express).

### Typed — entity

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
```

### Typed — connection

```swift
public extension ConnectionAPI {
    // Plan-aware: pass a typed entity AND its fragment. The fragment
    // plan governs (a) initialization of nested @connection canonicals,
    // (b) selection-set field stripping from the entity-record patch
    // so existing ref/refList links survive a merge.
    func addNode<N: OperationData, F: Fragment>(
        node: N,
        fragment: F.Type,
        variables: [String: JSONValue] = [:],
        options: AddNodeOptions = AddNodeOptions()
    )

    // Same as above, but takes F.Data directly.
    func addNode<F: Fragment>(
        node: F.Data,
        fragment: F.Type,
        variables: [String: JSONValue] = [:],
        options: AddNodeOptions = AddNodeOptions()
    )

    // Typed node from any OperationData (no fragment) — RAW path,
    // doesn't run plan-aware normalization. Prefer the fragment-typed
    // overload above unless you know the entity has no selection-set
    // fields (rare).
    func addNode<N: OperationData>(node: N, options: AddNodeOptions)

    // Typed closure-builder for optimistic nodes (no server data yet).
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

### Typed commit

```swift
public extension OptimisticTransaction {
    // Wraps result.data into JSONValue.object — no manual dance.
    func commit<O: OperationData>(_ data: O?)
}
```

### JSON-shaped (primitives)

```swift
public protocol OptimisticBuilder: AnyObject, Sendable {
    func patch(_ target: EntityRef, _ patch: [String: JSONValue], mode: EntityPatchMode)
    func patch(_ target: EntityRef, mode: EntityPatchMode,
               _ build: @Sendable (_ prev: [String: JSONValue]) -> [String: JSONValue])
    func delete(_ target: EntityRef)
    func connection(_ selector: ConnectionSelector) -> ConnectionAPI
    func connection(key canonicalKey: CacheKey) -> ConnectionAPI
}

public protocol ConnectionAPI: AnyObject, Sendable {
    var key: CacheKey { get }
    func addNode(_ node: [String: JSONValue], options: AddNodeOptions)
    func removeNode(_ ref: EntityRef)
    func patch(_ update: [String: JSONValue])
    // Closure form — read prev snapshot, return patch to merge.
    func patch(_ build: @Sendable (_ prev: [String: JSONValue]) -> [String: JSONValue])
}
```

### `EntityRef` resolves

| Ref form                                         | Result                                              |
| ------------------------------------------------ | --------------------------------------------------- |
| `.key("Post:p1")`                                | direct                                              |
| `.object(["__typename": "Post", "id": "p1"])`    | identified via your `KeyFunction` / `id` fallback   |

### Builder context

Your builder closure receives `(builder, ctx)`. `ctx.phase` is `.optimistic` on the initial call and `.commit` when `commit(data:)` re-runs it. `ctx.data` is `nil` at `.optimistic` and the `JSONValue` you passed to `commit(_:)` at `.commit`.

```swift
let tx = client.modifyOptimistic { b, ctx in
    // Use server data when commit phase fires; temp on the optimistic pass.
    let id = ctx.data?["id"]?.string ?? "temp:1"
    b.patch(.key("Post:\(id)"), ["title": "X"], mode: .merge)
}
tx.commit(.object(["id": "real-id"]))
```

This re-execution lets you swap a temp id for the server-assigned one and rebuild the same effects against the real record. **Note:** if your closure doesn't actually use `ctx.data`, `commit(...)` is a wasteful round-trip — prefer `dispose()`.

---

## Entities

### `b.patch(target, patch, mode:)`

- `.merge` (default): shallow-merge fields into the existing snapshot. Setting a field to `.undefined` removes it.
- `.replace`: write exactly the provided fields, drop everything else.

```swift
b.patch(.key("Post:p1"), ["title": "Renaming…"], mode: .merge)
b.patch(.key("Post:p1"), ["__typename": "Post", "id": "p1", "title": "Fresh"], mode: .replace)
```

Closure form — read existing snapshot to compute a delta:

```swift
b.patch(.key("Post:p1"), mode: .merge) { prev in
    let count = prev["likes"]?.int ?? 0
    return ["likes": .int(count + 1)]
}
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
        parent: .key(CachebayConstants.rootID),  // or .key("User:u1") / .object(user)
        key: "posts",
        filters: ["category": .string("tech")]
    )
)
// or by canonical key directly:
let c2 = b.connection(key: "@connection.posts({\"category\":\"tech\"})")
```

### `c.addNode(node, fragment:, options:)` — plan-aware

```swift
c.addNode(node: created, fragment: PostFields.self, options: AddNodeOptions(
    position: .start,                  // .start | .end | .before | .after
    anchor: .key("Post:42"),           // required for .before / .after
    edge: ["cursor": .string("cur42")] // edge-level metadata
))
```

What plan-aware means:

1. **Stamps `__typename`** from `F.onTypename` if the node data omits it.
2. **Initializes nested `@connection` canonicals** for every connection field in the fragment plan (idempotent — preserves existing canonicals; uses inline `edges`/`pageInfo` from node data when present).
3. **Strips selection-set fields** from the entity-record patch (two-pass: plan-aware via `PlanField.selectionSet`, then shape-aware via `__typename` heuristic for fields outside the plan). Existing ref/refList links survive a merge.

Without (3), passing a typed mutation result whose `__data` carries `clips: []` (an empty array) would overwrite the server-cycle `clips: .refList(...)` with a raw array, hard-missing the watcher. The typed `addNode(fragment:)` is the supported path; the no-fragment overload is an unsafe escape hatch.

### `c.removeNode(ref)`

```swift
c.removeNode(.key("Post:p1"))
c.removeNode(.object(["__typename": "Post", "id": "p1"]))
```

Removes the first occurrence of that node. The underlying entity record is untouched.

### `c.patch(update)`

```swift
// Direct partial:
c.patch([
    "pageInfo": .object(["hasNextPage": .bool(false)]),
    "totalCount": .int(10)
])

// Closure form — read prev snapshot, increment a scalar:
c.patch { prev in
    let count = prev["totalCount"]?.int ?? 0
    return ["totalCount": .int(count + 1)]
}
```

Shallow-merges into the canonical record. If `pageInfo` is included, it's merged field-by-field on the linked PageInfo record.

---

## Helpers

`client.inspect.getConnectionKeys(...)` finds matching canonicals so a single mutation can fan out:

```swift
for key in client.inspect.getConnectionKeys(parent: .root, key: "posts") {
    b.connection(key: key).addNode(node: created, fragment: PostFields.self,
                                    options: .init(position: .start))
}
```

Filter by parent (`.root`, `.entity("User:u1")`, `.entityObject(typename:id:)`), by field name, or by a raw-args predicate.

---

## Recipes

### Create — single-phase (`autoCommit`)

The server has the only valid id; no temp/optimistic state to project.

```swift
let result = try await client.executeMutation(mutation: CreateProject.self,
                                                variables: .init(input: input))
if let err = result.error { throw ProjectError.graphQL(err.localizedDescription) }
guard let created = result.data?.createProject else { throw ProjectError.noData }

client.modifyOptimistic(autoCommit: true) { b, _ in
    for key in client.inspect.getConnectionKeys(parent: .root, key: "projects") {
        b.connection(key: key).addNode(node: created, fragment: ProjectFields.self,
                                        options: AddNodeOptions(position: .start))
    }
}
return created.id
```

### Update — instant UI + dispose

We can guess optimistically; the server's full response is authoritative on commit.

```swift
let tx = client.modifyOptimistic { b, _ in
    b.patch(fragment: ProjectFields.self, id: id) { p in
        if let n = input.name { p.name = n }
        p.updatedAt = Date().iso8601String
    }
}

do {
    let result = try await client.executeMutation(mutation: UpdateProject.self,
                                                   variables: .init(id: id, input: input))
    if result.error != nil { tx.revert(); throw ... }
    tx.dispose()  // server normalize already wrote canonical Project:id
} catch {
    tx.revert()
    throw error
}
```

### Delete — instant UI + dispose

```swift
let tx = client.modifyOptimistic { b, _ in
    for key in client.inspect.getConnectionKeys(parent: .root, key: "posts") {
        b.connection(key: key).removeNode(fragment: PostFields.self, id: id)
    }
}

do {
    _ = try await client.executeMutation(mutation: DeletePost.self,
                                          variables: .init(id: id))
    tx.dispose()  // optimistic removeNode is the desired final state
} catch {
    tx.revert()
}
```

### Temp-id swap — full two-phase

Rare in iOS (usually `autoCommit` is what you want). Use when you need the closure to re-execute with the real id.

```swift
let tempId = "temp:\(UUID().uuidString)"

let tx = client.modifyOptimistic { b, ctx in
    let id = ctx.data?["id"]?.string ?? tempId
    b.connection(key: "@connection.posts({})").addNode(
        fragment: PostFields.self,
        options: AddNodeOptions(position: .start)
    ) { d in
        d.id = id  // temp id at .optimistic, server id at .commit
        d.title = input.title
    }
}

do {
    let result = try await client.executeMutation(...)
    tx.commit(result.data)  // closure re-runs with real id; addNode dedups
} catch {
    tx.revert()
}
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
3. On `dispose(L)`, the layer is removed from the pending list and baselines are dropped for records this layer was the SOLE toucher of. Graph state is **not** modified.
4. Connection ops follow the same pattern — the canonical's pre-layer state is captured once, and surviving layers' addNode/removeNode/patch calls re-apply on top.

This is why reverting a *middle* layer is safe: cachebay always rebuilds from the committed baseline, never from a layer-specific delta that could go stale.

---

## Performance

Verified by `Tests/CachebayTests/Performance/PerformanceTests.swift` on a typical M-series Mac (release build):

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
