import Foundation
import os

// MARK: - Concurrency model
//
// Cachebay is **lock-based**, not actor-based. Every subsystem owns a single
// `NSRecursiveLock`; all `Sendable` conformances are `@unchecked` and honest.
//
// ## Lock acquisition order (enforced by convention)
//
// Outer → inner, never the reverse. Subsystems at the same level never take
// each other's lock; they communicate via the Graph's `onChange` fanout which
// runs **outside** the Graph lock.
//
//     Queries.lock, Fragments.lock, Optimistic.lock, Operations.lock   ← "clients"
//                                  │
//                                  ▼
//                           Documents.lock                              ← "reader"
//                                  │
//                                  ▼
//                             Graph.lock                                ← "store"
//
// Rules enforced at every lock site:
//   1. Callbacks (`onData`, `onError`, storage writes) are always invoked
//      **after** releasing the owning subsystem's lock.
//   2. `Graph.flush()` drops `Graph.lock` before invoking `onChange`, so the
//      fanout (which acquires Queries/Fragments locks, which in turn acquire
//      Documents/Graph locks) can never deadlock against the writer.
//   3. Operations only holds its own lock for short, non-nested critical
//      sections (epoch bookkeeping, suspension window). It never calls into
//      Queries/Fragments/Documents while holding the Operations lock.
//
// ## Why not actors?
//
// Three reasons, in descending importance:
//   • **Synchronous reads.** `readQuery` / `readFragment` / graph access are
//     the hot path for UI; forcing `await` at every call site has a latency
//     and ergonomics cost out of proportion to its safety win.
//   • **Re-entrancy.** Several code paths legitimately re-enter the same
//     subsystem (e.g. a watcher's materialize triggers dep lookups that hit
//     the same cache). `NSRecursiveLock` handles this cleanly; actor re-entry
//     requires hop tokens and `nonisolated` escape hatches.
//   • **Callback boundaries.** Emitting to a `@Sendable` onData callback
//     outside the lock is a single line here; achieving the equivalent from
//     an actor requires detached tasks at every emission site.
//
// The stress tests under `Tests/CachebayTests/ConcurrencyStressTests.swift`
// validate this choice end-to-end.

/// Tiny Sendable boolean used to mark "currently applying a remote update to
/// the graph" so the `onChange` handler doesn't reflect those writes back to
/// storage.
private final class RemoteApplyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

/// Configuration for a `CachebayClient`. Construct once at app
/// startup; the client owns it for its lifetime.
///
/// - `transport`: HTTP + (optional) WS transports. Use the built-in
///   `URLSessionHTTPTransport` / `URLSessionWebSocketTransport`
///   unless you need custom auth or retry behavior.
/// - `cachePolicy`: default policy applied to every operation;
///   per-call `cachePolicy:` overrides this.
/// - `keys`: custom `KeyFunction`s for entities that don't use `id`
///   (or use a composite key). E.g. `["Tag": { obj in obj["slug"]?.string }]`.
/// - `interfaces`: registers concrete impls for a GraphQL interface
///   so variant fragments route to the canonical type.
/// - `suspensionTimeout`: window during which an in-flight or
///   recently-completed operation suppresses redundant network
///   fetches for the same signature.
/// - `storage`: optional persistent backend. When set, every graph
///   write replicates to disk; initial records load at client init.
/// - `logger`: optional `os.Logger` for runtime diagnostics
///   (materialize misses, watcher silencing, plan compile failures).
public struct CachebayOptions: Sendable {
    public var transport: Transport
    public var cachePolicy: CachePolicy
    public var keys: [String: KeyFunction]
    public var interfaces: [String: [String]]
    public var suspensionTimeout: TimeInterval
    /// Optional persistent storage. When set, every graph write is replicated to
    /// disk asynchronously, and initial records are loaded at client creation.
    public var storage: StorageAdapterFactory?
    /// Optional logger for runtime diagnostics. When set, Cachebay emits
    /// warnings for actionable cache problems — e.g. a watcher's materialize
    /// failing because an entity record exists but is missing a field its
    /// selection set requires (typical cause: a mutation's response shape
    /// is a subset of the consuming query's selection set, leaving the
    /// entity partially-populated for the watcher).
    public var logger: Logger?

    public init(
        transport: Transport,
        cachePolicy: CachePolicy = .cacheFirst,
        keys: [String: KeyFunction] = [:],
        interfaces: [String: [String]] = [:],
        suspensionTimeout: TimeInterval = 1.0,
        storage: StorageAdapterFactory? = nil,
        logger: Logger? = nil
    ) {
        self.transport = transport
        self.cachePolicy = cachePolicy
        self.keys = keys
        self.interfaces = interfaces
        self.suspensionTimeout = suspensionTimeout
        self.storage = storage
        self.logger = logger
    }
}

