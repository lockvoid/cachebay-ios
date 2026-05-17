# Profiling

Cachebay ships a built-in profiler protocol so you can measure where cache time goes in your app — both the user-facing operations (mutations, queries, fragment reads/writes, optimistic updates) and the internal hot paths that compete for it (normalize, materialize, graph flush, watcher fanout, optimistic replay, storage warmup).

Profiling is **opt-in**. The default `CachebayClient` instantiation has no profiler attached; every instrumentation call site compiles to a single nil check, so there is no measurable overhead in shipped builds unless you wire one in.

## Quick start — Instruments timeline

```swift
import Cachebay

let client = CachebayClient(options: CachebayOptions(
    transport: Transport(http: URLSessionHTTPTransport(endpoint: api)),
    profiler: OSSignpostProfiler()         // ← that's it
))
```

Open `Instruments.app` → choose the **os_signpost** template → record your app. Filter the signpost track by subsystem `com.cachebay` (override at `OSSignpostProfiler` init time if your app has its own convention). Each Cachebay operation shows up as a signpost interval — drill in for attributes (plan ID, watcher count, replay scope size, etc.).

`OSSignpostProfiler` is essentially free when Instruments isn't recording: signposts compile to an `os_signpost_enabled` check the kernel answers without a syscall. Safe to leave in release builds.

## Custom backends

The full protocol is small:

```swift
public protocol CachebayProfiler: AnyObject, Sendable {
    func begin(_ name: StaticString) -> CachebayProfileSpan?
    func record(_ name: StaticString, value: Double)
    func record(_ name: StaticString, value: Double, attributes: [String: String])
}

public protocol CachebayProfileSpan: AnyObject, Sendable {
    func end()
    func attribute(_ key: StaticString, _ value: String)
    func pause()
    func resume()
}
```

Implement it to route into OpenTelemetry, Datadog RUM, Firebase Performance, a homegrown Prometheus exporter — whatever your telemetry pipeline is. Return `nil` from `begin(...)` when your backend isn't currently sampling and the call site will short-circuit on the `?.` chain.

## Host-callback exclusion (the "smart" part)

The contract Cachebay holds itself to: **time spent in your code is never counted against Cachebay's reported duration.** Your `modifyOptimistic` builder closure, your watcher's `onData` callback, your commit closure, your network transport's response — none of these appear inside a Cachebay span.

Two patterns achieve this:

### Pattern A — `excludingHost` around a host callback inside an open span

```swift
public func modifyOptimistic(_ builder: @Sendable (OptimisticBuilder) -> Void) -> OptimisticTransaction {
    let span = profiler?.begin("cachebay.modifyOptimistic")
    defer { span?.end() }
    // ... allocate layer, set up builder ...
    span.excludingHost { builder(b) }   // ← host code, paused
    graph.flush()
    return OptimisticTransaction(...)
}
```

`excludingHost` pauses the span before running the body and resumes after. The profiler implementation subtracts the paused interval from the reported total. In Instruments this shows as two adjacent signpost intervals with a gap — the gap is the excluded host time.

### Pattern B — span ends before a tail loop of host callbacks

```swift
public func notifyDataByDependencies(_ touched: Set<CacheKey>) {
    let span = profiler?.begin("cachebay.watchers.fanout")
    // ... materialize, diff, build emits list ...
    span?.attribute("watcherCount", "\(affected.count)")
    span?.end()
    for (cb, v) in emits { cb(v) }      // ← host code, outside any span
}
```

Pattern B is preferred when the host call is the tail of the operation. No pause/resume bookkeeping; the host's time simply lives outside the span by construction.

If you write a `CachebayProfiler` conformance, implement `pause()` / `resume()` honestly — your reported duration must subtract paused intervals. Tests in `CachebayProfilerTests.swift` enforce this contract for every instrumented call site.

## Span inventory

| Span name | Where | Notable attributes |
|---|---|---|
| `cachebay.modifyOptimistic` | Opening an optimistic layer | (builder closure paused) |
| `cachebay.applyAutoCommit` | `modifyOptimistic(autoCommit: true)` | (builder closure paused) |
| `cachebay.optimistic.replay.connection` | After connection-canonical merge, with pending layers | `layerCount`, `scopeSize` |
| `cachebay.optimistic.replay.entity` | After entity normalize, with pending layers | `scopeSize` |
| `cachebay.executeMutation` | `executeMutation` end-to-end | `planID` (network paused) |
| `cachebay.executeQuery` | `executeQuery` end-to-end | `planID`, `policy` (network paused) |
| `cachebay.executeSubscription.frame` | Per-frame of a subscription stream | `planID`, `result` |
| `cachebay.documents.normalize` | Server-response merge into the graph | — |
| `cachebay.documents.materialize` | Read/diff path | `source=cache` if hot |
| `cachebay.readFragment` | `client.readFragment(...)` | — |
| `cachebay.writeFragment` | `client.writeFragment(...)` | — |
| `cachebay.graph.flush` | `Graph.flush()` pending-set drain | (handler invocation paused) |
| `cachebay.watchers.fanout` | Watcher dep-fanout (Queries + Fragments) | `watcherCount`, `emittedCount`, `kind` |
| `cachebay.storage.warmup` | `client.warmup()` | `recordCount` (disk load paused) |

### Counter events (not durations)

| Event name | Where | Value |
|---|---|---|
| `cachebay.watchers.emitted` | After a fanout fires any callbacks | Number of watchers emitted to |

Spans nest naturally in OS Signpost timelines via parent/child signpost IDs (Instruments displays them as a tree). For custom backends you can either treat each span independently or use the `StaticString` names to reconstruct parent/child relationships from name patterns (`cachebay.executeMutation` → `cachebay.documents.normalize` → `cachebay.graph.flush` → `cachebay.watchers.fanout` is the canonical post-mutation chain).

## What's deliberately NOT instrumented

- **Per-watcher materialize inside a fanout loop.** A burst of 50 watchers would emit 50 spans per fanout, drowning out the spans you actually care about. The `watcherCount` attribute on `cachebay.watchers.fanout` gives you the cost per watcher implicitly (total span time / count); if you need per-watcher signals, implement a custom `CachebayProfiler` that filters by `watcherCount > N`.
- **Storage flush / disk I/O.** The storage adapter is pluggable — instrumenting `SQLiteStorage.flush` would push the profiler protocol into the storage interface, which isn't worth it. If you care about storage timing, wrap your adapter implementation.
- **Network transport.** Same reasoning. `executeMutation` / `executeQuery` mark the network round-trip as paused so it's excluded from Cachebay's reported time, but if you want a separate "network" span, instrument your `HTTPTransport` directly — most are already wrappers around `URLSession`, which has its own Instruments support.

## Performance contract

- `profiler == nil` (the default): one nil check per call site, zero allocations, zero closure captures. Verified by the existing test suite running unchanged with profiler unset.
- `profiler != nil` but `begin(...)` returns nil (e.g., `OSSignpostProfiler` when Instruments isn't recording): one nil check on the returned span, zero work in span methods.
- `profiler != nil` and recording: span allocation per call (~1 retain), one method dispatch per `attribute` / `pause` / `resume` / `end`. Aggregated cost is in the low microseconds for typical Cachebay call patterns.
- The profiler is set at `CachebayClient.init` time and never changed. Subsystems hold their own non-mutating reference; no atomic loads on the hot path.
