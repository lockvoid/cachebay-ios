# Optimistic Updates

Cachebay's optimistic engine is **layered** and **reconstructive**. Each `modifyOptimistic` call opens a layer that applies immediately. You finish a layer with one of three lifecycle methods:

| Method                  | Effect                                                                                                                  | When to use                                                                                      |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `tx.dispose()`          | Drop the layer; **don't** restore baselines, **don't** run any commit-time work.                                        | The server response normalized into the cache is authoritative. **Most update-style mutations.** |
| `tx.commit { b in … }`  | Restore baselines for touched records, replay surviving layers, then run the **separate commit closure** once.          | Temp-id swap or any other case where you need explicit commit-time ops captured from outer scope. |
| `tx.revert()`           | Restore baselines for touched records, replay surviving layers. Drop the layer.                                         | The mutation failed.                                                                             |

Works for **entities** and **Relay connections**. No edge-list churn; updates are O(1) on connection size via the node index.

---

## TL;DR

```swift
// Open a layer — single-arg closure, no `ctx`.
let tx = client.modifyOptimistic { b in
    // 1) Typed entity merge — only the touched field lands in the patch.
    b.patch(fragment: PostFields.self, id: "p1") { draft in
        draft.title = "Draft…"
    }

    // 2) Connection link — purely structural, takes an EntityRef.
    //    Cachebay extracts identity from the typed payload and inserts
    //    the edge ref. The entity record itself is owned by `documents.normalize`
    //    (which ran when the server response landed) — `linkNode` does
    //    NOT touch entity scalars.
    b.connection(ConnectionSelector(key: "posts"))
        .linkNode(node: created, options: LinkNodeOptions(position: .start))
}

let result = try await client.executeMutation(...)

// Success — the server response is the full Post (PostFields). Normalize
// already wrote it into Post:p1; just drop the layer.
tx.dispose()

// Failure — roll back this layer; siblings keep their effects.
// tx.revert()
```

