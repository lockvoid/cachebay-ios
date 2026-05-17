# Changelog

All notable changes to Cachebay-iOS are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.2] — `OptimisticTransaction` lifetime tied to ARC (drop = dispose)

Changes `OptimisticTransaction` from a `struct` to a `final class` and adds a `deinit` that calls `dispose()`. A transaction whose owning reference is dropped without an explicit `commit` / `revert` / `dispose` is now released automatically when ARC tears it down, instead of leaking its layer for the lifetime of the client.

### The behaviour change

```swift
// v0.9.1 and earlier — leaked the layer forever:
func optimisticUpdateAndForget() {
    _ = client.modifyOptimistic { b in
        b.patch(.key("Post:p1"), ["likes": .int(42)], mode: .merge)
    }
    // Returned tx is dropped. Layer remains in `Optimistic.layers`
    // indefinitely. Every subsequent normalize replays it. Memory + CPU
    // creep on every long-running session that ever forgot to resolve.
}

// v0.9.2 — layer disposes automatically when ARC releases the tx:
func optimisticUpdateAndForget() {
    _ = client.modifyOptimistic { b in
        b.patch(.key("Post:p1"), ["likes": .int(42)], mode: .merge)
    }
    // Returned tx has no surviving reference → deinit fires → dispose()
    // runs → layer removed. Same observable behaviour as an explicit
    // `tx.dispose()` call.
}
```

`dispose` is the right default (not `revert`): the patch was already visible to the UI, and "drop without resolution" is the failure mode of error paths and task cancellation — replaying a half-applied layer on top of a possibly-evicted baseline would be worse than just leaving the visible state alone. Consumers that want rollback semantics must call `tx.revert()` explicitly.

### Failure modes this closes

- `Task` cancellation between `modifyOptimistic` and the awaited mutation — the tx local goes out of scope when the task unwinds, deinit cleans up.
- `throw` between `modifyOptimistic` and the explicit resolution call — same path: the throwing scope releases the tx local, deinit fires.
- Holder objects (view models, coordinators) being torn down with a pending tx — releasing the holder cascades to the tx via ARC.
- Bare-call sites (`_ = client.modifyOptimistic { ... }`) — the tx is released at the end of the enclosing statement.

### What "explicit resolution" still does

`commit`, `revert`, and `dispose` are unchanged on the surface. Internally, `commit` / `revert` now call into a private dispose closure that is idempotent — the deinit safety net executing on a transaction that was already resolved is a no-op, not a double-free. The same idempotency guard sits at the `Optimistic.commit(layer:commitBuilder:)` boundary: if the layer is already gone, `commit` exits before running its closure.

### Tests

New file: [`OptimisticTransactionLifetimeTests`](./Tests/CachebayTests/Runtime/OptimisticTransactionLifetimeTests.swift) — 7 contract tests covering:

- `_ = client.modifyOptimistic { ... }` releases the tx and disposes the layer.
- `var tx: OptimisticTransaction? = ...; tx = nil` disposes (manual ARC release).
- `Task { let tx = ...; ... }.cancel()` disposes (cancellation between open and resolve).
- A `throw` between `modifyOptimistic` and the planned resolution disposes.
- `tx.dispose()` followed by tx release is idempotent.
- `tx.commit { ... }` followed by tx release runs the commit closure exactly once.
- `tx.commit { ... }` called twice runs the closure exactly once (idempotency at the boundary).

### Source-level impact

`OptimisticTransaction` was a `Sendable` struct; it is now `final class: @unchecked Sendable`. Same public methods (`commit`, `revert`, `dispose`), same call sites. Reference semantics replace value semantics — copying a tx no longer creates an independent handle (it never made sense to: the layer is shared state, not a value).

Tests that previously bound a tx with `_ = client.modifyOptimistic { ... }` and inspected layer state afterwards now need a named binding (`let _tx = ...` plus a `withExtendedLifetime(_tx) {}` at end-of-scope) to keep the tx alive across the assertion block — otherwise ARC tears it down between the call and the read. Updated in this release: `OptimisticReplayResultTests`, `OptimisticTests`, `CanonicalReplayIntegrationTests`, `OptimisticAddNodeReplayTests`, `OptimisticSplitClosuresTests`, `OptimisticLayeringTests`, `OptimisticWriteFragmentTests`.

### Migration

Nothing for consumers to do unless you were relying on the leak. Code that calls `modifyOptimistic` and *always* resolves the returned tx via `commit` / `revert` / `dispose` behaves identically. Code that "forgot" to resolve will now release the layer on scope exit — observable difference: the optimistic effect disappears once your `tx` local goes out of scope. If you were depending on that effect persisting, you must hold the `OptimisticTransaction` reference somewhere with the lifetime you want (a view-model property, a session-scoped collection, etc.).

## [0.9.1] — Entity replay-after-normalize (closes the entity-axis race)

Fixes a race where a server-response `normalize` could silently clobber a concurrent optimistic layer's field patch. Symmetric counterpart to the connection-side replay that's been in place since v0.4 — connection canonicals were already protected (`OptimisticReplayer.replay(connectionKeys:)` runs from `Canonical.updateConnection`), but entities had no equivalent hook.

### The bug

Two concurrent mutations patching different fields of the same entity:

```
T=0    tx1 patches Clip:c1.captionsEnabled = true.  Graph: {captionsEnabled: true, volume: 1.0}
T=100  tx2 patches Clip:c1.volume = 0.5.            Graph: {captionsEnabled: true, volume: 0.5}
T=300  Server response 1 lands. Returns full ClipFields including volume: 1.0
       (server didn't know about tx2 yet). `documents.normalize` shallow-merges
       — volume = 0.5 silently clobbered → 1.0.
T=305  tx1.dispose() — doesn't touch graph.        Graph: {volume: 1.0}  ← bug
T=500  Server response 2 lands with volume: 0.5.    Graph: {volume: 0.5}
```

User sees the volume slider snap to 1.0 then back to 0.5 — UI flicker, optimistic patch silently lost.