/// Primary cache instance. Framework-agnostic, `Sendable`, safe to share
/// across actors and threads (internal locks serialize state).
///
/// Construct with `CachebayClient(options:)`; reach the operation API
/// through methods like `executeQuery`, `watchQuery`, `executeMutation`,
/// `modifyOptimistic`, etc. Subsystems (`Documents`, `Queries`,
/// `Optimistic`, …) are internal — exposed to tests via `@testable`,
/// not to library consumers, so the public surface stays narrow and
/// SemVer-able.
public final class CachebayClient: @unchecked Sendable {
    /// Inspection helpers: `getRecord`, `getConnectionKeys`, etc.
    /// Public so callers can fan optimistic updates out across every
    /// matching connection canonical without hand-building keys.
    public let inspect: Inspect
    /// Persistent storage adapter (e.g. SQLite). `nil` when the client
    /// runs in-memory only. Public so callers can call lifecycle hooks
    /// like `dispose()` on shutdown.
    public let storage: StorageAdapter?

    let graph: Graph
    let planner: Planner
    let canonical: Canonical
    let documents: Documents
    let queries: Queries
    let fragments: Fragments
    let optimistic: Optimistic
    let operations: Operations

    private let remoteApplyFlag = RemoteApplyFlag()

    public init(options: CachebayOptions) {
        let graph = Graph(options: GraphOptions(keys: options.keys, interfaces: options.interfaces, onChange: nil))
        let planner = Planner()
        let canonical = Canonical(graph: graph)
        let documents = Documents(graph: graph, planner: planner, canonical: canonical, logger: options.logger)
        let queries = Queries(graph: graph, planner: planner, documents: documents, logger: options.logger)
        let fragments = Fragments(planner: planner, documents: documents)
        let optimistic = Optimistic(graph: graph, planner: planner, documents: documents)
        canonical.setReplayer(optimistic)
        documents.setReplayer(optimistic)
        let operations = Operations(
            transport: options.transport, planner: planner, documents: documents, queries: queries,
            defaultPolicy: options.cachePolicy, suspensionTimeout: options.suspensionTimeout
        )
        let inspect = Inspect(graph: graph)

        let remoteApplyFlag = self.remoteApplyFlag
        var storageInstance: StorageAdapter? = nil
        if let factory = options.storage {
            // First 8 hex chars of a v4 UUID — unique per instance, no force-unwrap,
            // no dependency on an external seed source.
            let instanceID = String(UUID().uuidString.lowercased().prefix(8))
            let ctx = StorageContext(
                instanceID: instanceID,
                onUpdate: { [weak graph] records in
                    guard let graph else { return }
                    remoteApplyFlag.set(true)
                    for (id, rec) in records { graph.putRecord(id, rec) }
                    graph.flush()
                    remoteApplyFlag.set(false)
                },
                onRemove: { [weak graph] ids in
                    guard let graph else { return }
                    remoteApplyFlag.set(true)
                    for id in ids { graph.removeRecord(id) }
                    graph.flush()
                    remoteApplyFlag.set(false)
                },
                onEvictAll: nil
            )
            storageInstance = factory(ctx)
        }
        self.storage = storageInstance

        self.graph = graph
        self.planner = planner
        self.canonical = canonical
        self.documents = documents
        self.queries = queries
        self.fragments = fragments
        self.optimistic = optimistic
        self.operations = operations
        self.inspect = inspect

        // Wire Graph.onChange → Queries + Fragments dependency propagation +
        // storage replication (unless we're currently applying a remote update).
        let queriesRef = queries
        let fragmentsRef = fragments
        let storageRef = storageInstance
        let graphRef = graph
        graph.setOnChange { touched in
            queriesRef.notifyDataByDependencies(touched)
            fragmentsRef.notifyDataByDependencies(touched)
            guard let storageRef, !remoteApplyFlag.isSet else { return }
            var puts: [(CacheKey, [String: JSONValue])] = []
            var removes: [CacheKey] = []
            for id in touched {
                // Skip synthetic dep keys like `@.posts` — they're notification
                // slivers, not actual records.
                if id.contains(".") && graphRef.getRecord(id) == nil && !graphRef.hasRecord(id) {
                    continue
                }
                if let snap = graphRef.getRecord(id) {
                    puts.append((id, snap))
                } else {
                    removes.append(id)
                }
            }
            if !puts.isEmpty { storageRef.put(puts) }
            if !removes.isEmpty { storageRef.remove(removes) }
        }

        // Hydration from storage is **explicit** — call `client.warmup()`
        // when ready (e.g. in your auth bootstrap, or wrapped in a Task).
        // No auto-async-warmup at construction time. Rationale: callers
        // need control over when the graph is hydrated so first queries
        // don't race the load. v0.9.0 breaking change.
    }