> **Two stores, two APIs.** Entity records (`Post:p1`, `User:u1`, …) are owned by `documents.normalize` (auto from query / mutation / subscription responses) or by an explicit `b.writeFragment` / `b.patch` / `b.delete`. Connection mutations (`b.connection(...).linkNode/unlinkNode/patch`) are owned separately: they manage edge refs, edge meta, and pageInfo — **never entity scalars**. The link primitive takes an `EntityRef`, not a node dict, so the API surface itself enforces the contract.
>
> If you want a fresh entity in the cache (optimistic-create flow), use `b.writeFragment(fragment:id:data:)` before linking — see ["Optimistic create flow"](#optimistic-create-flow) below.

---

## Lifecycle: dispose vs commit vs revert

The default mental model from cachebay-web is *"commit on success, revert on failure"*. iOS adds **`dispose()`** because the typical iOS flow awaits the server BEFORE finalizing the layer:

```swift
let tx = client.modifyOptimistic { b in
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

`commit { b in … }` is still useful when you genuinely want commit-time ops — the canonical "temp-id swap" pattern. But for mutations where the server returns the full entity (or any superset of the optimistic patch), prefer `dispose()`.

### When to use each

- **`dispose()`** — server response is authoritative for the touched records. Examples: `updateProject`, `updateClip`, `deleteProject`, `upsertElement`. ~80% of real mutations.
- **`commit { b in … }`** — temp-id swap or any case where commit-time ops differ from optimistic-time ops. The commit closure captures typed server data from outer scope (no `ctx.data` indirection).
- **`revert()`** — the mutation failed.

### ARC drops the tx → layer disposes automatically

`OptimisticTransaction` is a reference type (`final class`). Its `deinit` calls `dispose()` — so a tx that goes out of scope **without** an explicit `commit` / `revert` / `dispose` will release its layer when ARC tears it down. This is the safety net for forgotten-resolution paths:

```swift
func optimisticLike(postID: String) async throws {
    let tx = client.modifyOptimistic { b in
        b.patch(.key("Post:\(postID)"), ["liked": .bool(true)], mode: .merge)
    }
    // If executeMutation throws or the surrounding Task is cancelled,
    // `tx` goes out of scope before any explicit resolution. ARC
    // releases it → deinit fires → layer disposes. No leak.
    let r = try await client.executeMutation(...)
    if r.error != nil { tx.revert() } else { tx.dispose() }
}
```

This is **dispose semantics, not revert** — the optimistic effect on the visible graph is left in place when ARC drops the tx. The next normalize call writes server-authoritative data over it as usual; the layer just stops contributing to replay. If you want the optimistic patch reverted on every error path, call `tx.revert()` explicitly — don't rely on ARC for rollback.

If you need the optimistic effect to persist *beyond* the scope where the tx is created (e.g. a view-model holding the patch until a long-running task completes), store the `OptimisticTransaction` reference in a property with the lifetime you want. Otherwise the deinit will fire at the end of the creating scope.

`commit` / `revert` / `dispose` are idempotent — calling any of them after another (or after ARC has already fired deinit on a resolved tx) is a no-op, not a double-free.

---

## Single-phase variant: `autoCommit`

When you've **already awaited** the server response and only want to write the result through the builder API, use the single-phase form:

```swift
let result = try await client.executeMutation(mutation: CreateProject.self, ...)
guard let created = result.data?.createProject else { throw ... }

client.modifyOptimistic(autoCommit: true) { b in
    let keys = client.inspect.getConnectionKeys(parent: .root, key: "projects")
    for key in keys {
        b.connection(key: key).linkNode(node: created,
                                         options: LinkNodeOptions(position: .start))
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
    // Typed link by typed payload. Cachebay extracts identity
    // (__typename + id) from the payload and forwards an EntityRef.
    // Does NOT write entity scalars — entity records are owned
    // by `documents.normalize` (already wrote the response when
    // the mutation landed) or by an explicit `b.writeFragment`.
    func linkNode<N: OperationData>(node: N, options: LinkNodeOptions = .init())

    // Typed link by fragment + bare id. The fragment supplies the
    // typename, canonicalised through the interfaces map so a variant
    // fragment targets the right canonical entity record. Use this
    // in optimistic-create flows after `writeFragment` has bootstrapped
    // the entity:
    //
    //   b.writeFragment(fragment: PostFields.self, id: tempId, data: draft)
    //   c.linkNode(fragment: PostFields.self, id: tempId,
    //              options: .init(position: .start))
    func linkNode<F: Fragment, ID: LosslessStringConvertible>(
        fragment: F.Type,
        id: ID,
        options: LinkNodeOptions = .init()
    )

    // Typed unlink keyed by bare id.
    func unlinkNode<F: Fragment, ID: LosslessStringConvertible>(
        fragment: F.Type,
        id: ID
    )
}
```

### Typed commit

```swift
public extension OptimisticTransaction {
    // Wraps result.data into JSONValue.object — no manual dance.
    // (No typed `commit` overload — the commit closure captures typed
    // data from outer scope via ordinary Swift closure semantics.)
    // `tx.commit { b in … }` takes a separate commit-phase builder.
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
    /// Insert an edge into the connection pointing at `ref`. Purely
    /// structural — does not write to the entity record. The entity
    /// must already exist in the cache (via `documents.normalize` /
    /// `b.writeFragment`) for the link to materialize anything when
    /// read.
    func linkNode(_ ref: EntityRef, options: LinkNodeOptions)
    /// Remove the edge that points at `ref` from this connection.
    /// The entity record itself is untouched — only the edge link is
    /// removed.
    func unlinkNode(_ ref: EntityRef)
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

### Two closures, captured by scope

`modifyOptimistic { b in … }` runs once on open. `tx.commit { b in … }` runs once on commit. There is no shared closure body, no `phase` switch, no `ctx.data` plumbing — typed server data flows in via ordinary Swift closure capture from the surrounding scope:

```swift
let tx = client.modifyOptimistic { b in
    // Optimistic-phase ops only.
    b.patch(.key("Post:temp:1"), ["title": "Drafting…"], mode: .merge)
}

let result = try await client.executeMutation(...)

tx.commit { b in
    // Commit-phase ops. `result` is captured directly — fully typed,
    // no JSONValue dance.
    if let post = result.data?.createPost?.post {
        b.patch(.key("Post:\(post.id)"), ["title": post.title], mode: .merge)
    }
}
```

The optimistic closure's recorded ops replay when a sibling layer commits/reverts; the closure itself never re-executes. The commit closure runs exactly once when this layer commits.

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

Removes the record snapshot. Edges referencing it are not auto-removed — use `connection.unlinkNode` for that.

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

### `c.linkNode(_ ref:, options:)` — link an existing entity

```swift
// Link by direct cache key:
c.linkNode(.key("Post:p1"), options: LinkNodeOptions(
    position: .start,                  // .start | .end | .before | .after
    anchor: .key("Post:42"),           // required for .before / .after
    edge: ["cursor": .string("cur42")] // edge-level metadata, lands on edge record
))

// Link by typed payload — Cachebay extracts identity:
c.linkNode(node: created, options: .init(position: .start))

// Link by fragment + id (typed; canonicalises interface namespaces):
c.linkNode(fragment: PostFields.self, id: tempId, options: .init(position: .start))
```

What `linkNode` does (and doesn't do):

- **Inserts an edge ref** into the canonical's `edges` refList at `position`. O(1) via `ConnectionIndex`.
- **Synthesises the edge record** with `__typename: <NodeTypename>Edge`, `node: .ref(entityKey)`, plus any `edge:` meta you passed.
- **Updates `::nodeIndex` and `::cursorIndex`** so subsequent dedup/anchor lookups are O(1).
- **Does NOT write to the entity record.** The entity scalars (`title`, `body`, etc.) come from `documents.normalize` (auto from the operation that produced this entity) or from an explicit `b.writeFragment` you ran beforehand. If the entity isn't in the cache yet, the edge ref will dangle until something writes it — that's the caller's responsibility.

### `c.unlinkNode(ref)`

```swift
c.unlinkNode(.key("Post:p1"))
c.unlinkNode(.object(["__typename": "Post", "id": "p1"]))
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
    b.connection(key: key).linkNode(node: created, options: .init(position: .start))
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

client.modifyOptimistic(autoCommit: true) { b in
    for key in client.inspect.getConnectionKeys(parent: .root, key: "projects") {
        b.connection(key: key).linkNode(node: created,
                                         options: LinkNodeOptions(position: .start))
    }
}
return created.id
```

### Update — instant UI + dispose

We can guess optimistically; the server's full response is authoritative on commit.

```swift
let tx = client.modifyOptimistic { b in
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
let tx = client.modifyOptimistic { b in
    for key in client.inspect.getConnectionKeys(parent: .root, key: "posts") {
        b.connection(key: key).unlinkNode(fragment: PostFields.self, id: id)
    }
}

do {
    _ = try await client.executeMutation(mutation: DeletePost.self,
                                          variables: .init(id: id))
    tx.dispose()  // optimistic unlinkNode is the desired final state
} catch {
    tx.revert()
}
```

<a id="optimistic-create-flow"></a>
### Optimistic create — write entity, then link

Write the temp entity into the cache so watchers can materialize it,
then link the temp id into every relevant connection. Two explicit
operations, two clean responsibilities — entity write via
`writeFragment`, structural link via `linkNode`.

```swift
let tempId = "temp:\(UUID().uuidString)"
let draft = PostFields.Data.make(id: tempId, title: input.title, body: input.body)

let tx = client.modifyOptimistic { b in
    b.writeFragment(fragment: PostFields.self, id: tempId, data: draft)
    for key in client.inspect.getConnectionKeys(parent: .root, key: "posts") {
        b.connection(key: key).linkNode(
            fragment: PostFields.self, id: tempId,
            options: LinkNodeOptions(position: .start)
        )
    }
}

do {
    let result = try await client.executeMutation(...)
    if let err = result.error { tx.revert(); throw err }
    // Server response normalized into Post:<realId>. Dispose the layer
    // (which holds the temp entity + temp-keyed edges) and run a fresh
    // autoCommit linking the real id into the same connections.
    tx.dispose()
    if let created = result.data?.createPost?.post {
        client.modifyOptimistic(autoCommit: true) { b in
            for key in client.inspect.getConnectionKeys(parent: .root, key: "posts") {
                b.connection(key: key).linkNode(node: created,
                                                 options: LinkNodeOptions(position: .start))
            }
            b.delete(.key("Post:\(tempId)"))
        }
    }
} catch {
    tx.revert()
}
```

For the most common case — server response is the only valid identity, no temp UI needed —  use `autoCommit` directly (see "Create — single-phase" above).

---

## Layering semantics

Layers apply in insertion order:

```
Base:                         [A]
L1: linkNode B (start)     →   [B*, A]
L2: patch A.title         →   [B*, A'*]
revert(L1)                →   [A'*]      // L2 still applied on top of base
revert(L2)                →   [A]        // back to base
```

`*` = optimistic.

The implementation:

1. On the first touch of any record, the **committed baseline** (the pre-optimistic snapshot) is captured globally — once per record across all layers.
2. On `revert(L)` or `commit(L, data:)`, the layer is removed from the pending list, the committed baseline is restored for every record the layer touched, and surviving layers' ops are replayed in id order on those records.
3. On `dispose(L)`, the layer is removed from the pending list and baselines are dropped for records this layer was the SOLE toucher of. Graph state is **not** modified.
4. Connection ops follow the same pattern — the canonical's pre-layer state is captured once, and surviving layers' linkNode/unlinkNode/patch calls re-apply on top.

This is why reverting a *middle* layer is safe: cachebay always rebuilds from the committed baseline, never from a layer-specific delta that could go stale.

### Pending layers survive server normalize

Pending optimistic layers are also re-applied **after every server-response normalize** (mutation responses, subscription frames, query refreshes, `writeFragment` calls). This closes a class of races where a server response carrying stale values for a field a pending layer just patched would silently clobber the optimistic state.

```
T=0    txA: patch Clip:c1.captionsEnabled = true.
T=100  txB: patch Clip:c1.volume = 0.5.
T=300  Server response to mutation A lands. The full ClipFields payload
       includes volume=1.0 (server didn't know about txB yet).
       documents.normalize → shallow-merges {volume: 1.0} over Clip:c1.
       → cachebay auto-replays pending layers' entity ops scoped to
         Clip:c1 → txB's volume=0.5 re-applies.
       Final state: {captionsEnabled: true, volume: 0.5}.
       No flicker. Pending patches survive.
```

Rules:

- **Replay is scoped** to the entity keys the normalize actually wrote. Layers' ops on records the normalize didn't touch are not re-applied.
- **Latest-id layer wins** on per-field conflicts between layers (same as everywhere else in the layered model).
- **Server data wins on UNpatched fields.** A layer patching `volume` does not block the server's `captionsEnabled` update; only the fields the layer's patch contains are re-applied.
- **Applies to all normalize paths** — mutation `executeMutation`, subscription frames in `executeSubscription`, query refresh in `executeQuery` (cache-and-network), and explicit `writeFragment` / `writeQuery`. Subscriptions are the most-race-prone path; this is where the protection matters most.
- **Symmetric with connection-side replay.** Connection canonicals have had this protection since v0.4 (the `OptimisticReplayer` bridge in `Canonical.updateConnection`). Entity records gained it in v0.9.1.

If you want the server's value to land on a patched field, the explicit options are:

- `tx.commit { b in b.patch(.key("…"), [...server value...], mode: .merge) }` — replace with server data.
- `tx.revert()` — drop the optimistic patch, baseline restore wins.
- `tx.dispose()` followed by a fresh write — drop layer bookkeeping, write the server-confirmed value explicitly.

Quietly dropping a pending optimistic patch was never something Cachebay should do silently; the three lifecycle methods are the only ways to override pending state.

---

## Performance

Verified by `Tests/CachebayTests/Performance/PerformanceTests.swift` on a typical M-series Mac (release build):

| Scenario                              | Throughput        | Per-op  |
| ------------------------------------- | ----------------- | ------- |
| Entity patch apply+revert             | ~530k ops/s       | 1.9 µs  |
| Connection linkNode + commit (empty)   | ~233k ops/s       | 4.3 µs  |
| Connection linkNode @ preload=5 000    | ~12k ops/s        | 86 µs   |
| Mixed patch+linkNode apply+revert      | ~86k ops/s        | 11.6 µs |
| Revert bottom-of-1000 (per survivor)  | ~0.34 µs          | —       |

Tail latency at preload=5 000 stays p99/p50 < 5×; no hidden spikes hide in the amortised mean.

---

## Next steps

- [Storage](./STORAGE.md) — optimistic state is **not** persisted; only committed records replicate to disk.
- [Relay Connections](./RELAY_CONNECTIONS.md) — `linkNode` / `unlinkNode` reference.
- [Mutations](./MUTATIONS.md) — full server-side patterns.