### The fix

`Documents.normalize` now tracks entity keys it writes during the walk and calls `replayer.replayEntityOps(scope:)` after the walk completes. Pending optimistic layers' entity ops re-apply over the server-normalized graph state, in layer-id order, scoped to records the normalize actually touched.

New API surface (internal-ish — most consumers don't touch this directly):
- `Optimistic.replayEntityOps(scope: Set<CacheKey>)` — public method, mirrors the existing `replay(connectionKeys:)`.
- `OptimisticReplayer.replayEntityOps(scope:)` — protocol method (was previously just `replay(connectionKeys:)`).
- `Documents.setReplayer(_:)` — injection point, wired automatically from `CachebayClient.init`.

After the fix, the same timeline becomes:

```
T=0    tx1: captionsEnabled = true.
T=100  tx2: volume = 0.5.
T=300  Server response 1: normalize → {volume: 1.0}.
       replayEntityOps(scope: {"Clip:c1"}) → tx2's op (volume=0.5) re-applies.
       Graph: {captionsEnabled: true, volume: 0.5}   ← no clobber, no flicker
T=305  tx1.dispose(). Graph unchanged.
T=500  Server response 2: normalize → {volume: 0.5}. Replay no-op.
```

### What's protected (symmetric with connection-side replay)

- Mutation responses (`executeMutation`).
- Subscription frames (`executeSubscription` — auto-normalize per frame).
- Query refreshes (`executeQuery` cache-and-network path).
- Explicit `writeFragment` calls (anything that funnels through `documents.normalize`).

A layer's recorded entity op survives any subsequent normalize until the layer is committed, reverted, or disposed via its lifecycle method. Server data wins on UNpatched fields; pending optimistic patches win on patched fields. Latest-id layer wins on per-field conflicts between layers.

### Tests

New file: [`OptimisticReplayAfterNormalizeTests`](./Tests/CachebayTests/Runtime/OptimisticReplayAfterNormalizeTests.swift) — 10 contract tests covering:

- The core race (mutation response clobbers pending entity field patch).
- Scoping (replay runs only for entities the normalize touched).
- Layer-id ordering (latest layer wins on per-field conflicts between layers).
- Multi-field merge (server wins on UNpatched fields; layer wins on patched fields).
- Multi-entity normalize (replay runs per entity, not just the first).
- No-pending-layers baseline (replay hook is free when no layers exist).
- **Subscription frames trigger replay** — single-frame and multi-frame scenarios. Subscriptions are the most race-prone path (originally motivated v0.7.0's chat-pipeline fix); this is where the protection matters most.
- `.replace`-mode entity ops survive replay (fields not in the patch stay dropped after server normalize).
- Mixed entity + connection ops in one normalize (both entity-replay AND connection-replay fire, no interference).

655/655 tests green (was 645; +10 new).

### Internal performance

- Added pre-lock fast path to `Optimistic.replayEntityOps(scope:)` and `Optimistic.replay(connectionKeys:)`. Both are called from `documents.normalize` / `canonical.updateConnection` on every server-response merge — that's the runtime's hottest path. An unsynchronized `Array.isEmpty` read short-circuits when no layers are pending, making the no-pending-layers case truly free (one branch, no lock acquisition, no array sort). False-negative race window is benign: a layer added concurrently with the check just gets its replay deferred to the next normalize.

### Migration

None. Fully internal behavior change. Consumers don't see new API surface unless they were implementing custom `OptimisticReplayer` conformances (none in practice — protocol exists only for the `Optimistic ↔ Canonical` decoupling).

### Performance

The replay walk is O(layers × layer-ops × scope-hits). At typical optimistic depths (1-5 pending layers, 1-3 ops each) the walk is microseconds. The scope check (`Set<CacheKey>.contains`) is O(1). Won't show up in profiles for normal use.

For high-stacking flows (>50 pending layers — uncommon), consider committing or disposing layers eagerly. Stacking is itself a Cachebay perf anti-pattern; this fix doesn't change that.

## [0.9.0] — Explicit storage warmup

Replaces the fire-and-forget background hydration that ran inside `CachebayClient.init` with an explicit, synchronous `client.warmup()` method. Callers control when (and on which thread) the SQLite read happens — no hidden Tasks, no race window between client construction and the first query.

The motivation: the hidden auto-warmup made it impossible to *guarantee* the in-memory graph was hydrated before queries fired. A query issued in `App.init` would race the background load and fall through to the network even when the data was already on disk. Making warmup explicit eliminates the race by construction — the consumer decides when the graph is ready.

### Breaking — `CachebayClient.init` no longer hydrates in the background

```swift
// Before (v0.8.x):
let client = CachebayClient(options: options)
// ↑ fired off Task { await storage.load(); … } — races first queries

// After (v0.9.0):
let client = CachebayClient(options: options)
// ↑ in-memory graph is empty until you call:
client.warmup()                                   // sync (~10-300 ms)
// or
Task.detached(priority: .userInitiated) {
    client.warmup()                               // background, fire-and-forget
}
// or
await Task.detached(priority: .userInitiated) {
    client.warmup()                               // explicit await
}.value
```

`warmup()` is **synchronous on the calling thread** — wrap it in a `Task` if you want async semantics. iOS launch-time recipe: call it directly from `App.init` (cost is bounded, fits inside the launch screen) or `await` it inside your existing auth/bootstrap async flow.

### Added
- **`CachebayClient.warmup()`** — public sync method. No-op when no storage adapter is configured. Idempotent (safe to call multiple times). Gap-fill semantics: never overwrites records already in the in-memory graph (live network data beats disk on conflict).
- **`StorageAdapter.loadSync()`** — protocol method for adapters to expose a synchronous bulk read. SQLite implementation runs on the worker queue via `queue.sync` so the load serializes against any pending writes.

### Removed
- Auto-async-warmup `Task { await storage.load(); … }` from `CachebayClient.init`. Storage-backed clients now require an explicit `warmup()` call.

### Migration

One line per app, typically inside your existing async bootstrap:

```swift
// In your AuthViewModel.bootstrap (or equivalent first-screen entry point):
func bootstrap() async {
    await Task.detached(priority: .userInitiated) {
        CachebayService.client.warmup()   // ← add this
    }.value
    // … existing auth / first-query flow …
}
```

Or, if you want to block App.init for the load (acceptable for caches under ~10K records — see perf numbers below):

```swift
@main
struct MyApp: App {
    init() {
        _ = CachebayService.client       // existing
        CachebayService.client.warmup()  // ← add this
    }
    // …
}
```

### Performance — measured warmup latency across realistic cache sizes

New `StorageWarmupTests.test_perf_sqlite_warmup_acrossTiers` benchmarks bulk warmup at three tiers (Apple Silicon, release mode):

| Tier | Records | Wall clock (median) | Per-record |
|---|---|---|---|
| Small  | 500    | 15 ms     | 30 µs |
| Medium | 5 000  | 148 ms    | 30 µs |
| Large  | 50 000 | 1 490 ms  | 30 µs |

Linear scaling — SQLite open + prepared-stmt overhead amortizes fully across record count. For typical app caches (~3-10K records) warmup is invisible inside the iOS launch screen. 50K+ caches feel the cost; offer a Task-wrapped warmup with a "loading" splash UI, or batch-warm during idle frames.

Sanity-check assertions in CI: small <200ms, medium <1.5s, large <10s. Regressions break the suite.

### Tests
- New file: [`StorageWarmupTests`](./Tests/CachebayTests/Storage/StorageWarmupTests.swift) — 6 contract tests + 1 perf benchmark.
- Migrated: `SQLiteStorageTests.test_client_persists_and_reloads` — was using `Task.sleep(100ms)` to wait for the auto-warmup; now calls `client2.warmup()` explicitly.
- `RecorderStorage` / `RecordingStorage` test mocks gained `loadSync()` conformance.

645/645 tests green deterministically.

## [0.8.0] — Split-closure `modifyOptimistic`

Replaces the dual-phase `(b, ctx) -> Void` builder with **two separate closures**: one for optimistic ops, one for commit ops. Typed server data flows into the commit closure via ordinary Swift closure capture from outer scope — no more `ctx.data: JSONValue?` plumbing, no manual `case .object(let raw) = ctx.data ?? .null` unwrap, no generic `commit<O: OperationData>(_:)` overload, no `BuilderContext` / `BuilderPhase` types.

Motivated by the `ChatMutations.sendMessage` callsite in ferment-cuts-ios where the manual JSON-walk to recover typed `SendProjectMessage.Data` from `ctx.data` was both verbose and error-prone. The author flagged it inline ("Worth flagging upstream"); this is the upstream fix.

### Breaking — API rename + signature change

```swift
// Before (v0.7.x):
let tx = client.modifyOptimistic { b, ctx in
    switch ctx.phase {
    case .optimistic:
        b.patch(.key("Post:tmp"), [...], mode: .merge)
    case .commit:
        // Manual ctx.data unwrap — typed Data not visible.
        guard case .object(let raw) = ctx.data ?? .null,
              let payload = SendProjectMessage.Data(__data: raw).sendProjectMessage
        else { return }
        b.patch(.key("Post:\(payload.id)"), [...], mode: .merge)
    }
}
tx.commit(.object(serverData))   // or tx.commit(typedData) typed extension

// After (v0.8.0):
let tx = client.modifyOptimistic { b in
    b.patch(.key("Post:tmp"), [...], mode: .merge)
}
let response = try await client.executeMutation(...)
tx.commit { b in
    // `response` captured directly from outer scope — fully typed,
    // no JSONValue, no generic, no ctx.
    if let payload = response.data?.sendProjectMessage {
        b.patch(.key("Post:\(payload.id)"), [...], mode: .merge)
    }
}
```

**Removed:**
- `BuilderContext` and `BuilderPhase` types — the closure no longer needs them.
- `OptimisticTransaction.commit(_ data: JSONValue?)` — replaced by `commit(_ build: (OptimisticBuilder) -> Void)`.
- `OptimisticTransaction.commit<O: OperationData>(_:)` typed extension — replaced by capturing typed data in the new commit closure's outer scope.

**Changed:**
- `OptimisticBuilder` closure shape: `(b: OptimisticBuilder, ctx: BuilderContext) -> Void` → `(b: OptimisticBuilder) -> Void`.
- `Optimistic.applyAutoCommit` likewise takes a single-arg closure.
- `OptimisticTransaction.commit` now takes a builder closure; `revert()` and `dispose()` are unchanged.

### Migration

Three mechanical patterns cover the bulk of consumer code:

| Before | After |
|---|---|
| `{ b, _ in … }` | `{ b in … }` |
| `{ b, ctx in switch ctx.phase { … } }` | Two separate closures — split the cases |
| `tx.commit(nil)` | `tx.dispose()` (locks optimistic ops in — same net effect) |
| `tx.commit(.object(data))` / `tx.commit(typedData)` | `tx.commit { b in … }` capturing the data from outer scope |
| `tx.commit { _ in }` | `tx.revert()` (semantically equivalent: drop layer + restore baseline + run nothing) |

For deferred / temp-id-swap flows the migration is non-mechanical — see "Optimistic create flow" in [`Docs/OPTIMISTIC_UPDATES.md`](./Docs/OPTIMISTIC_UPDATES.md) for the full pattern.

### Why split-closure beats `(b, ctx)`

The dual-phase model conflated two distinct concerns. Splitting them:

1. **No `JSONValue?` plumbing.** Typed server data is captured via Swift closure semantics, not boxed into a generic JSON value and re-unwrapped per callsite.
2. **No `phase` switch.** Each closure does one thing; the optimistic-vs-commit branching that lived in user code is gone.
3. **No generic over operation/data type on `modifyOptimistic`.** The library doesn't need to know what type the commit closure uses — that's a pure user-side concern in the closure body.
4. **Multiple operations in one transaction work cleanly.** A commit closure can handle two await results from outer scope; the old `commit<O: OperationData>(_:)` could only carry one type.
5. **A whole class of bugs structurally disappears.** The dual-phase model encouraged "I forgot to guard with `if ctx.phase == .optimistic` and the optimistic ops accidentally re-ran on commit" mistakes. Split closures make this impossible.

### Smaller behavior fix in this release
- `applyAutoCommit` was previously documented as "runs the closure once at `.commit` phase". With the rename it's literally "runs the closure once" — same effect, simpler description.

### Tests
- New file: [`OptimisticSplitClosuresTests`](./Tests/CachebayTests/Runtime/OptimisticSplitClosuresTests.swift) — 8 contract tests pinning the split-closure semantics (closure-runs-once, recorded-ops-replay-on-sibling-commit, commit-closure-captures-from-outer-scope, dispose-vs-revert-vs-commit asymmetry, temp-id swap end-to-end).
- Removed: `OptimisticTypedCommitTests` — entire file tested the removed `commit<O: OperationData>(_:)` overload.
- Removed: `test_commit_restoresPreOptimisticBaseline_wipingServerUpdates` from `OptimisticDisposeTests` — pinned a bug-mode that existed only in the old `commit(nil)`-replays-the-closure model. With explicit commit closures the bug is structurally impossible.
- Migrated: `OptimisticTwoCycleTests` — was testing dual-phase replay; now tests split-closure equivalent (temp-id swap, edge-meta update across phases).

638/638 tests green deterministically.

## [0.7.0] — Connections ≠ entity store

This release reframes connection mutations as **purely structural** — they manage edges and pageInfo, never entity scalars. The motivation is closing a class of "stale-payload replay clobbers later normalize state" races (see [`OptimisticLinkNodeContractTests`](./Tests/CachebayTests/Runtime/OptimisticLinkNodeContractTests.swift) and the `chatMessageCreated`/`chatMessageUpdated` racing scenario from production). Two stores, two APIs:

- **Entity records** (`Post:p1`, `User:u1`, …) — owned by `documents.normalize` (auto from queries / mutations / subscriptions) or by explicit `b.writeFragment` / `b.patch` / `b.delete`.
- **Connection structure** (edge refs, edge meta, pageInfo) — owned by `b.connection(...).linkNode/unlinkNode/patch`.

### Breaking — API rename + signature change
- **`addNode` → `linkNode`**, **`removeNode` → `unlinkNode`**. The verb names the action precisely; the old name implied "add a node" which encouraged conflating entity creation with connection insertion.
- **`AddNodeOptions` → `LinkNodeOptions`**. Drops `fragmentDocument` / `fragmentName` / `fragmentVariables` fields — the plan-aware path is gone (see below).
- **The raw entry point now takes `EntityRef`, not `[String: JSONValue]`**:
  ```swift
  // Before:
  func addNode(_ node: [String: JSONValue], options: AddNodeOptions)
  // After:
  func linkNode(_ ref: EntityRef, options: LinkNodeOptions)
  ```
  Migrate dict callers via `linkNode(.object(dict), options:)` or `linkNode(.key("Post:p1"), options:)`. The signature itself enforces the contract: there is no scalar parameter that *could* leak onto the entity record.
- **Typed overloads collapsed to three:**
  ```swift
  func linkNode<N: OperationData>(node: N, options: LinkNodeOptions = .init())
  func linkNode<F: Fragment, ID>(fragment: F.Type, id: ID, options: LinkNodeOptions = .init())
  func unlinkNode<F: Fragment, ID>(fragment: F.Type, id: ID)
  ```
  The deleted overloads were `addNode<N, F>(node:fragment:options:)`, `addNode<F>(node:F.Data,fragment:...)`, and `addNode<F>(fragment:options:build:)` (the closure-builder draft form). Optimistic-create flows that used these now do two explicit calls — `b.writeFragment(fragment:id:data:)` then `b.connection(...).linkNode(fragment:id:)`. Cleaner separation, harder to misuse.
- **`Optimistic.ReplayResult` field rename**: `.added` → `.linked`, `.removed` → `.unlinked`. Internal `ConnectionOpKind.addNode/removeNode` likewise renamed.

### Breaking — behavior change
- **`linkNode` no longer writes entity-record scalars.** Previously, `addNode(node, fragment:)` shallow-merged scalar fields from `node` into the entity record. That broke under concurrent-writer scenarios:
  1. Subscription `chatMessageCreated` lands → `documents.normalize` writes entity (`status: streaming, toolCalls: null`).
  2. Subscription `chatMessageUpdated` lands ~6 ms later → normalize merges (`status: complete, toolCalls: [...]`).
  3. The user's deferred `Created`-handler runs `addNode(stale_msg, fragment:)` — the merged scalars from step 1 silently revert step 2's state.
  In the new design, step 3 takes an `EntityRef` only and cannot clobber. Tests covering the race are in [`OptimisticLinkNodeContractTests`](./Tests/CachebayTests/Runtime/OptimisticLinkNodeContractTests.swift).
- **Plan-aware fragment-walk helpers deleted**: `stampTypenameFromPlan`, `stripSelectionSetFields`, `isEntityShaped`, `initializeNestedConnections`. Nested `@connection` canonicals are now initialized by `documents.normalize` (via `b.writeFragment`), not by `linkNode`.

### Migration

For most callers the change is mechanical:

```swift
// Before — composite addNode that wrote entity scalars + linked
b.connection(key).addNode(node: msg, fragment: ProjectMessageFields.self,
                          options: AddNodeOptions(position: .start))

// After (case A: entity is already in cache from a server response)
b.connection(key).linkNode(node: msg, options: LinkNodeOptions(position: .start))

// After (case B: optimistic-create — ensure entity exists first)
b.writeFragment(fragment: PostFields.self, id: tempId, data: draft)
b.connection(key).linkNode(fragment: PostFields.self, id: tempId,
                            options: LinkNodeOptions(position: .start))
```

For `removeNode → unlinkNode`: pure rename.

### Fixed — concurrency bugs uncovered while landing the rename

- **`Graph.flush` short-circuit dropped fanouts under concurrent writers.** When two threads' flushes overlapped, the second saw `isFlushing == true` and returned early — but the records its writer added to `pending` weren't drained until the next external flush. Watchers depending on those records never saw an emit. Fix: the running flush thread now **loops until pending is empty**, so writes that landed during its own handler call are fanned out before exit. ([`ConcurrencyStressTests.test_watcher_never_drops_final_state_under_burst`](./Tests/CachebayTests/Stress/ConcurrencyStressTests.swift))
- **`MaterializeContext.readEntity` produced inconsistent `(record, version)` snapshots.** `graph.getRecord` and `graph.version` were two separate locked calls, so a writer could slip a write between them — yielding a `(stale-record, newer-version)` tuple. A subsequent materialize at the *same version* (with the actual newer record) would then version-collide with the stale one, `recycleSnapshots` would short-circuit them as equal, and the watcher would silently drop the emit. Fix: new `Graph.recordAndVersion(_:)` returns both under one lock acquisition; `readEntity` uses that snapshot for both the record contents and the fingerprint version.
- **Removed `notifyDataBySignature` from `executeMutation`.** That path delivered a *pre-materialized* snapshot to watchers based on signature match, but the snapshot was captured between the mutation's normalize and its notify call — under concurrency, two mutations could race their pre-materialized snapshots and the older one could land last. The dep-fanout (triggered synchronously by `graph.flush()` inside `materialize`) already covers watcher delivery and re-materializes at notify time, so it always reflects the latest graph state. Net effect: simpler, race-free.

### Performance / dev-loop
- **Stress test rewritten with a programmatic deadline** instead of a fixed `Task.sleep(50ms)`. A failing run now terminates within 1 s with a deterministic error; the happy path resolves in a single poll (~ms).

### Memo to consumers
- The chat-pipeline workaround pattern (`writeFragment` defensive call inside a subscription Updated handler) can be removed once a project upgrades to v0.7.0 — the structural-only `linkNode` makes the underlying race impossible by construction. Audit your subscription handlers for the pattern and simplify.

## [0.6.0] — Pure-fragment-spread reuse in codegen

## [0.6.0] — Pure-fragment-spread reuse in codegen

### Added
- **Codegen detects pure fragment spreads and reuses the fragment's emitted `Data` type at the parent position**, instead of emitting a structurally-identical fresh nested struct per query that spreads it. When a field's selection set is exactly `{ ...FragmentName }` (with no extra fields beyond the spread; user-written `__typename` is tolerated), the parent's typed accessor returns `[FragmentName.Data]` / `FragmentName.Data?` directly.

  ```swift
  // Before:
  public struct ProjectFields {
      public struct Data {
          public struct Elements: OperationData { … 460 lines of duplicate Element machinery … }
          public var elements: [Elements] { … }
      }
  }

  // After:
  public struct ProjectFields {
      public struct Data {
          public var elements: [ElementFields.Data] { … }
      }
  }
  ```

  The duplicate `AsVideoElement` / `AsAudioElement` / `AsImageElement` accessor trees and the duplicate factory methods at every parent position collapse to a single canonical site. Concretely in the `ferment-cuts-ios` consumer: `UserMessageFields.cachebay.swift` shrank from **1023 lines to 460** (-55%); `ProjectFields.cachebay.swift` shrank similarly. Every consumer-side converter that took `Project.Data.Project.Elements` *or* `UserMessageFields.Data.Attachments` *or* `ElementFields.Data` (three identical types) is now a single converter taking `ElementFields.Data`. **Polymorphic helpers across queries become possible** — a function that wants an Element from chat OR from a project query takes the same typed argument.

### Detection rule
- The position's selection set must contain exactly one `FragmentSpread` and zero other selections (Field / InlineFragment), with `__typename` field selections at the parent scope tolerated since cachebay auto-injects them anyway.
- Multiple spreads on the same position, inline fragments at the parent scope, or any extra named field at the parent scope → fall back to the v0.5.0 "fresh nested struct + factories" behavior. Detection happens against the AST before lowering; once selections are merged, the property is irrecoverable.

### Migration
- **Source-breaking** for consumers who explicitly named the per-position type (e.g. `Project.Data.Project.Elements` → no longer exists, use `[ElementFields.Data]`). Callers using `for el in project.elements` without naming the element type are transparent. In `ferment-cuts-ios` this was ~10 sites; bulk-replace with `perl -pi -e` and the build catches the rest.
- **Rerun `cachebay-cli` codegen** to pick up the dedup. v0.5.0 factories on per-position structs disappear for fields that now reuse the fragment type — call `FragmentName.Data.<subtype>(...)` from the canonical site.

### Precedent
- Relay-compiler reuses fragment data types directly at pure-spread positions; Apollo iOS solves the same problem via per-fragment protocol conformance. Cachebay matches Relay's simpler approach: the fragment's `Data` IS the reused type at every spread site.

## [0.5.0] — Compile-time fragment data factories

### Added
- **Codegen-emitted static factories on every generated `Data` / `AsX` struct.** Polymorphic fragments emit one factory per type-condition (`ProjectMessageFields.Data.projectUserMessage(...)`, `ElementFields.Data.videoElement(...)`); plain fragments emit a single `Data.make(...)`. Every selected non-null field is a required named parameter; nullable selections get `= nil` defaults. `__typename` is hardcoded into the dict body so callers never thread a typename string. Forgetting a required field is a compile error at the call site, replacing the v0.4.0 silent-watcher-silence failure mode where a missing selection-set field would only surface as a debug-level "no field" log at runtime.

  ```swift
  let element = ElementFields.Data.videoElement(
      id: att.id, kind: "video", state: "draft", intent: "STORY",
      name: att.name, derivatives: [], lockVersion: 1,
      colorSpace: v.colorSpace,
      music: 0, speech: 1, noise: 0,
      beatsAnalyzed: false, musicHighlighted: false, speechTranscribed: false,
      beats: [], downbeats: [], quantizedBeats: [], quantizedDownbeats: [],
      musicHighlights: []
      // duration, width, height, rotation, aiPrompt, content, … all optional, default nil
  )
  ```

  Mirroring `AsX` factories also emit at the subtype-struct level (`AsVideoElement.make(...)`) for callers who already have an `AsX` and want a sibling.

  At parent scope, subtype-specific nested types are qualified with `AsX.` (e.g. `[AsAudioElement.MusicHighlights]`) so they resolve outside the subtype struct. Shared nested types stay unqualified — they live as siblings on the parent.

### Migration
- **Rerun `cachebay-cli` codegen** to pick up the new factories. Existing `F.Data(__data: [...])` call sites continue to compile; opt-in to the typed factories one call site at a time.

## [0.4.0] — Optimistic `writeFragment` (normalize-with-baselines)

### Added
- **`OptimisticBuilder.writeFragment(...)`** — plan-aware optimistic write that walks the fragment plan + data, captures baselines for every entity record it touches, and normalizes nested entities (single + list) into separate cache records linked by `.ref` / `.refList`. Mirrors `CachebayClient.writeFragment` but goes through the optimistic layer — `revert()` / `dispose()` work, layered commit replays surviving siblings correctly. Use for OPTIMISTIC CREATE flows where a fresh entity tree is built client-side (e.g. an outbound chat message + its attachments). The strict materializer requires `.ref` / `.refList` for selection-set link fields, so embedded objects (`.array of .object`) silence the watcher with "unexpected link shape" — `writeFragment` produces the right shape automatically.

  ```swift
  client.modifyOptimistic { b, _ in
      b.writeFragment(fragment: ProjectMessageFields.self, id: userId, data: messageData)
  }
  ```

  Exposed in two forms: a JSON-shaped primitive on the protocol (`document:fragmentName:rootId:variables:data:`), and typed extensions in `Optimistic+Typed.swift` (`fragment:id:[variables:]data:`). The variable-less overload covers fragments with `Variables == EmptyVariables`.

### Limitation
- Only entity-shaped records (objects with `__typename + id`) get baselines captured. Inline-container synthetic keys (e.g. `Element:42.derivatives.0`) write into the graph but aren't tracked for revert. For fresh-create flows this is harmless (no prior state to restore); flows that optimistically MUTATE pre-existing inline containers should stay on `b.patch(...)`.

### Internals
- `Optimistic.init(graph:planner:documents:)` now takes the `Documents` engine so the optimistic layer can route writes through `documents.normalize` while injecting baseline captures. Pre-1.0 internal-only signature change; `CachebayClient.init` is the only caller.

## [0.3.3] — Stable codegen source paths

### Fixed
- **Generated `// Source:` and `/// Fragment X:` headers now use paths relative to `--operations`** instead of absolute paths into the caller's staging tempdir. Wrappers (e.g. `ferment-cuts-ios`'s `Scripts/cachebay-codegen`) typically copy operations into a randomized `/var/folders/.../cachebay-codegen-XXXXXX.<random>/` tree before invoking the cli; embedding that path in every emitted file caused two problems: (a) leaked the host's tempdir layout into checked-in code, and (b) churned every generated file's diff on every codegen run as the random suffix changed. Now an emitted header reads `// Source: Fragments/ProjectFragment.graphql` regardless of where the cli was invoked from. Path resolution canonicalizes both the operations roots and each file before stripping the prefix, so symlinks (e.g. macOS `/var` → `/private/var`) don't defeat the match.

## [0.3.2] — Reconnector resurrection race; test-seam handshake; CI perf threshold

### Fixed
- **`startReconnector` could resurrect after `.stopped`.** Race window: a delayed `receiveLoopError` from a now-dead socket can land in `handleUnexpectedDisconnect` after `stopWithTerminalReason` has nulled `reconnectorTask` and flipped state to `.stopped`. The disconnect path's `startReconnector` call only checked `reconnectorTask != nil`, not state — so it would spawn a fresh reconnector and emit one bonus `.reconnectScheduled(attempt: 1, ...)` past the terminal `.stopped` event. `test_reconnect_emitsReconnectScheduledEvents_withGrowingDelays` flaked at ~30–60% on macOS runners. Fixed by guarding `startReconnector` against `.stopped` state — public `reconnect()` paths resurrect state out of `.stopped` before calling, so they're not blocked. Pre-existing bug; deterministic across 30/30 stress runs after fix.
- **`takeConnectionState` opened a real WebSocket task even when test seams were active.** `test_subscribeDuringConnecting_doesNotDoubleSubscribeOnAck` would race the real (failing) handshake against the test's injected `connection_ack` and pass locally / fail on slower CI runners. Added `.testSeamConnect` decision: when an outbound sink is installed, drive the handshake through the sink without opening a real socket.

### Tests
- `test_perf_addNode_preload_5000_tail_latency` p99/p50 ratio threshold raised from 5× to 10×. Local M-series runners land at ~1.3×; GitHub-hosted macos-15 shared hardware routinely hits 4–6× under noisy-neighbour load. 10× still catches pathological regressions (e.g. an O(n²) regression that would push the ratio past 20×).

## [0.3.1] — Operation-projection `nodes()` overload

### Added
- **`Sequence.nodes()` / `Optional<Sequence>.nodes()`** — operation-projection variant of `nodes(as:)`. Unwraps each edge's `node` into the operation-specific `Element.Node` type without any fragment cast. Use when call sites keep operation-typed helpers downstream (e.g. a `posterFromCachebay(_: Projects.Data.Projects.Edges.Node.Poster)` helper would break under `nodes(as: ProjectFields.self)` because the cast crosses the projection seam — `nodes()` preserves the type). The two overloads coexist: `.nodes()` for operation projection, `.nodes(as: F.self)` for fragment view.

## [0.3.0] — Typed connection-edge sugar

### Added
- **`ConnectionEdge` protocol + `Sequence.nodes(as:)` / `Optional<Sequence>.nodes(as:)` sugar.** Replaces the rote `edges?.compactMap { $0.node?.as(F.self) } ?? []` with `edges.nodes(as: F.self)`. The fragment cast stays explicit (`as: F.self`) — only the compactMap boilerplate disappears. `cachebay-cli` automatically emits the `: Cachebay.ConnectionEdge` conformance on every generated edge struct (any nested struct with a `node: Node?` shared child of object shape), so consumers don't write any conformance themselves. Marker-only protocol; no runtime cost.

### Migration
- **Rerun `cachebay-cli` codegen** to pick up the new `: Cachebay.ConnectionEdge` conformance on emitted `Edges` structs. Existing call sites continue to compile unchanged; opt-in to the sugar one connection at a time.

## [0.2.1] — WebSocket reliability hardening

### Added
- **`updateConnectionParams(_:reconnectIfConnected:)`** — replace the params payload sent in `connection_init`. Use for auth-token rotation (refresh-token flow, account switch, role change) without manually wrangling `disconnect()` → reset → `reconnect()`. With `reconnectIfConnected: true`, drops the live socket and re-handshakes immediately, replaying every `.subscribed` subscription after the new ack. With `false`, the params are stashed and take effect on the next natural reconnect. Inspired by Apollo iOS's `updateConnectingPayload(_:reconnectIfConnected:)`.
- **Optional client-initiated ping/pong** (`URLSessionWebSocketTransport(pingInterval:)`). Disabled by default. When set, the transport sends a `{"type":"ping"}` frame at the configured cadence after `connection_ack` lands, and answers any server-initiated `{"type":"ping"}` with `{"type":"pong"}`. Required for long-idle subscriptions behind NAT (typical NAT timeout 60–120s) or proxies with idle-disconnect policies. The ping Task uses the injected `clock`, so tests can drive cadence with `FakeClock` deterministically.

### Changed
- **Default WS connect timeout shortened to 10s** (`URLSessionWebSocketTransport.defaultConnectTimeout`). Previously the transport used `URLSession.shared`, which carries `timeoutIntervalForRequest = 60`. During a server-restart window, the dominant failure mode is "TCP handshake succeeded, WS upgrade stalled" — a 60s default would eat the entire backoff schedule on the first half-connected attempt. 10s is greater than `ReconnectPolicy.default.maxDelay` (5s) so each backoff cycle gets a full attempt, covers slow cold-start servers (k8s/fly.io 3–7s p95), and aligns with AWS/Cloudflare/Slack norms.
- Callers who pass their own `URLSession` are unaffected — cachebay no longer reads from `.shared` and won't mutate a caller-supplied session.
- `connectionParams` is now a snapshotting computed property (read-only). Mutate via `updateConnectionParams(_:reconnectIfConnected:)`. **Pre-1.0 breaking** for anyone who was assigning `transport.connectionParams = ...` directly (no callers in this repo or the Ferment Cuts consumer at the time of the change).

### Fixed
- **Duplicate `.disconnected` events per failed attempt.** A single physical socket failure typically trips both the send path (the `connection_init` write fails) and the receive-loop catch (the `task.receive()` await throws). The first teardown left state at `.connecting` when subs were pending (`then: nil` in `handleUnexpectedDisconnect`), so the second teardown's gate (`task == nil && isAlreadyTornDown(_state)`) didn't match — `.connecting` isn't "torn down" — and a duplicate event slipped through. Smoke logs from a real failed-handshake retry cycle showed `[WS] disconnected: receiveLoopError` immediately followed by `[WS] disconnected: sendError` per attempt. Now `handleUnexpectedDisconnect` always transitions to `.disconnected` after teardown; the reconnectorLoop overwrites to `.reconnecting(N)` on its next iteration. Brief flicker, correct dedupe.
- **Double `subscribe` frame when calling `subscribe()` mid-handshake.** If a caller invoked `subscribe()` while the transport was in `.connecting` (or `.reconnecting`) and `connection_ack` arrived after registration, two `subscribe` frames went out for the same id: one from the caller's own awaiting Task waking up, one from the connection_ack replay loop. Strict graphql-transport-ws servers reject the duplicate with close code 4409 "Subscriber for `<id>` already exists"; tolerant servers double-yielded events. Mirrors Apollo iOS's two-phase registry: subscriptions are now tagged `.pending` (registered, frame not on the wire) or `.subscribed` (frame sent, awaiting `next`/`error`/`complete`). The ack handler replays only `.subscribed` entries.

## [0.2.0] — WebSocket auto-reconnect

### Added
- **Auto-reconnect for `URLSessionWebSocketTransport`** — survives unexpected disconnects (server restart, network blip, app suspend/resume). Tears down the dead socket, schedules a retry with exponential backoff + jitter, replays every active subscription's `subscribe` after the new `connection_ack`. Subscribers' `for try await` loops keep yielding across the gap.
- `ReconnectPolicy` struct configures the backoff. Defaults: `0.5s → 1s → 2s → 4s → 5s → 5s …` (cap 5s, ±30% jitter, retries forever) — tight enough for real-time chat / live-update feeds. Presets: `.default`, `.disabled`, `.aggressive`.
- New `ConnectionState` cases: `.reconnecting(attempt:)`, `.stopped(reason:)` with `TerminalReason` (`.userClosed` / `.unauthorized(code:)` / `.maxAttemptsExceeded`).
- New `ConnectionEvent` cases: `.reconnectScheduled(attempt:delay:)`, `.stopped(reason:)`.
- `transport.reconnect()` — state-aware caller-driven reconnect:
  - `.connected` / `.connecting` → no-op
  - `.reconnecting(N)` → wakes the pending backoff sleep, attempts now (counter unchanged)
  - `.stopped(_)` → resurrects, replays subscriptions
  - `.disconnected` with pending subs → starts a fresh attempt now
  - Use from UI "Reconnect" buttons, `NWPathMonitor.pathUpdateHandler` on `.satisfied`, or `UIApplication.didBecomeActiveNotification` observers — spamming is safe.
- Permanent-failure detection — WS close code 4401/4403 → `.stopped(.unauthorized)`; reconnect won't retry until caller refreshes auth and calls `reconnect()`.
- Subscription registry that survives reconnect — the transport keeps `(query, variables, continuation)` per subscription and replays them after the new `connection_ack`.
- Injectable `clock: any Clock<Duration>` parameter on `URLSessionWebSocketTransport.init` (defaults to `ContinuousClock()`). Tests pass a `FakeClock` to drive backoff sleeps deterministically — reconnect tests run in milliseconds without burning real wall-clock seconds.
- `Tests/CachebayTests/Helpers/FakeClock.swift` — reference fake-clock impl with `advance(by:)` / `releaseAllPending()` / `waitForPendingSleepThenAdvance(by:)`.
- 6 new reconnect tests in `WebSocketReconnectTests.swift` — backoff math, disabled-policy fail-fast, no-op reconnect, disconnect→stopped→resurrect, exponential growth + jitter range with `FakeClock`, userClosed-vs-maxAttemptsExceeded distinction.
- `Docs/SUBSCRIPTIONS.md` "Auto-reconnect" + "Background lifecycle & reliability" sections — covers all five reliability scenarios (server restart, app foreground, network back, auth-expiry, explicit disconnect), copy-paste consumer wiring with `NWPathMonitor` + foreground observer, testing recipe with `FakeClock`, optimization rationale, known limitations (no ping/pong heartbeats, no connection-level backpressure).

### Changed (breaking)
- **Deployment targets bumped to iOS 16+ / macOS 13+ / tvOS 16+ / watchOS 9+** (visionOS unchanged at 1+). Required to use `Duration` / `Clock` / `Task.sleep(for:)` natively in the reconnect orchestrator and FakeClock test helper. iOS 15 consumers should pin to `v0.1.0`.

### Fixed
- Duplicate `disconnected` events emitted for the same physical disconnect (one from the send-error path, one from the receive-loop catch) — now collapsed via state-aware short-circuit in `teardown`.
- Race where `setState(.disconnected)` after a delayed `receiveLoop` cancellation could overwrite a `.stopped(_)` terminal state. `handleUnexpectedDisconnect` now no-ops when state is already `.stopped`.

## [0.1.0] — Initial public release

First public version. The library was developed and battle-tested as part of the Ferment Cuts iOS app before being extracted; coverage parity with cachebay-web is locked in by the suite (608 tests, all green).

### Added
- `OptimisticTransaction.dispose()` — drops the layer without restoring baselines or re-running the builder. Use when the server response is the authoritative state for touched records (most update mutations). Avoids the bug where `commit(...)`'s baseline restore wipes server-side fields the optimistic patch didn't touch.
- `client.modifyOptimistic(autoCommit: Bool, _:)` — single-phase variant. When `autoCommit: true`, the closure runs once at `.commit` phase against the base graph (no layer recorded, no double-write). Use for create-style mutations where you've already awaited the server response.
- `OptimisticTransaction.commit<O: OperationData>(_:)` — typed overload that wraps `data.__data` into the JSON shape the underlying closure expects.
- `addNode<N: OperationData, F: Fragment>(node:fragment:options:)` — plan-aware connection insert. Walks the fragment plan to (a) initialize nested `@connection` canonicals, (b) stamp `__typename` from `F.onTypename`, (c) strip selection-set fields from the entity-record patch (two-pass: plan-aware + shape-aware) so existing ref/refList links survive a merge.
- `ConnectionAPI.patch { prev in … }` — closure-form connection patch for read-modify-write on canonical scalars (parity with cachebay-web `c.patch(prev => ({...}))`).
- `Optimistic.replay(connectionKeys:) -> ReplayResult` — exposes `{added, removed}` entity sets from replayed layers (parity with cachebay-web `replayOptimistic`).
- Logger plumbing on `CachebayClient` for runtime diagnostics (materialize misses, watcher silencing).

### Changed
- Soft scalar materialize miss downgraded from `.warning` to `.debug` log level — was spamming Error-level lines for the harmless cursor-on-optimistic-edge case.
- `CachebayClient.{graph, planner, canonical, documents, queries, fragments, optimistic, operations}` properties now `internal` (still accessible from tests via `@testable`). Public surface narrowed to `inspect` + `storage` + the typed methods on the client itself. Reduces the SemVer-able surface.
- Removed unused `CachebayCodegen` library product and the `cachebay-cli` Swift executable stub from `Package.swift`. The actual codegen is the Rust binary in `cli/`.

### Tests
- Test suite cross-checks behavior with cachebay-web file-by-file: documents (normalize/materialize/rootId), operations (queries/mutations/subscriptions × cache policies × invalidation × watcher state), queries (watchers, refcount), optimistic (entity, connection, fragment-plan-aware, layering, two-phase commit), canonical (pagination/leader/edge cases/replay), compiler (planner/metadata/dedupe/operations/connections/formats/fragments), performance (render-count assertions), integration (typed-API doc routing, evictAll, connection watcher).
- 608 tests across the suite. CI runs on every PR via `.github/workflows/test.yml`.

[Unreleased]: https://github.com/lockvoid/cachebay-ios/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/lockvoid/cachebay-ios/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/lockvoid/cachebay-ios/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/lockvoid/cachebay-ios/compare/v0.3.3...v0.4.0
[0.3.3]: https://github.com/lockvoid/cachebay-ios/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/lockvoid/cachebay-ios/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/lockvoid/cachebay-ios/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/lockvoid/cachebay-ios/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/lockvoid/cachebay-ios/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/lockvoid/cachebay-ios/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/lockvoid/cachebay-ios/releases/tag/v0.1.0