    /// Hydrate the in-memory graph from the configured storage adapter.
    /// **Synchronous on the calling thread** — wrap in a `Task` if you
    /// want async semantics. No-op if no storage adapter is configured.
    ///
    /// Gap-fill semantics: only writes records the in-memory graph
    /// doesn't already have. A live network response that landed
    /// before `warmup()` is treated as more authoritative than disk.
    ///
    /// Idempotent: subsequent calls re-issue the SQLite read but the
    /// gap-fill predicate makes them effectively no-ops.
    ///
    /// Typical use:
    ///
    /// ```swift
    /// // In your AuthViewModel.bootstrap (or wherever the first
    /// // queries are about to fire):
    /// func bootstrap() async {
    ///     // Ensure cache is warm before any cacheFirst query runs.
    ///     // ~10-300 ms depending on cache size; runs on the calling
    ///     // thread (or a Task you choose).
    ///     await Task.detached(priority: .userInitiated) {
    ///         CachebayService.client.warmup()
    ///     }.value
    ///     // … rest of bootstrap …
    /// }
    /// ```
    ///
    /// Or call directly on main during `App.init` if the cost is
    /// acceptable (~50-300 ms for typical caches; iOS launch budget
    /// is ~5-10 s, well within tolerance).
    public func warmup() {
        guard let storage = self.storage else { return }
        do {
            let records = try storage.loadSync()
            if records.isEmpty { return }
            remoteApplyFlag.set(true)
            for (id, snap) in records where !graph.hasRecord(id) {
                graph.putRecord(id, snap)
            }
            graph.flush()
            remoteApplyFlag.set(false)
        } catch {
            // Load failure is swallowed; cache simply stays cold.
            // (Subsystem loggers aren't on `self` — surface this via
            // a watcher's onError if you need the signal in production.)
        }
    }

    /// Force a drain of pending storage writes and close connections.
    /// Call on app termination for a persistent guarantee; otherwise rely on
    /// write-behind + WAL.
    public func shutdown() async {
        if let storage {
            try? await storage.flush()
            storage.dispose()
        }
    }

    // MARK: - Identity

    public func identify(_ object: [String: JSONValue]) -> CacheKey? {
        return graph.identify(object)
    }

    // MARK: - readFragment / writeFragment / watchFragment

    public func readFragment(id: CacheKey, fragment: String, fragmentName: String? = nil, variables: [String: JSONValue] = [:]) -> JSONValue? {
        readFragment(id: id, fragment: .source(fragment), fragmentName: fragmentName, variables: variables)
    }

    public func readFragment(id: CacheKey, fragment: QueryDocument, fragmentName: String? = nil, variables: [String: JSONValue] = [:]) -> JSONValue? {
        guard let plan = try? planner.getPlan(fragment, fragmentName: fragmentName) else { return nil }
        return fragments.readFragment(plan: plan, rootId: id, variables: variables)
    }

    public func writeFragment(id: CacheKey, fragment: String, fragmentName: String? = nil, variables: [String: JSONValue] = [:], data: JSONValue) throws {
        let plan = try planner.getPlan(.source(fragment), fragmentName: fragmentName)
        fragments.writeFragment(plan: plan, rootId: id, variables: variables, data: data)
        graph.flush()
    }

    public func watchFragment(id: CacheKey, fragment: String, fragmentName: String? = nil, options: WatchFragmentOptions) throws -> WatchFragmentHandle {
        let doc = QueryDocument.source(fragment)
        let plan = try planner.getPlan(doc, fragmentName: fragmentName)
        return fragments.watchFragment(plan: plan, document: doc, fragmentName: fragmentName, rootId: id, options: options)
    }

    // MARK: - readQuery / writeQuery / watchQuery

    public func readQuery(query: String, variables: [String: JSONValue] = [:]) -> JSONValue? {
        guard let plan = try? planner.getPlan(.source(query)) else { return nil }
        return queries.readQuery(plan: plan, variables: variables)
    }

    public func writeQuery(query: String, variables: [String: JSONValue] = [:], data: JSONValue) throws {
        let plan = try planner.getPlan(.source(query))
        queries.writeQuery(plan: plan, variables: variables, data: data)
    }

