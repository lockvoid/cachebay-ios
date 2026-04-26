# Keynotes

How Cachebay-iOS works, end to end, in five minutes. Not an API guide — a mental model. For surface API and recipes, jump to [SETUP](./SETUP.md), [QUERIES](./QUERIES.md), and [OPTIMISTIC_UPDATES](./OPTIMISTIC_UPDATES.md).

---

## 1) Core model: a normalized graph

Everything lives in a single normalized **graph**:

- **Entities** — one record per `Type:id` (e.g. `Spell:42`) with field snapshots.
- **Edges** — tiny records carrying edge metadata (e.g. `cursor`, `score`) and a `__ref` pointer to a node:
  ```json
  { "__typename": "SpellEdge", "cursor": "s42", "node": { "__ref": "Spell:42" } }
  ```
- **Connections** — canonical records under `@connection.<field>(...)` with:
  - `edges: { "__refs": ["@connection.spells.edges:0", ...] }`
  - `pageInfo: { "__ref": "@connection.spells.pageInfo" }`
  - any extra connection-level fields (shallow-merged).
- **Pages** — concrete page records (e.g. `@.spells({"first":2,"after":"s2"})`) whose edge records are reused by the canonical list.

Pointers are simple `__ref` strings. Reads chase refs — no deep tree copies, no per-call rematerialisation.

---

## 2) The plan: what to fetch vs what to cache

Every operation is compiled to a **CachePlan** — a flat field tree with:

- A **network query string** (`__typename` injected, `@connection` stripped).
- Per-field **argument builders** (variable-aware) for cache-key construction.
- **Connection metadata** (mode / filters / key) for canonicalisation.
- Stable **fingerprint** + numeric **id** so signatures match whether the plan was built at runtime or pre-baked by `cachebay-cli`.
- A **variable mask** (strict + canonical) for watcher-signature dedup.

If you use the codegen, the plan is a literal in the generated Swift — runtime never parses GraphQL. If you pass a string at runtime, the `Planner` parses + lowers once and caches by source.

---

## 3) Documents: normalize → canonicalize → materialize

**Normalize**
Network frames are written as entities, edges, and **page** records. Mutations land under `@mutation.N` rootIds; subscriptions under `@subscription.N`.

**Canonicalize**
For every connection key:
- **infinite**: append/prepend page edges into a **growing union**; **dedup by node key** (`O(1)` via `ConnectionIndex`); refresh kept edge meta in place.
- **page**: replace the visible window with the last page.
- `pageInfo` and connection-level fields are **shallow-merged**. Boundary fields (`startCursor`/`endCursor`/`hasNextPage`/`hasPreviousPage`) follow Relay rules — ordered relative to the existing list.

Out-of-order pages converge to the same canonical state.

**Materialize**
Reads walk the plan against the graph and produce typed `Data` (typed via codegen) or `JSONValue` trees. A parallel **fingerprint tree** lets watcher emissions reuse unchanged sub-objects (`recycleSnapshots`).

---

## 4) Optimistic engine: layered & reconstructive

`client.modifyOptimistic { tx, ctx in … }` opens a **layer**:

```swift
let tx = client.modifyOptimistic { b, _ in
    b.patch(.key("Spell:42"), ["title": "Draft"], mode: .merge)
    let c = b.connection(ConnectionSelector(parent: .key("Query"), key: "spells"))
    c.addNode(["__typename": "Spell", "id": "tmp:1", "title": "Draft"], options: AddNodeOptions(position: .start))
}
```

- `tx.commit(serverData)` re-runs the builder in `.commit` phase with server data and drops the layer.
- `tx.revert()` removes only that layer; cachebay restores the **committed baseline** then **replays** all surviving layers on the touched records.

Stacked layers compose deterministically: revert any one and the rest stay applied.

---

## 5) Runtime: policies + suspension

- **Policies** (set globally, override per call):
  - `cacheOnly` — serve cache or `cacheMiss`.
  - `cacheFirst` — cached terminal else one network.
  - `cacheAndNetwork` — cached immediately **and** revalidate.
  - `networkOnly` — always network.
- **Suspension** — a short window after a result where re-executing the same canonical signature serves cached terminally instead of refetching. Smooths out duplicate Suspense-style re-execs.
- **Mutations & subscriptions** — normalized side-effects merge into the graph; mutations forward the original payload, subscriptions stream non-terminating updates.

(There's no `SSR` / `hydrate()` window — that's web-only and intentionally removed for iOS. Cold-start warm cache comes from SQLite persistence; see [STORAGE](./STORAGE.md).)

---

## 6) Identity: keys & interfaces

- **Keys** — optional per-type closures compute `Type:id`. Default: object's `id` field.
- **Interfaces** — map parent → concrete types (e.g. `Spell: ["AudioSpell", "VideoSpell"]`) so `readFragment(id: "Spell:42", ...)` resolves to the concrete record once known.

---

## 7) Persistence

`SQLiteStorage` write-behinds every graph mutation to `records` + `journal` tables in SQLite. On launch, the graph **gap-fills** from disk before the first network call — UI renders the warm cache instantly. Cross-process journal polling lets multi-WebView Capacitor apps see each other's writes within ~100 ms.

Details: [STORAGE.md](./STORAGE.md).

---

## 8) Performance principles

- **Pointer-chasing only** — `__ref` hops + `O(1)` Map lookups, no deep tree walks.
- **No edge-list scans** — `ConnectionIndex` (`nodeKey → edgeKey`) makes addNode/removeNode `O(1)` regardless of connection size.
- **Idempotent merges** — replays, retries, out-of-order pages all converge.
- **Locks > actors** — synchronous reads, recursive lock for legitimate re-entrancy, callbacks fired *outside* the lock. See [SETUP.md](./SETUP.md#concurrency-model).
- **Pre-baked plans** — codegen emits `CachePlan` literals; runtime skips parse/lower entirely.

---

## 9) Data flow at a glance

```
       ┌──────────┐
Net  ─▶│ Normalize│──▶ Entities · Edges · Page records
       └────┬─────┘
            ▼
       ┌─────────────┐   (mode-aware merge, dedup by node key,
       │ Canonicalize│──▶ refresh kept edge meta, pageInfo updates)
       └────┬────────┘
            ▼
   (if any) Replay optimistic layers (touched-records scope)
            ▼
       ┌────────────┐
       │ Materialize│──▶ Typed Data (codegen) · stable edges[] · fingerprints
       └────┬───────┘
            ▼
       Publish (policy-aware; suspension window honoured)
            │
            └──▶ SQLite write-behind (replicated, gap-filled at next launch)
```

The graph is the single source of truth; views are reactive projections.

---

MIT © LockVoid Labs ~●~
