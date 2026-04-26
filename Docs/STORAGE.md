# Storage — SQLite Persistence + Cross-Process Sync

Cachebay can persist the normalized graph to SQLite and synchronise changes across processes (multi-WebView Capacitor apps, background services) in real time.

## Quick start

```swift
import Cachebay

let dbPath = (try! FileManager.default.url(
    for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
)).appendingPathComponent("cachebay.sqlite").path

let client = CachebayClient(options: CachebayOptions(
    transport: Transport(http: httpTransport, ws: wsTransport),
    storage: SQLiteStorage.factory(options: .init(path: dbPath))
))
```

That's it. Every committed record write is replicated to disk asynchronously; on launch, the cache hydrates from disk (gap-fill semantics — see below) before the first network call.

## How it works

### Two-table journal

A single SQLite database serves both persistence and cross-process synchronisation.

| Table     | Key                                          | Value                                                 |
| --------- | -------------------------------------------- | ----------------------------------------------------- |
| `records` | `id TEXT PRIMARY KEY` (e.g. `"User:1"`)       | normalised snapshot (JSON-encoded blob)               |
| `journal` | `seq INTEGER PRIMARY KEY AUTOINCREMENT`       | `{ client_id, kind, record_id, ts }`                  |

The journal's autoincrement seq is monotonic across every process sharing the database, so a remote-sync poller can resume cleanly from `lastSeenSeq`.

### Write flow (this process)

1. `graph.flush()` calls `onChange(touched)`.
2. The client wires `onChange` to `storage.put(updates)` / `storage.remove(removed)`.
3. The adapter enqueues a serial-queue work item; control returns immediately to the caller.
4. The work item drains all queued ops in one `BEGIN IMMEDIATE` transaction, writing both the record + a journal row.

### Sync flow (other processes — optional)

Future versions will poll the journal (`SELECT * FROM journal WHERE seq > lastSeenSeq`), filter out our own `client_id`, and push remote changes back into the in-memory graph via `StorageContext.onUpdate` / `onRemove`. The protocol is already in place; just call `storage.flush()` to force an immediate poll. Multi-WebView Capacitor apps benefit most.

### Hydrate on launch

On `CachebayClient.init`, an async `storage.load()` runs in a Task. Records load into the graph **only where the in-memory store doesn't already have a record** — gap-fill semantics. Combined with no SSR, this means: if you've already written something to the cache before storage finishes loading, your write wins.

## Performance tuning

`SQLiteStorage` opens with:
- `PRAGMA journal_mode=WAL` — concurrent readers, fast writes.
- `PRAGMA synchronous=NORMAL` — balanced fsync cost.
- `PRAGMA temp_store=MEMORY` — small queries stay off disk.
- `PRAGMA cache_size=-8192` — ~8 MB SQLite-side page cache.
- Prepared statements for `INSERT OR REPLACE`, `DELETE`, journal-append — reused across writes.
- Write-behind on a serial `DispatchQueue` — callers never block on I/O.

Call `try await storage.flush()` at app-suspend / scene-deactivate time for a strict durability guarantee. Otherwise rely on WAL + fsync-on-checkpoint.

## API

When `storage` is configured:

```swift
public protocol StorageAdapter: Sendable {
    func put(_ records: [(CacheKey, [String: JSONValue])])
    func remove(_ ids: [CacheKey])
    func load() async throws -> [(CacheKey, [String: JSONValue])]

    func flush() async throws       // drain pending writes
    func evictJournal() async throws // delete journal entries older than journalMaxAge
    func evictAll() async throws    // clear records + journal, broadcast evict-all signal
    func inspect() async throws -> StorageInspection
    func dispose()
}
```

You access it as `client.storage`:

```swift
let info = try await client.storage?.inspect()
// StorageInspection(recordCount: 142, journalCount: 38, lastSeenSeq: 287, instanceID: "a1b2c3d4")

try await client.storage?.flush()
try await client.storage?.evictJournal()
```

## Options

```swift
SQLiteStorage.factory(options: SQLiteStorage.Options(
    path: "/path/to/cachebay.sqlite",
    journalMaxAge: 3600   // seconds; entries older than this are evicted
))
```

| Option           | Default | Description                                                   |
| ---------------- | ------- | ------------------------------------------------------------- |
| `path`           | required| SQLite file location.                                         |
| `journalMaxAge`  | 3600    | Seconds of journal retention. Override for chatty multi-process workloads. |

## Eviction strategy

- **On load**: stale journal entries are evicted immediately.
- **`storage.evictJournal()`**: manual cleanup (also called by `evictAll`).
- **`storage.evictAll()`**: nuke records + journal + write a single `evict-all` signal so other processes drop their in-memory cache too.
- **`client.evictAll()`**: high-level — clears in-memory + persistent + emits `nil` to all watchers + refetches active queries with `.networkOnly`.

## Custom storage

Conform to `StorageAdapter` + `StorageAdapterFactory` for alternate backends (e.g. `URLDocument`-backed iCloud sync, Core Data, a remote write-through). The factory receives a `StorageContext` with an `instanceID` (random per-process) and three callbacks for pushing remote changes back into the graph:

```swift
public typealias StorageAdapterFactory = @Sendable (StorageContext) -> StorageAdapter

public struct StorageContext: Sendable {
    public let instanceID: String
    public let onUpdate: @Sendable (_ records: [(CacheKey, [String: JSONValue])]) -> Void
    public let onRemove: @Sendable (_ ids: [CacheKey]) -> Void
    public let onEvictAll: (@Sendable () -> Void)?
}
```

Match the journal protocol or invent your own — cachebay just calls your `put` / `remove` and trusts you to wire up `onUpdate` / `onRemove` for any external changes.

## Edge cases

| Scenario                                  | Behaviour                                                  |
| ----------------------------------------- | ---------------------------------------------------------- |
| Storage load + in-process write race      | In-memory write wins; load only fills gaps                 |
| Optimistic update + revert                | Both flow through `onChange` — storage always matches graph |
| Process killed mid-write                  | WAL rolls back the partial txn; next launch sees committed data |
| All processes closed → reopen             | `records` has full state; old journal entries are evicted on load |
| Multiple `SQLiteStorage` instances, same path | Shared SQLite file; each polls the other's journal entries |

## Threading

`SQLiteStorage` is `@unchecked Sendable`. Internally:
- All SQLite handle access is serialised on a private `DispatchQueue`.
- `put`/`remove` are non-blocking and may be called from anywhere.
- `load`/`flush`/`evictAll`/`inspect` are `async` — they enqueue work and `await` completion.
- `dispose()` synchronously drains and closes; safe to call once at app shutdown.

## Next steps

- [Setup](./SETUP.md) — wire `storage:` in `CachebayOptions`.
- [Optimistic Updates](./OPTIMISTIC_UPDATES.md) — note: optimistic state isn't persisted, only committed records.
- [Keynotes](./KEYNOTES.md) — the persistence section in the bigger picture.
