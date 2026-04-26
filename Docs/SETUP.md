# Setup

Create a `CachebayClient` once at app boot and reuse it everywhere. The client is `Sendable` — pass it to any actor or thread.

## Create instance

```swift
import Cachebay

let client = CachebayClient(options: CachebayOptions(
    transport: Transport(
        http: URLSessionHTTPTransport(url: URL(string: "https://api.example.com/graphql")!),
        ws:  URLSessionWebSocketTransport(url: URL(string: "wss://api.example.com/graphql")!)
    ),
    cachePolicy: .cacheFirst,
    suspensionTimeout: 1.0,
    storage: SQLiteStorage.factory(options: .init(path: "/Users/me/Library/Caches/cachebay.sqlite"))
))
```

## Options

| Option              | Type                                | Default        | Notes |
| ------------------- | ----------------------------------- | -------------- | ----- |
| `transport`         | `Transport`                         | required       | `http: HTTPTransport` + optional `ws: WSTransport`. |
| `cachePolicy`       | `CachePolicy`                       | `.cacheFirst`  | Default applied to every `executeQuery` unless overridden. |
| `keys`              | `[String: KeyFunction]`             | `[:]`          | Custom identity per typename (see below). |
| `interfaces`        | `[String: [String]]`                | `[:]`          | Interface → concrete-types map for shared identity. |
| `suspensionTimeout` | `TimeInterval`                      | `1.0`          | Window after a network result where re-execs of the same canonical signature serve cached terminally. |
| `storage`           | `StorageAdapterFactory?`            | `nil`          | Persist + cross-process sync. Usually `SQLiteStorage.factory(options:)`. |

## Cache policies

| Policy             | Cache behaviour                              | Network behaviour                                     |
| ------------------ | -------------------------------------------- | ----------------------------------------------------- |
| `.cacheAndNetwork` | Emit immediately if cached.                  | Always fetch; revalidate on response.                 |
| `.cacheFirst`      | Use cache if present.                        | One network call only when cache is missing.          |
| `.networkOnly`     | Bypass cache for the read.                   | Always fetch; cache is updated from the response.     |
| `.cacheOnly`       | Read from cache only.                        | Never fetch; missing data → `CombinedError.cacheMiss()`. |

Override per call:

```swift
let r = try await client.executeQuery(
    query: GetSpell.networkQuery,
    variables: ["id": "p1"],
    cachePolicy: .cacheAndNetwork
)
```

## Entity identity

By default a record's id is its `id` field. Customise per type:

```swift
let client = CachebayClient(options: CachebayOptions(
    transport: ...,
    keys: [
        "User": { _, obj in obj["email"]?.string },
        "Spell": { _, obj in obj["uuid"]?.string }
    ],
    interfaces: [
        "Node": ["User", "Post", "Spell"]
    ]
))
```

- A `KeyFunction` receives `(typename, [String: JSONValue])` and returns the unique value for that record. It must be stable per entity.
- Interfaces let you read by parent type: `readFragment(id: "Node:42", ...)` resolves to the concrete record once `__typename` is known.
- Writes always go through the **concrete** type (`{__typename: "User", id: ...}`), but the cache key is rewritten to the canonical interface name when one exists.

## Concurrency model

Cachebay is **lock-based**, not actor-based. Every subsystem owns a single `NSRecursiveLock`. The lock acquisition order is documented and enforced by convention:

```
Queries · Fragments · Optimistic · Operations
                  │
                  ▼
             Documents
                  │
                  ▼
                Graph
```

Three rules:

1. Callbacks (`onData`, `onError`, storage writes) are invoked **after** releasing the owning subsystem's lock.
2. `Graph.flush()` drops `Graph.lock` before invoking `onChange`, so the fanout (which acquires Queries/Fragments locks) can never deadlock against the writer.
3. Operations holds its own lock only for short, non-nested critical sections (epoch bookkeeping, suspension window).

Stress tests under `Tests/CachebayTests/ConcurrencyStressTests.swift` validate this end to end. Why locks instead of actors:

- Synchronous reads (`readQuery` / `readFragment`) without `await`.
- Re-entrancy (a watcher's materialize triggers dep lookups against the same cache) is natural with a recursive lock.
- Emitting to a `@Sendable` callback outside the lock is one line; from an actor it requires detached tasks.

## Evict everything

For logout / account switch:

```swift
await client.evictAll()
```

This:

- Drops all in-memory entities.
- Clears persistent storage (records + journal).
- Notifies all watchers with `nil` so the UI clears.
- Re-fetches every active query watcher with `.networkOnly` so the next render is fresh.

## Next steps

- [Codegen](./CODEGEN.md) — generate typed operations + pre-baked CachePlans.
- [Operations](./OPERATIONS.md) — `executeQuery` / `executeMutation` / `executeSubscription`.
- [Storage](./STORAGE.md) — SQLite, cross-process sync.
