# Type reducers

A per-type hook fired at the moment of every wire-side entity write — query responses, mutation responses, subscription frames, fragment writes. The reducer receives both sides of the merge (the currently-stored record and the merge candidate) and returns the dict that actually lands in the cache.

The hook is **opt-in per `__typename`**. Register a reducer for `Chat` and only `Chat` writes pay the closure cost; every other type continues through the default field-wise merge with zero overhead.

## The problem it solves

A single entity can receive writes from many subscription channels and refetches in parallel. If two snapshots of the same entity arrive out of order, the cache's default last-write-wins merge can clobber newer state with older — e.g. a stale `chatMessageCreated` carrying `chat.state = toolCalling` overwrites a fresh `chatMessageUpdated` that already moved `chat.state` to `idle`.

A type reducer lets the consumer guard against this with a one-line policy: compare an `updatedAt` (or version) field on both sides, keep whichever is newer.

## Quick start

```swift
let client = CachebayClient(options: CachebayOptions(
    transport: Transport(http: URLSessionHTTPTransport(endpoint: api)),
    typeReducers: [
        "Chat": { ctx in
            // First write — accept it.
            guard let prev = ctx.prev else { return ctx.next }
            let prevT = prev["updatedAt"]?.string ?? ""
            let nextT = ctx.next["updatedAt"]?.string ?? ""
            return nextT >= prevT ? ctx.next : prev
        }
    ]
))
```

That's it. Wire writes for `Chat` now run through the reducer; everything else is unchanged.

## What the reducer receives

```swift
public struct EntityMergeContext: Sendable {
    public let id: String                    // identity, e.g. "1" for Chat:1
    public let prev: [String: JSONValue]?    // current stored record (nil if new entity)
    public let next: [String: JSONValue]     // merge candidate (what the cache *would* store)
}
```

`next` is **not** the raw wire patch — it's the result of the default field-wise merge of the wire patch over `prev`. So if the wire payload only carries `{state}` but `prev` has `{state, updatedAt, activeRole}`, then `next` carries `{state: ...new, updatedAt: ...old, activeRole: ...old}`. You can read `updatedAt` off `next` even when the payload didn't carry it, because the reducer always sees the merge candidate as a full record.

Typename is implicit from the dict key the reducer was registered under.

## What you return

Any `[String: JSONValue]`. Conventional patterns:

| Return | Meaning |
|---|---|
| `ctx.next` | Accept the default merge. Same as not registering a reducer. |
| `ctx.prev ?? ctx.next` | Reject the incoming write. The cache reverts to the prior state. |
| Custom dict | Install your own merged record. Useful for stitched merges (e.g. accept some fields, reject others). |

## What happens when you reject

Returning `prev` reverts the record. The cache's differ then sees zero field-level changes between what's stored and what was stored before. **No watcher fanout fires for the rejected write.** The differ does all of this on its own; you don't have to signal "skip emit" anywhere.

## When the hook fires

| Path | Reducer fires |
|---|:---:|
| `executeQuery` (cache miss) | ✅ |
| `executeMutation` | ✅ |
| `executeSubscription` (each frame) | ✅ |
| `writeQuery` / `writeFragment` | ✅ |
| `readQuery` / `readFragment` | — (reads don't write) |
| `modifyOptimistic` (layer apply, replay, commit) | — (optimistic is explicit user intent) |
| Storage warmup (records loaded from disk) | — (already in canonical form) |

Optimistic bypass is structural — `modifyOptimistic` writes go through `Optimistic.swift` which calls `Graph.putRecord` directly, never through the entity-level normalize where the hook lives. You don't need a flag for it; the bypass falls out of the architecture.

## Performance contract

- **No reducers registered** (the default): every entity write pays one `Dictionary.isEmpty` check. That's it. No allocations, no closure dispatch, no snapshot work. The hook compiles out.
- **Reducer registered for type T**: every entity write for T pays two `Graph.getRecord` calls (prev snapshot, next snapshot — both dict lookups under one lock acquisition each) and one closure invocation. Writes for *other* types pay only the dict lookup miss.

In the release-mode benchmark suite (705-flat-posts, 5×140 nested projects), the no-reducer path is indistinguishable from the pre-feature baseline.

## Partial payloads

The wire often carries a subset of an entity's fields. The reducer sees the merge candidate (`next`), not the raw partial patch — so if you need to read a field that wasn't in this payload but exists in the prior record, just read it off `next`. It's already there.

```swift
"Chat": { ctx in
    // `next.updatedAt` is present even if the wire payload only carried `{state}`,
    // because next = mergeFields(prev, wirePatch).
    guard let prev = ctx.prev else { return ctx.next }
    return (ctx.next["updatedAt"]?.string ?? "") >= (prev["updatedAt"]?.string ?? "")
        ? ctx.next : prev
}
```

## Stitched merges

Reducers don't have to choose all-or-nothing. Return any dict you want:

```swift
"Chat": { ctx in
    // Accept everything from incoming, except refuse to downgrade `state`
    // to a value the server lists as older than what we already have.
    guard let prev = ctx.prev else { return ctx.next }
    var merged = ctx.next
    if needsRollbackProtection(prev: prev["state"], next: ctx.next["state"]) {
        merged["state"] = prev["state"]
    }
    return merged
}
```

## What it doesn't do

- **No async / no `throws`.** Reducers are sync, pure functions. They run on the thread doing the entity write. Don't perform I/O.
- **No cross-entity awareness.** A `Chat` reducer only sees `Chat`. If you need to coordinate across types, do it outside the reducer or via a separate watcher.
- **No connection-record support.** Reducers fire on entity records keyed by `__typename:id`. Connection canonicals, edges, and page records have their own merge model (see `RELAY_CONNECTIONS.md`).
- **No per-field policies.** The reducer sees and returns whole records. If you need per-field policy, branch on the field inside your closure.

## Idiomatic Chat-version guard

The full example, copy-paste ready:

```swift
extension CachebayOptions {
    static func production(transport: Transport) -> CachebayOptions {
        .init(
            transport: transport,
            typeReducers: [
                "Chat": { ctx in
                    guard let prev = ctx.prev,
                          let prevT = prev["updatedAt"]?.string,
                          let nextT = ctx.next["updatedAt"]?.string
                    else { return ctx.next }
                    return nextT >= prevT ? ctx.next : prev
                }
            ]
        )
    }
}
```