    public func watchQuery(query: String, options: WatchQueryOptions) throws -> WatchQueryHandle {
        let doc = QueryDocument.source(query)
        let plan = try planner.getPlan(doc)
        return queries.watchQuery(plan: plan, document: doc, options: options)
    }

    // MARK: - Optimistic

    /// Open an optimistic layer. The closure runs **once**,
    /// immediately, and its ops are recorded for replay if a sibling
    /// layer later commits or reverts.
    ///
    /// Returns an `OptimisticTransaction` whose `commit { b in … }`
    /// takes a separate commit-phase closure that captures typed
    /// server data from outer scope (no `ctx.data` plumbing).
    /// `revert()` and `dispose()` are unchanged.
    public func modifyOptimistic(_ builder: @Sendable (_ b: OptimisticBuilder) -> Void) -> OptimisticTransaction {
        return optimistic.modifyOptimistic(builder)
    }

    /// Single-phase variant: `autoCommit: true` skips layer recording
    /// and runs the builder once, applying ops directly to the graph.
    ///
    /// Use when you've already awaited the server's response and only
    /// want to write the result through the builder API:
    ///
    /// ```swift
    /// let result = try await client.executeMutation(...)
    /// guard let created = result.data?.createProject else { throw ... }
    /// // The mutation's normalize already wrote the entity record
    /// // — auto-commit only needs to link it into the connections.
    /// client.modifyOptimistic(autoCommit: true) { b in
    ///     for key in keys {
    ///         b.connection(key: key).linkNode(node: created,
    ///                                          options: .init(position: .start))
    ///     }
    /// }
    /// ```
    ///
    /// `autoCommit: false` is equivalent to the unlabeled overload
    /// minus the returned transaction handle (the layer stays applied
    /// indefinitely — discouraged; prefer the unlabeled overload).
    public func modifyOptimistic(
        autoCommit: Bool,
        _ builder: @Sendable (_ b: OptimisticBuilder) -> Void
    ) {
        if autoCommit {
            optimistic.applyAutoCommit(builder)
        } else {
            _ = optimistic.modifyOptimistic(builder)
        }
    }

    // MARK: - Operations

    @discardableResult
    public func executeQuery(query: String, variables: [String: JSONValue] = [:], cachePolicy: CachePolicy? = nil, onCacheData: (@Sendable (_ data: JSONValue, _ willFetchFromNetwork: Bool) -> Void)? = nil, onNetworkData: (@Sendable (_ data: JSONValue) -> Void)? = nil, onError: (@Sendable (_ error: CombinedError) -> Void)? = nil) async throws -> OperationResult<JSONValue> {
        let plan = try planner.getPlan(.source(query))
        let opts = ExecuteQueryOptions(variables: variables, cachePolicy: cachePolicy, onCacheData: onCacheData, onNetworkData: onNetworkData, onError: onError)
        return await operations.executeQuery(plan: plan, options: opts)
    }

    @discardableResult
    public func executeMutation(query: String, variables: [String: JSONValue] = [:], onData: (@Sendable (_ data: JSONValue) -> Void)? = nil, onError: (@Sendable (_ error: CombinedError) -> Void)? = nil) async throws -> OperationResult<JSONValue> {
        let plan = try planner.getPlan(.source(query))
        let opts = ExecuteMutationOptions(variables: variables, onData: onData, onError: onError)
        return await operations.executeMutation(plan: plan, options: opts)
    }

    public func executeSubscription(query: String, variables: [String: JSONValue] = [:]) throws -> AsyncThrowingStream<OperationResult<JSONValue>, Error> {
        let plan = try planner.getPlan(.source(query))
        return operations.executeSubscription(plan: plan, options: ExecuteSubscriptionOptions(variables: variables))
    }

    // MARK: - Evict

    public func evictAll() async {
        // Clear persistent storage FIRST so on next launch (or in this
        // process if the storage is shared) records don't resurrect
        // from disk. Mirrors cachebay-web's `evictAll →
        // storageAdapter.evictAll() → evictInMemoryAndRefetch()` flow.
        // Without this, `evictAll` is a no-op across app restarts: the
        // in-memory graph wipes, the storage adapter still holds the
        // records, and `storage.load()` re-hydrates them.
        if let storage {
            try? await storage.evictAll()
        }
        optimistic.evictAll()
        documents.evictAll()
        graph.evictAll()
        fragments.notifyEvictAll()
        let refetch = queries.notifyEvictAll()
        for descriptor in refetch {
            let plan = descriptor.plan
            let variables = descriptor.variables
            _ = await operations.executeQuery(
                plan: plan,
                options: ExecuteQueryOptions(variables: variables, cachePolicy: .networkOnly)
            )
        }
    }
}
