import Foundation

/// How `b.patch(_:_:mode:)` reconciles its patch with the existing
/// entity record. `.merge` (default) shallow-merges fields;
/// `.replace` writes exactly the patch and drops everything else.
public enum EntityPatchMode: Sendable {
    case merge
    case replace
}

/// Where `b.connection(...).linkNode` inserts the new edge. `.before`
/// and `.after` require an `anchor`; missing-anchor falls back to
/// `.start` / `.end` respectively.
public enum EdgePosition: Sendable {
    case start
    case end
    case before
    case after
}

/// How callers identify an entity record. `.key` is direct
/// (`"Post:p1"`); `.object` runs through your `KeyFunction` /
/// `id`-fallback to produce the same key.
public enum EntityRef: Sendable {
    case key(CacheKey)
    case object([String: JSONValue])
}

/// Connection-selector handed to optimistic builders.
public struct ConnectionSelector: Sendable {
    public var parent: EntityRef
    public var key: String
    public var filters: [String: JSONValue]
    public init(parent: EntityRef = .key(CachebayConstants.rootID), key: String, filters: [String: JSONValue] = [:]) {
        self.parent = parent
        self.key = key
        self.filters = filters
    }
}

/// Options for `b.connection(...).linkNode(_:options:)` — the
/// connection-link primitive. Purely structural: `position` controls
/// where the new edge ref lands in the canonical's `edges` refList,
/// `anchor` resolves the reference for `.before` / `.after`, and
/// `edge` carries optional per-edge meta (cursor, score, …) that
/// lands on the synthesised edge record (NOT on the entity).
public struct LinkNodeOptions: Sendable {
    public var position: EdgePosition = .end
    public var anchor: EntityRef? = nil
    public var edge: [String: JSONValue]? = nil
    public init(
        position: EdgePosition = .end,
        anchor: EntityRef? = nil,
        edge: [String: JSONValue]? = nil
    ) {
        self.position = position
        self.anchor = anchor
        self.edge = edge
    }
}

/// Handle for a pending optimistic layer. **Reference-typed** —
/// the layer's lifetime is bound to the lifetime of this transaction
/// reference. When the last strong reference is released without an
/// explicit `commit` / `revert` / `dispose`, `deinit` auto-disposes
/// the layer as a safety net.
///
/// This is the **v0.9.2 shape change** from a `Sendable struct` of
/// closures to a `final class @unchecked Sendable`. Source-compatible
/// for the 99%+ case: `tx.commit(...)`, `tx.revert()`, `tx.dispose()`
/// all keep the same signatures. The semantic change is lifetime:
/// holding `tx` keeps the layer pending; dropping `tx` cleans it up.
///
/// Holding a long-lived optimistic layer (an unsent draft, a streaming
/// upload preview, a 30-second voice-recording stub) means holding
/// the `OptimisticTransaction` reference for as long as the optimistic
/// state should remain visible. The layer is auto-disposed when the
/// last strong reference goes out of scope.
public final class OptimisticTransaction: @unchecked Sendable {
    private let _commit: @Sendable (@escaping @Sendable (OptimisticBuilder) -> Void) -> Void
    private let _revert: @Sendable () -> Void
    private let _dispose: @Sendable () -> Void

    init(
        commit: @escaping @Sendable (@escaping @Sendable (OptimisticBuilder) -> Void) -> Void,
        revert: @escaping @Sendable () -> Void,
        dispose: @escaping @Sendable () -> Void
    ) {
        self._commit = commit
        self._revert = revert
        self._dispose = dispose
    }

    /// Finalize the layer with a separate commit-phase closure.
    ///
    /// Semantics:
    ///   * Layer removed from pending. Future replays of other layers
    ///     ignore this one.
    ///   * Baselines for records this layer touched are restored.
    ///   * Surviving layers' recorded ops are replayed on top.
    ///   * The supplied `build` closure runs **once**, applying its
    ///     ops directly to the graph (no recording, no layer).
    ///   * Baselines for records no longer referenced by any surviving
    ///     layer are dropped.
    ///
    /// Idempotent: a second `commit(...)` call after the layer has
    /// already been resolved is a no-op — the closure is NOT invoked
    /// twice. (Underlying `Optimistic.commit` uses `firstIndex` to
    /// short-circuit.)
    ///
    /// The commit closure captures typed server data from outer scope —
    /// there is no `ctx.data` plumbing, no `JSONValue?` unwrap, no
    /// generic over `OperationData`. Just an ordinary Swift closure.
    ///
    /// ```swift
    /// let tx = client.modifyOptimistic { b in
    ///     b.patch(.key("Post:temp"), ["title": .string("Drafting…")], mode: .merge)
    /// }
    /// let result = try await client.executeMutation(...)
    /// if result.error != nil { tx.revert(); throw ... }
    /// tx.commit { b in
    ///     // `result` captured from outer scope — fully typed.
    ///     if let post = result.data?.createPost?.post {
    ///         b.patch(.key("Post:\(post.id)"), ["title": .string(post.title)], mode: .merge)
    ///     }
    /// }
    /// ```
    public func commit(_ build: @escaping @Sendable (OptimisticBuilder) -> Void) {
        _commit(build)
    }

    /// Revert: restore baselines for the layer's touched records,
    /// replay surviving layers' ops on top, drop the layer.
    /// Idempotent — a second `revert()` is a no-op.
    public func revert() {
        _revert()
    }

    /// Drop the layer without restoring baselines or running any
    /// commit-time work. Use when the server's response was already
    /// normalized into the cache (via `executeMutation`'s pipeline)
    /// and is authoritative — calling `commit { … }` here without a
    /// reason would replay surviving layers' ops on top of the
    /// already-normalized state, possibly producing duplicate writes.
    ///
    /// Semantics:
    ///   * Layer removed from pending. Future replays of other layers
    ///     ignore this one.
    ///   * Baselines for records touched ONLY by this layer are
    ///     dropped. Records still referenced by surviving layers keep
    ///     their baseline.
    ///   * Graph state is NOT modified — whatever the cache holds
    ///     after `executeMutation`'s normalize is the final state.
    ///
    /// Idempotent — a second `dispose()` is a no-op.
    public func dispose() {
        _dispose()
    }

    /// Safety net: when the last strong reference to this transaction
    /// goes out of scope without an explicit resolve, auto-dispose
    /// the layer. Prevents the "I forgot to handle the error path"
    /// leak class where a layer would otherwise stay pending forever
    /// (and after v0.9.1, replay its ops on every subsequent
    /// `documents.normalize`, causing unbounded phantom writes).
    ///
    /// Dispose is chosen over revert as the default because:
    ///   * The layer's ops were already applied to the graph when the
    ///     layer opened. `dispose` preserves that observable state.
    ///   * `revert` would assume the caller wanted to undo their
    ///     optimistic edit — paternalistic and likely wrong for the
    ///     "common error path" leak case.
    ///   * If the layer's intent was tied to a server mutation that
    ///     never returned, the next server normalize on the same
    ///     record will overwrite via the standard merge — no need
    ///     for an explicit rollback.
    ///   * Idempotent at the `Optimistic` layer: if the caller
    ///     already explicitly resolved (commit/revert/dispose), this
    ///     deinit-fired `dispose` is a no-op (`firstIndex` returns
    ///     nil, guard returns early).
    deinit {
        _dispose()
    }
}

/// The builder surface used inside `cache.modifyOptimistic { b in ... }`
/// and `tx.commit { b in ... }`.
public protocol OptimisticBuilder: AnyObject, Sendable {
    func patch(_ target: EntityRef, _ patch: [String: JSONValue], mode: EntityPatchMode)
    /// Closure form mirroring `cachebay-web`'s
    /// `b.patch(target, prev => ({...}))`. The closure receives the
    /// current cache snapshot of the entity (`[:]` if absent) and
    /// returns the patch dict to apply. Use this for read-modify-write
    /// flows like incrementing a counter where the optimistic value
    /// depends on the latest cached value.
    func patch(_ target: EntityRef, mode: EntityPatchMode, _ build: @Sendable (_ prev: [String: JSONValue]) -> [String: JSONValue])
    func delete(_ target: EntityRef)
    func connection(_ selector: ConnectionSelector) -> ConnectionAPI
    func connection(key canonicalKey: CacheKey) -> ConnectionAPI
    /// Resolve a typename to the canonical interface namespace if it
    /// implements one (e.g. `"SpeechClip"` → `"TimelineClip"` when the
    /// `interfaces` option registers SpeechClip as a TimelineClip impl).
    /// Returns the input unchanged when there's no interface mapping.
    /// Used by the typed `patch<F>(fragment:id:_:)` overloads so a
    /// variant-rooted fragment lands on the canonical entity key.
    func canonicalTypename(_ typename: String) -> String
    /// Plan-aware optimistic write. Walks the fragment plan + data,
    /// captures baselines for every entity record it touches, and
    /// normalizes nested entities (single + list) into separate cache
    /// records linked by `.ref` / `.refList`. Mirrors
    /// `CachebayClient.writeFragment` but goes through the optimistic
    /// layer — `revert()` / `dispose()` work, layered commit replays
    /// surviving siblings correctly.
    ///
    /// Use for OPTIMISTIC CREATE flows where a fresh entity tree is
    /// built client-side (e.g. an outbound chat message + its
    /// attachments). The strict materializer requires `.ref` /
    /// `.refList` for selection-set link fields, so embedded objects
    /// silence the watcher with "unexpected link shape" — this method
    /// produces the right shape automatically.
    ///
    /// Limitation: only entity-shaped records (objects with
    /// `__typename + id`) get baselines captured. Inline-container
    /// synthetic keys (e.g. `Element:42.derivatives.0`) write into the
    /// graph but aren't tracked for revert. For fresh-create flows
    /// this is harmless (no prior state to restore); flows that
    /// optimistically mutate pre-existing inline containers should
    /// stay on `b.patch(...)`.
    func writeFragment(
        document: QueryDocument,
        fragmentName: String,
        rootId: CacheKey,
        variables: [String: JSONValue],
        data: [String: JSONValue]
    )

    /// Plan-aware optimistic patch — backs the typed
    /// `patch<F>(fragment:id:_:)` overload. Walks the fragment plan in
    /// tandem with the supplied (partial) data dict and translates any
    /// data-shape values for selection-set fields into graph-shape
    /// equivalents:
    ///
    /// - **Inline-container** (id-less object on a selection-set field) →
    ///   parent gets `.ref("<parent>.<fieldKey>")`, the inline contents
    ///   land at the synthetic container key. Mirrors `documents.normalize`
    ///   for the same shape.
    /// - **Entity object** (`__typename + id` resolves a cache key) →
    ///   parent gets `.ref("Type:id")`, the entity record gets the
    ///   inline fields merged in.
    /// - **List of either** → parent gets `.refList`, each element
    ///   becomes its own record (synthetic key for inline, canonical key
    ///   for entity).
    /// - **Scalars / `.null` / `.undefined` / `.ref` / `.refList`** →
    ///   pass through unchanged.
    ///
    /// Each produced write goes through the existing
    /// `patch(_ target:_:mode:)` path so baseline capture and revert
    /// semantics work uniformly across the root record AND any
    /// synthetic container / entity records the translation introduces.
    ///
    /// `mode` propagates to every write: a `.replace` patch on a
    /// `Project` whose draft touched `Project.settings` will drop the
    /// parent's unrelated fields AND replace the synthetic container's
    /// contents. Consumers who only want surgical scalar edits should
    /// keep using the JSON-shaped `patch(_ target: EntityRef, _ patch:
    /// [String: JSONValue], mode:)` directly — that path is plan-agnostic
    /// and assumes the patch is already graph-shaped.
    func patchFragment(
        document: QueryDocument,
        fragmentName: String,
        rootId: CacheKey,
        variables: [String: JSONValue],
        data: [String: JSONValue],
        mode: EntityPatchMode
    )
}

public extension OptimisticBuilder {
    /// Backwards-compatible default: falls back to the dumb JSON patch
    /// so external conformers don't break when `patchFragment` lands as
    /// a new protocol requirement. Cachebay's own `BuilderImpl` overrides
    /// with the plan-aware translation.
    func patchFragment(
        document: QueryDocument,
        fragmentName: String,
        rootId: CacheKey,
        variables: [String: JSONValue],
        data: [String: JSONValue],
        mode: EntityPatchMode
    ) {
        patch(.key(rootId), data, mode: mode)
    }
}

/// Connection mutation surface — manipulates the structural shape of
/// a connection (its `edges` refList, edge meta, pageInfo) **only**.
///
/// Connection mutations DO NOT write to the entity store. The entity
/// records the connection points at (`Post:p1`, `User:u1`, …) are
/// owned exclusively by `documents.normalize` (auto from query /
/// mutation / subscription responses, or explicit via
/// `b.writeFragment` / `b.patch` / `b.delete`). Linking the same
/// entity into multiple connections, or unlinking it, never affects
/// its scalar fields. If the entity isn't in the cache yet, that's
/// the caller's responsibility — see `writeFragment`.
///
/// This separation is intentional and load-bearing: it makes a whole
/// class of "stale-payload replays clobber later state" bugs
/// impossible by construction. The `linkNode` signature takes an
/// `EntityRef` (identity), not a node dict (data) — there's nothing
/// in the API surface that *could* leak scalars onto the entity.
public protocol ConnectionAPI: AnyObject, Sendable {
    var key: CacheKey { get }
    /// Insert an edge into the connection pointing at `ref`. Purely
    /// structural — does not write to the entity record. The entity
    /// must already exist in the cache (via normalize / writeFragment)
    /// for the link to materialize anything when read.
    func linkNode(_ ref: EntityRef, options: LinkNodeOptions)
    /// Remove the edge that points at `ref` from this connection.
    /// The entity record itself is untouched — only the edge link is
    /// removed. Other connections that link to the same entity are
    /// unaffected.
    func unlinkNode(_ ref: EntityRef)
    func patch(_ update: [String: JSONValue])
    /// Closure-builder form mirroring cachebay-web's
    /// `c.patch(prev => ({...}))`. The closure receives the current
    /// snapshot of the connection canonical record (`[:]` if absent)
    /// and returns the patch dict to merge into it. Use this for
    /// read-modify-write on connection-level scalars (e.g.
    /// `totalCount` increments) where the optimistic value depends on
    /// the latest cached value.
    func patch(_ build: @Sendable (_ prev: [String: JSONValue]) -> [String: JSONValue])
    /// See `OptimisticBuilder.canonicalTypename(_:)` — exposed here so
    /// typed link overloads can canonicalise the fragment's
    /// `onTypename` to the right cache namespace.
    func canonicalTypename(_ typename: String) -> String
}

public final class Optimistic: @unchecked Sendable {
    private let graph: Graph
    private let planner: Planner?
    private let documents: Documents?
    let profiler: (any CachebayProfiler)?
    private let lock = NSRecursiveLock()

    fileprivate enum EntityOpKind: Sendable { case write(patch: [String: JSONValue], mode: EntityPatchMode); case delete }
    fileprivate enum ConnectionOpKind: Sendable {
        case linkNode(entityKey: CacheKey, meta: [String: JSONValue]?, position: EdgePosition, anchor: CacheKey?)
        case unlinkNode(entityKey: CacheKey)
        case patch([String: JSONValue])
    }
    fileprivate struct EntityOp: Sendable { let recordId: CacheKey; let kind: EntityOpKind }
    fileprivate struct ConnectionOp: Sendable { let connectionKey: CacheKey; let kind: ConnectionOpKind }

    fileprivate final class Layer: @unchecked Sendable {
        let id: Int
        var entityOps: [EntityOp] = []
        var connectionOps: [ConnectionOp] = []
        var touched: Set<CacheKey> = []
        init(id: Int) {
            self.id = id
        }
    }

    fileprivate var layers: [Layer] = []
    private var nextLayerId: Int = 1
    /// One-shot pre-optimistic snapshot captured for every record touched by
    /// any layer. Restored on revert/commit before replaying surviving layers.
    private var committedBaselines: [CacheKey: [String: JSONValue]?] = [:]

    public init(graph: Graph, planner: Planner? = nil, documents: Documents? = nil, profiler: (any CachebayProfiler)? = nil) {
        self.graph = graph
        self.planner = planner
        self.documents = documents
        self.profiler = profiler
    }

    /// Open a new optimistic layer. The closure runs **once**,
    /// immediately, on the optimistic-phase graph; its ops are
    /// recorded on the layer for replay if a sibling layer commits or
    /// reverts later.
    ///
    /// Returns an `OptimisticTransaction` whose `commit { b in … }` /
    /// `revert()` / `dispose()` finalize the layer. The commit
    /// closure is separate — it captures typed data from outer
    /// scope; there is no `ctx.data` / `BuilderContext` plumbing.
    public func modifyOptimistic(_ builder: @Sendable (_ b: OptimisticBuilder) -> Void) -> OptimisticTransaction {
        let span = profiler?.begin("cachebay.modifyOptimistic")
        defer { span?.end() }

        lock.lock()
        nextLayerId += 1
        let layer = Layer(id: nextLayerId)
        layers.append(layer)
        lock.unlock()

        let b = BuilderImpl(optimistic: self, layer: layer, recording: true)
        // Host code — excluded from the span's reported duration.
        span.excludingHost { builder(b) }
        graph.flush()

        let weakSelf = self
        return OptimisticTransaction(
            commit: { [weak weakSelf] commitBuilder in
                weakSelf?.commit(layer: layer, commitBuilder: commitBuilder)
            },
            revert: { [weak weakSelf] in
                weakSelf?.revert(layer: layer)
            },
            dispose: { [weak weakSelf] in
                weakSelf?.dispose(layer: layer)
            }
        )
    }

    /// Single-phase variant of `modifyOptimistic`. Runs the closure
    /// once, applying ops directly to the base graph without
    /// recording a layer.
    ///
    /// Use this when you've already awaited the server's response
    /// and only want to write the result into cache via the builder
    /// API (`b.connection(...).linkNode(...)` etc.). Compared to
    /// `modifyOptimistic { … }` followed by `tx.dispose()`:
    /// `applyAutoCommit` skips the layer-recording overhead since
    /// there is no optimistic state to project / revert.
    ///
    /// Callers reach this via
    /// `client.modifyOptimistic(autoCommit: true) { … }`.
    public func applyAutoCommit(_ builder: @Sendable (_ b: OptimisticBuilder) -> Void) {
        let span = profiler?.begin("cachebay.applyAutoCommit")
        defer { span?.end() }

        // Dummy layer — never appended to `layers`, never replayed,
        // never reverted. Held only so BuilderImpl has a stable
        // reference; in non-recording mode it's never read.
        let dummy = Layer(id: 0)
        let b = BuilderImpl(optimistic: self, layer: dummy, recording: false)
        // Host code — excluded from the span's reported duration.
        span.excludingHost { builder(b) }
        graph.flush()
    }

    /// Replay summary: which entity keys were linked into a connection
    /// (`linkNode`) and which were unlinked (`unlinkNode`) within the
    /// scope of this replay. Mirrors cachebay-web's
    /// `replayOptimistic({connections}) → {linked: Set, unlinked: Set}`.
    public struct ReplayResult: Sendable {
        public let linked: Set<CacheKey>
        public let unlinked: Set<CacheKey>
        public init(linked: Set<CacheKey> = [], unlinked: Set<CacheKey> = []) {
            self.linked = linked
            self.unlinked = unlinked
        }
    }

    @discardableResult
    public func replay(connectionKeys: [CacheKey]) -> ReplayResult {
        // Unlocked fast path — same rationale as `replayEntityOps`.
        // Connection-merge runs this on every page update; cheap exit
        // when no layers are pending matters.
        if layers.isEmpty { return ReplayResult() }
        let span = profiler?.begin("cachebay.optimistic.replay.connection")
        defer { span?.end() }
        lock.lock()
        if layers.isEmpty {
            lock.unlock()
            return ReplayResult()
        }
        let sorted = layers.sorted { $0.id < $1.id }
        lock.unlock()
        span?.attribute("layerCount", "\(sorted.count)")
        span?.attribute("scopeSize", "\(connectionKeys.count)")
        let scope = connectionKeys.isEmpty ? nil : Set(connectionKeys)
        var linked: Set<CacheKey> = []
        var unlinked: Set<CacheKey> = []
        for layer in sorted {
            for op in layer.entityOps { applyEntityOp(op) }
            for op in layer.connectionOps {
                if let scope, !scope.contains(op.connectionKey) { continue }
                applyConnectionOp(op)
                switch op.kind {
                case .linkNode(let entityKey, _, _, _):
                    linked.insert(entityKey)
                case .unlinkNode(let entityKey):
                    unlinked.insert(entityKey)
                case .patch:
                    break
                }
            }
        }
        return ReplayResult(linked: linked, unlinked: unlinked)
    }

    /// Re-apply pending optimistic layers' entity ops over the
    /// currently-committed graph state, scoped to `entityKeys`. Used
    /// by `Documents.normalize` to ensure that a server-response
    /// normalize (mutation / subscription / query refresh) doesn't
    /// silently clobber a pending optimistic patch on the same fields.
    ///
    /// Symmetric with `replay(connectionKeys:)`, which already provides
    /// this protection for connection canonicals (`linkNode` /
    /// `unlinkNode` ops survive a paginate-after-cursor server merge).
    /// Without this entity-side version, two concurrent optimistic
    /// layers patching different fields of the same entity would
    /// experience a flicker when the first mutation's server response
    /// lands carrying stale values for the field the second layer
    /// patched. See
    /// `OptimisticReplayAfterNormalizeTests.test_pendingOptimisticFields_surviveServerNormalize`.
    ///
    /// Layer ops are applied in layer-id order so the latest layer's
    /// value wins on field conflicts — consistent with the rest of the
    /// layered-write semantics. A layer's op is only re-applied when
    /// its `recordId` is in `entityKeys`; ops on records the normalize
    /// didn't touch are left alone.
    public func replayEntityOps(scope entityKeys: Set<CacheKey>) {
        if entityKeys.isEmpty { return }
        // Unlocked fast path. `documents.normalize` calls this on
        // every server-response merge — that's the runtime's hottest
        // path. Skipping the lock + array sort when no layers exist
        // makes the no-pending-layers case truly free (a single
        // unsynchronized `Array.isEmpty` read on the `layers` Swift
        // array's storage header). False-negative race window is
        // benign: a layer added concurrently with this check just
        // gets its replay deferred to the next normalize call.
        if layers.isEmpty { return }
        let span = profiler?.begin("cachebay.optimistic.replay.entity")
        defer { span?.end() }
        span?.attribute("scopeSize", "\(entityKeys.count)")
        lock.lock()
        // Re-check under the lock — a concurrent `modifyOptimistic`
        // could have raced our unlocked read above.
        if layers.isEmpty {
            lock.unlock()
            return
        }
        // Snapshot layers in id order while holding the lock so a
        // concurrent `modifyOptimistic` / `commit` doesn't reorder
        // us mid-walk. We're only reading; the actual op application
        // talks to `graph` which has its own lock.
        let sorted = layers.sorted { $0.id < $1.id }
        lock.unlock()
        for layer in sorted {
            for op in layer.entityOps where entityKeys.contains(op.recordId) {
                applyEntityOp(op)
            }
        }
    }

    public func evictAll() {
        lock.lock(); defer { lock.unlock() }
        layers.removeAll(keepingCapacity: false)
    }

    // MARK: - Commit / Revert
    //
    // The revert/commit strategy uses the **global** `committedBaselines` map:
    // every record touched by any layer is snapshotted once (the first time
    // any layer touches it). On revert/commit, we:
    //   1. Remove the layer from the pending list.
    //   2. For each record touched only by the removed layer, restore the
    //      committed baseline and drop the baseline entry. For records still
    //      touched by surviving layers, restore the baseline (leaving it
    //      cached for future reverts).
    //   3. Replay surviving layers' ops in id order on the affected records
    //      so stacked layers keep their effects.

    /// Drop the layer's bookkeeping without restoring any baselines
    /// or re-running the builder. Used when the server's response is
    /// authoritative and `executeMutation`'s normalize already wrote
    /// the canonical state into the graph — calling `commit(_:)`
    /// here would revert touched records to the pre-optimistic
    /// snapshot, wiping the server normalize.
    ///
    /// Semantics: layer removed from pending; baselines dropped for
    /// records this layer was the SOLE toucher of (records still
    /// referenced by surviving layers keep their baseline so future
    /// reverts work correctly).
    private func dispose(layer: Layer) {
        lock.lock(); defer { lock.unlock() }
        let idx = layers.firstIndex { $0.id == layer.id }
        guard let i = idx else { return }
        layers.remove(at: i)
        let touched = layer.touched
        let stillReferenced = Set(layers.flatMap { $0.touched })
        for r in touched where !stillReferenced.contains(r) {
            committedBaselines.removeValue(forKey: r)
        }
    }

    private func commit(layer: Layer, commitBuilder: @Sendable (_ b: OptimisticBuilder) -> Void) {
        lock.lock()
        // Idempotency guard — symmetric with `dispose` and `revert`,
        // both of which use `firstIndex` to short-circuit re-entry.
        // Without this guard, calling `commit` twice (e.g. via the
        // v0.9.2 `OptimisticTransaction.deinit` safety net firing
        // after an explicit commit) would re-run the caller's commit
        // builder closure and double-write whatever it touches.
        guard layers.firstIndex(where: { $0.id == layer.id }) != nil else {
            lock.unlock()
            return
        }
        layers.removeAll { $0.id == layer.id }
        let touched = Array(layer.touched)
        let survivors = layers.sorted { $0.id < $1.id }
        // Restore touched records to the committed baseline, then replay survivors.
        for recordId in touched {
            if let snapshot = committedBaselines[recordId] {
                restoreEntity(recordId, snapshot: snapshot ?? nil)
            }
        }
        replayEntityAndConnectionOps(survivors, scope: Set(touched))
        // Drop baselines for records no longer referenced by any surviving layer.
        let stillReferenced = Set(survivors.flatMap { $0.touched })
        for r in touched where !stillReferenced.contains(r) {
            committedBaselines.removeValue(forKey: r)
        }
        lock.unlock()

        // Run the caller's commit closure once, applying its ops
        // directly to the graph (no recording, no layer). The closure
        // captures typed server data from outer scope.
        let dummy = Layer(id: 0)
        let b = BuilderImpl(optimistic: self, layer: dummy, recording: false)
        commitBuilder(b)
        graph.flush()
    }

    private func revert(layer: Layer) {
        lock.lock()
        let idx = layers.firstIndex { $0.id == layer.id }
        guard let i = idx else { lock.unlock(); return }
        layers.remove(at: i)
        let touched = Array(layer.touched)
        let survivors = layers.sorted { $0.id < $1.id }
        for recordId in touched {
            if let snapshot = committedBaselines[recordId] {
                restoreEntity(recordId, snapshot: snapshot ?? nil)
            }
        }
        replayEntityAndConnectionOps(survivors, scope: Set(touched))
        let stillReferenced = Set(survivors.flatMap { $0.touched })
        for r in touched where !stillReferenced.contains(r) {
            committedBaselines.removeValue(forKey: r)
        }
        lock.unlock()
        graph.flush()
    }

    /// Replay the given layers' ops in id order, filtered to records in `scope`.
    private func replayEntityAndConnectionOps(_ layers: [Layer], scope: Set<CacheKey>) {
        for l in layers {
            for op in l.entityOps where scope.contains(op.recordId) {
                applyEntityOp(op)
            }
            for op in l.connectionOps where scope.contains(op.connectionKey) {
                applyConnectionOp(op)
            }
        }
    }

    // MARK: - Entity ops

    private func applyEntityOp(_ op: EntityOp) {
        switch op.kind {
        case .write(let patch, let mode):
            if mode == .replace {
                graph.replaceRecord(op.recordId, patch)
            } else {
                graph.putRecord(op.recordId, patch)
            }
        case .delete:
            graph.removeRecord(op.recordId)
        }
    }

    private func restoreEntity(_ recordId: CacheKey, snapshot: [String: JSONValue]?) {
        guard let snapshot else {
            graph.removeRecord(recordId)
            return
        }
        graph.replaceRecord(recordId, snapshot)
    }

    // MARK: - Connection ops

    private func applyConnectionOp(_ op: ConnectionOp) {
        var canonicalRecord = graph.getRecord(op.connectionKey) ?? [:]
        if canonicalRecord.isEmpty {
            // Ensure canonical exists.
            let pageInfoKey = "\(op.connectionKey).pageInfo"
            graph.putRecord(pageInfoKey, [
                CachebayConstants.typenameField: .string(CachebayConstants.connectionPageInfoTypename),
            ])
            canonicalRecord = [
                CachebayConstants.typenameField: .string(CachebayConstants.connectionTypename),
                CachebayConstants.connectionEdgesField: .refList([]),
                CachebayConstants.connectionPageInfoField: .ref(pageInfoKey),
            ]
            graph.replaceRecord(op.connectionKey, canonicalRecord)
            ConnectionIndex.clear(graph: graph, canonicalKey: op.connectionKey)
        }

        switch op.kind {
        case .linkNode(let entityKey, let meta, let position, let anchor):
            insertEdge(into: op.connectionKey, entityKey: entityKey, meta: meta, position: position, anchor: anchor)
        case .unlinkNode(let entityKey):
            removeEdge(from: op.connectionKey, entityKey: entityKey)
        case .patch(let update):
            applyConnectionPatch(op.connectionKey, update)
        }
    }

    // revertConnectionOp removed — connection baselines are restored via
    // `committedBaselines` in the main revert/commit flow, then surviving
    // layers replay their connection ops (see `replayEntityAndConnectionOps`).

    private func insertEdge(into canonicalKey: CacheKey, entityKey: CacheKey, meta: [String: JSONValue]?, position: EdgePosition, anchor: CacheKey?) {
        // Dedup by node: O(1) via the node index.
        if let existingEdge = ConnectionIndex.edgeKey(graph: graph, canonicalKey: canonicalKey, nodeKey: entityKey) {
            if let meta {
                graph.putRecord(existingEdge, meta)
            }
            return
        }

        var canonical = graph.getRecord(canonicalKey) ?? [:]
        var edgeRefs = canonical[CachebayConstants.connectionEdgesField]?.refList ?? []

        // Compute next edge index.
        let counterKey = "\(canonicalKey)::edgeCounter"
        let nextIndex = (graph.getRecord(counterKey)?["value"]?.int ?? 0) + 1
        graph.replaceRecord(counterKey, ["value": .int(nextIndex)])

        let nodeType = entityKey.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let edgeTypename = nodeType.isEmpty ? "Edge" : "\(nodeType)Edge"
        let edgeKey = "\(canonicalKey).edges.\(nextIndex)"

        var edgeRecord: [String: JSONValue] = [
            CachebayConstants.typenameField: .string(edgeTypename),
            CachebayConstants.connectionNodeField: .ref(entityKey),
        ]
        if let meta {
            for (k, v) in meta where k != CachebayConstants.typenameField && k != CachebayConstants.connectionNodeField {
                edgeRecord[k] = v
            }
        }
        graph.replaceRecord(edgeKey, edgeRecord)

        switch position {
        case .start:
            edgeRefs.insert(edgeKey, at: 0)
        case .end:
            edgeRefs.append(edgeKey)
        case .before, .after:
            // Anchor lookup is also O(1) now.
            let anchorEdge = anchor.flatMap { ConnectionIndex.edgeKey(graph: graph, canonicalKey: canonicalKey, nodeKey: $0) }
            let anchorIndex = anchorEdge.flatMap { edgeRefs.firstIndex(of: $0) } ?? -1
            if anchorIndex < 0 {
                if position == .before { edgeRefs.insert(edgeKey, at: 0) } else { edgeRefs.append(edgeKey) }
            } else {
                let insertAt = position == .before ? anchorIndex : anchorIndex + 1
                edgeRefs.insert(edgeKey, at: insertAt)
            }
        }

        canonical[CachebayConstants.connectionEdgesField] = .refList(edgeRefs)
        graph.replaceRecord(canonicalKey, canonical)
        ConnectionIndex.insert(graph: graph, canonicalKey: canonicalKey, nodeKey: entityKey, edgeKey: edgeKey)

        // Maintain `::cursorIndex` (cursor → position) — match cachebay-
        // web's `shiftCursorIndicesAfter` + `addCursorToIndex`. Without
        // this, the cursor index is stale after every optimistic
        // add/remove and the next paginate-after-cursor splices at the
        // wrong slot.
        if let insertPos = edgeRefs.firstIndex(of: edgeKey) {
            var index = readCursorIndex(canonicalKey)
            // Shift positions >= insertPos by +1.
            for (k, v) in index where v >= insertPos {
                index[k] = v + 1
            }
            // Add the new cursor (only if the edge meta included one).
            if let cursor = getEdgeCursor(edgeKey) {
                index[cursor] = insertPos
            }
            writeCursorIndex(canonicalKey, index)
        }

        // Unused counter hint silences the "nextIndex unused" warning if any.
        _ = nextIndex
    }

    private func removeEdge(from canonicalKey: CacheKey, entityKey: CacheKey) {
        guard let targetEdge = ConnectionIndex.edgeKey(graph: graph, canonicalKey: canonicalKey, nodeKey: entityKey) else {
            return
        }
        var canonical = graph.getRecord(canonicalKey) ?? [:]
        var edgeRefs = canonical[CachebayConstants.connectionEdgesField]?.refList ?? []
        if let idx = edgeRefs.firstIndex(of: targetEdge) {
            // Capture the removed cursor + position BEFORE we drop the
            // edge from the list so we can update `::cursorIndex`.
            let removedCursor = getEdgeCursor(targetEdge)
            edgeRefs.remove(at: idx)
            canonical[CachebayConstants.connectionEdgesField] = .refList(edgeRefs)
            graph.replaceRecord(canonicalKey, canonical)

            // Maintain cursor index — match cachebay-web's
            // `removeCursorFromIndex` + `shiftCursorIndicesAfter(_, -1)`.
            var index = readCursorIndex(canonicalKey)
            if let c = removedCursor {
                index.removeValue(forKey: c)
            }
            for (k, v) in index where v > idx {
                index[k] = v - 1
            }
            writeCursorIndex(canonicalKey, index)
        }
        ConnectionIndex.remove(graph: graph, canonicalKey: canonicalKey, nodeKey: entityKey)
    }

    // MARK: - Cursor index helpers (mirror Canonical's so Optimistic
    // can maintain the index without a circular dep on Canonical).

    private func cursorIndexKey(_ canonicalKey: CacheKey) -> CacheKey {
        "\(canonicalKey)::cursorIndex"
    }

    private func readCursorIndex(_ canonicalKey: CacheKey) -> [String: Int] {
        guard let rec = graph.getRecord(cursorIndexKey(canonicalKey)) else { return [:] }
        var out: [String: Int] = [:]
        out.reserveCapacity(rec.count)
        for (k, v) in rec {
            if case .int(let i) = v { out[k] = Int(i) }
        }
        return out
    }

    private func writeCursorIndex(_ canonicalKey: CacheKey, _ index: [String: Int]) {
        var rec: [String: JSONValue] = [:]
        rec.reserveCapacity(index.count)
        for (k, v) in index { rec[k] = .int(Int64(v)) }
        graph.replaceRecord(cursorIndexKey(canonicalKey), rec)
    }

    private func getEdgeCursor(_ edgeKey: CacheKey) -> String? {
        graph.getField(edgeKey, "cursor")?.string
    }

    private func applyConnectionPatch(_ canonicalKey: CacheKey, _ update: [String: JSONValue]) {
        var canonical = graph.getRecord(canonicalKey) ?? [:]
        if let pageInfo = update[CachebayConstants.connectionPageInfoField]?.object,
           let pageInfoRef = canonical[CachebayConstants.connectionPageInfoField]?.ref {
            graph.putRecord(pageInfoRef, pageInfo)
        }
        for (k, v) in update where k != CachebayConstants.connectionPageInfoField {
            canonical[k] = v
        }
        graph.replaceRecord(canonicalKey, canonical)
    }

    // MARK: - Baseline capture

    fileprivate func captureBaseline(_ layer: Layer, recordId: CacheKey) {
        lock.lock(); defer { lock.unlock() }
        if layer.touched.contains(recordId) { return }
        layer.touched.insert(recordId)
        // Record's pre-optimistic state is snapshotted once, globally.
        if committedBaselines[recordId] == nil {
            committedBaselines[recordId] = graph.getRecord(recordId)
        }
    }

    /// Capture the canonical record + every aux record the connection
    /// runtime maintains alongside it (`::nodeIndex`, `::cursorIndex`)
    /// so that on revert/commit they're restored as a unit. Without
    /// this, a stale `nodeIndex` entry can survive baseline restoration
    /// and silently break the next `insertEdge`'s dedup check or
    /// `removeEdge`'s targetEdge lookup.
    fileprivate func captureConnectionBaselines(_ layer: Layer, canonicalKey: CacheKey) {
        captureBaseline(layer, recordId: canonicalKey)
        captureBaseline(layer, recordId: ConnectionIndex.nodeIndexKey(canonicalKey))
        captureBaseline(layer, recordId: "\(canonicalKey)::cursorIndex")
    }

    fileprivate func resolveEntityRef(_ ref: EntityRef) -> CacheKey? {
        switch ref {
        case .key(let k): return k
        case .object(let o): return graph.identify(o)
        }
    }

    fileprivate func buildCanonicalKey(_ selector: ConnectionSelector) -> CacheKey {
        let parentId: CacheKey
        switch selector.parent {
        case .key(let k): parentId = (k == "Query" || k.isEmpty) ? CachebayConstants.rootID : k
        case .object(let o): parentId = graph.identify(o) ?? CachebayConstants.rootID
        }
        // Build a synthetic PlanField for the canonical key helper.
        let filters = selector.filters
        let filtersList = Array(filters.keys)
        let stringify: @Sendable ([String: JSONValue]) -> String = { vars in
            let mask = filtersList
            var parts: [String] = []
            for k in mask.sorted() {
                if let v = vars[k] { parts.append("\"\(k)\":" + stableStringify(v)) }
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
        let field = PlanField(
            responseKey: selector.key, fieldName: selector.key,
            selectionSet: nil, selectionMap: nil, typeCondition: nil,
            expectedArgNames: filtersList,
            buildArgs: { _ in filters },
            stringifyArgs: stringify,
            isConnection: true, connectionKey: selector.key, connectionFilters: filtersList,
            connectionMode: nil, pageArgs: nil,
            skipIf: nil, includeIf: nil, selId: ""
        )
        return Keys.buildConnectionCanonicalKey(field: field, parentId: parentId, variables: filters)
    }

    // MARK: - BuilderImpl

    fileprivate final class BuilderImpl: OptimisticBuilder, @unchecked Sendable {
        let optimistic: Optimistic
        let layer: Layer
        let recording: Bool

        init(optimistic: Optimistic, layer: Layer, recording: Bool) {
            self.optimistic = optimistic
            self.layer = layer
            self.recording = recording
        }

        func patch(_ target: EntityRef, _ patch: [String: JSONValue], mode: EntityPatchMode) {
            guard let recordId = optimistic.resolveEntityRef(target) else { return }
            if patch.isEmpty { return }
            if recording {
                optimistic.captureBaseline(layer, recordId: recordId)
                layer.entityOps.append(EntityOp(recordId: recordId, kind: .write(patch: patch, mode: mode)))
            }
            if mode == .replace { optimistic.graph.replaceRecord(recordId, patch) }
            else { optimistic.graph.putRecord(recordId, patch) }
        }

        func patch(_ target: EntityRef, mode: EntityPatchMode, _ build: @Sendable (_ prev: [String: JSONValue]) -> [String: JSONValue]) {
            guard let recordId = optimistic.resolveEntityRef(target) else { return }
            // Read the current snapshot from the graph and pass it to
            // the closure so callers can compute a delta (e.g.
            // `prev → ({ count: prev.count + 1 })`). Mirrors cachebay-
            // web's `b.patch(target, prev => ({...}))` form.
            let prev = optimistic.graph.getRecord(recordId) ?? [:]
            let computed = build(prev)
            if computed.isEmpty { return }
            if recording {
                optimistic.captureBaseline(layer, recordId: recordId)
                layer.entityOps.append(EntityOp(recordId: recordId, kind: .write(patch: computed, mode: mode)))
            }
            if mode == .replace { optimistic.graph.replaceRecord(recordId, computed) }
            else { optimistic.graph.putRecord(recordId, computed) }
        }

        func delete(_ target: EntityRef) {
            guard let recordId = optimistic.resolveEntityRef(target) else { return }
            if recording {
                optimistic.captureBaseline(layer, recordId: recordId)
                layer.entityOps.append(EntityOp(recordId: recordId, kind: .delete))
            }
            optimistic.graph.removeRecord(recordId)
        }

        func connection(_ selector: ConnectionSelector) -> ConnectionAPI {
            let canonicalKey = optimistic.buildCanonicalKey(selector)
            return ConnectionAPIImpl(optimistic: optimistic, layer: layer, recording: recording, canonicalKey: canonicalKey)
        }

        func connection(key canonicalKey: CacheKey) -> ConnectionAPI {
            return ConnectionAPIImpl(optimistic: optimistic, layer: layer, recording: recording, canonicalKey: canonicalKey)
        }

        func canonicalTypename(_ typename: String) -> String {
            optimistic.graph.canonicalTypename(typename)
        }

        func writeFragment(
            document: QueryDocument,
            fragmentName: String,
            rootId: CacheKey,
            variables: [String: JSONValue],
            data: [String: JSONValue]
        ) {
            // Need both the planner (to resolve the fragment plan) and
            // the documents engine (to perform the normalize). Both are
            // wired by `CachebayClient.init`; missing them is a
            // misconfigured Optimistic instance — silently no-op
            // rather than crash.
            guard let planner = optimistic.planner,
                  let documents = optimistic.documents,
                  let plan = try? planner.getPlan(document, fragmentName: fragmentName)
            else { return }

            // Capture baselines for every entity record the data tree
            // identifies, BEFORE handing off to `documents.normalize`.
            // The normalize machinery walks the plan + data, writes
            // each entity at its canonical key and links them via
            // `.ref` / `.refList` — but it doesn't capture baselines.
            // We pre-walk the data shape to cover the entity universe
            // we're about to touch; revert restores those records to
            // their pre-write snapshot.
            if recording {
                optimistic.captureBaseline(layer, recordId: rootId)
                optimistic.captureBaselinesForEntityTree(layer, data: .object(data))
            }

            documents.normalize(plan: plan, variables: variables, data: .object(data), rootId: rootId)
        }

        func patchFragment(
            document: QueryDocument,
            fragmentName: String,
            rootId: CacheKey,
            variables: [String: JSONValue],
            data: [String: JSONValue],
            mode: EntityPatchMode
        ) {
            // Resolve the plan once. If the planner can't reach the
            // document (misconfigured Optimistic instance), fall back to
            // a dumb patch so the surface stays usable — though
            // inline-container fields will silence under that fallback.
            // The protocol's default impl does the same; we duplicate it
            // here because the planner check is per-call.
            guard let planner = optimistic.planner,
                  let plan = try? planner.getPlan(document, fragmentName: fragmentName)
            else {
                patch(.key(rootId), data, mode: mode)
                return
            }

            // Translate the data into a flat list of (recordId, fields)
            // ops. Synthetic-container keys ride the same `patch(...)`
            // pathway as the root, so each gets a baseline captured and
            // revert restores them properly.
            let ops = optimistic.translateTypedPatch(
                plan: plan,
                variables: variables,
                rootId: rootId,
                data: data
            )
            for op in ops {
                patch(.key(op.recordId), op.fields, mode: mode)
            }
        }
    }

    /// One translated write produced by `translateTypedPatch`.
    fileprivate struct TranslatedPatchOp {
        let recordId: CacheKey
        let fields: [String: JSONValue]
    }

    /// Translate a typed-patch `__data` dict into a flat list of
    /// (recordId, fields) writes. Mirrors the shape `documents.normalize`
    /// produces for the same data, but scoped strictly to the fields the
    /// caller touched — never walks into the cache beyond what the
    /// patch references.
    ///
    /// The translation rules per (planField, value):
    /// - **selection-set field + `.object` + identifiable entity**
    ///   (`graph.identify(obj)` succeeds): write `.ref(entityKey)` onto
    ///   the parent; emit a sub-op writing `obj`'s recognised fields to
    ///   `entityKey`.
    /// - **selection-set field + `.object` + no identity**: inline
    ///   container. Write `.ref("<parent>.<storeKey>")` onto the parent;
    ///   emit a sub-op writing the contents to that synthetic key.
    /// - **selection-set field + `.array`**: walk each element as
    ///   above, collect refs, write `.refList(refs)` onto the parent.
    ///   Inline-container list elements are keyed
    ///   `"<parent>.<storeKey>.<index>"`.
    /// - **selection-set field + `.ref` / `.refList` / `.null` /
    ///   `.undefined`**: pass through unchanged — caller already wrote
    ///   graph-shape, or is explicitly clearing.
    /// - **scalar field**: pass through unchanged.
    ///
    /// Recursive: nested objects (entity-in-entity, inline-in-inline,
    /// entity-in-inline, etc.) all walk through the same rules with
    /// the appropriate parent context.
    fileprivate func translateTypedPatch(
        plan: CachePlan,
        variables: [String: JSONValue],
        rootId: CacheKey,
        data: [String: JSONValue]
    ) -> [TranslatedPatchOp] {
        var rootFields: [String: JSONValue] = [:]
        var subOps: [TranslatedPatchOp] = []
        translateLevel(
            data: data,
            selectionMap: plan.rootSelectionMap,
            parentId: rootId,
            variables: variables,
            outFields: &rootFields,
            subOps: &subOps
        )
        // Root op first — the field links must exist when revert / replay
        // walks the layer's entityOps. Sub-ops follow in walk order.
        var ops: [TranslatedPatchOp] = [TranslatedPatchOp(recordId: rootId, fields: rootFields)]
        ops.append(contentsOf: subOps)
        return ops
    }

    private func translateLevel(
        data: [String: JSONValue],
        selectionMap: [String: PlanField],
        parentId: CacheKey,
        variables: [String: JSONValue],
        outFields: inout [String: JSONValue],
        subOps: inout [TranslatedPatchOp]
    ) {
        for (responseKey, value) in data {
            // No matching plan field — pass through under the response
            // key. Covers `__typename`/`id` (always passed) and any
            // extra hand-written keys outside the plan's selection set.
            guard let field = selectionMap[responseKey] else {
                outFields[responseKey] = value
                continue
            }
            translateValue(
                value: value,
                field: field,
                parentId: parentId,
                variables: variables,
                outFields: &outFields,
                subOps: &subOps
            )
        }
    }

    private func translateValue(
        value: JSONValue,
        field: PlanField,
        parentId: CacheKey,
        variables: [String: JSONValue],
        outFields: inout [String: JSONValue],
        subOps: inout [TranslatedPatchOp]
    ) {
        let storeKey = Keys.buildFieldKey(field: field, variables: variables)

        // Scalar field — pass through whatever JSONValue the caller
        // supplied. Type-correctness is the caller's problem; we don't
        // re-validate here.
        guard let childSelectionMap = field.selectionMap else {
            outFields[storeKey] = value
            return
        }

        switch value {
        case .null, .undefined, .ref, .refList:
            // Caller already gave us graph-shape, OR is clearing the
            // field. Pass through.
            outFields[storeKey] = value
        case .object(let obj):
            translateObject(
                obj: obj,
                field: field,
                storeKey: storeKey,
                parentId: parentId,
                childSelectionMap: childSelectionMap,
                variables: variables,
                outFields: &outFields,
                subOps: &subOps
            )
        case .array(let arr):
            translateArray(
                arr: arr,
                field: field,
                storeKey: storeKey,
                parentId: parentId,
                childSelectionMap: childSelectionMap,
                variables: variables,
                outFields: &outFields,
                subOps: &subOps
            )
        default:
            // Scalar on a field whose plan says it should have a
            // selection set. Caller error, but tolerate — pass through
            // and let the strict materializer surface the warning.
            outFields[storeKey] = value
        }
    }

    private func translateObject(
        obj: [String: JSONValue],
        field: PlanField,
        storeKey: String,
        parentId: CacheKey,
        childSelectionMap: [String: PlanField],
        variables: [String: JSONValue],
        outFields: inout [String: JSONValue],
        subOps: inout [TranslatedPatchOp]
    ) {
        // Try to resolve as an entity (typename + identifying key).
        if let entityKey = graph.identify(obj) {
            outFields[storeKey] = .ref(entityKey)
            var entityFields: [String: JSONValue] = [:]
            translateLevel(
                data: obj,
                selectionMap: childSelectionMap,
                parentId: entityKey,
                variables: variables,
                outFields: &entityFields,
                subOps: &subOps
            )
            subOps.append(TranslatedPatchOp(recordId: entityKey, fields: entityFields))
            return
        }
        // Inline container — synthetic key under the parent.
        let containerKey = "\(parentId).\(storeKey)"
        outFields[storeKey] = .ref(containerKey)
        var containerFields: [String: JSONValue] = [:]
        translateLevel(
            data: obj,
            selectionMap: childSelectionMap,
            parentId: containerKey,
            variables: variables,
            outFields: &containerFields,
            subOps: &subOps
        )
        subOps.append(TranslatedPatchOp(recordId: containerKey, fields: containerFields))
    }

    private func translateArray(
        arr: [JSONValue],
        field: PlanField,
        storeKey: String,
        parentId: CacheKey,
        childSelectionMap: [String: PlanField],
        variables: [String: JSONValue],
        outFields: inout [String: JSONValue],
        subOps: inout [TranslatedPatchOp]
    ) {
        var refs: [CacheKey] = []
        refs.reserveCapacity(arr.count)
        for (i, item) in arr.enumerated() {
            switch item {
            case .object(let obj):
                if let entityKey = graph.identify(obj) {
                    refs.append(entityKey)
                    var entityFields: [String: JSONValue] = [:]
                    translateLevel(
                        data: obj,
                        selectionMap: childSelectionMap,
                        parentId: entityKey,
                        variables: variables,
                        outFields: &entityFields,
                        subOps: &subOps
                    )
                    subOps.append(TranslatedPatchOp(recordId: entityKey, fields: entityFields))
                } else {
                    let containerKey = "\(parentId).\(storeKey).\(i)"
                    refs.append(containerKey)
                    var containerFields: [String: JSONValue] = [:]
                    translateLevel(
                        data: obj,
                        selectionMap: childSelectionMap,
                        parentId: containerKey,
                        variables: variables,
                        outFields: &containerFields,
                        subOps: &subOps
                    )
                    subOps.append(TranslatedPatchOp(recordId: containerKey, fields: containerFields))
                }
            case .ref(let r):
                refs.append(r)
            default:
                // Non-object element in a selection-set list. Caller
                // error; skip to avoid corrupting the refList.
                continue
            }
        }
        outFields[storeKey] = .refList(refs)
    }

    /// Walk a data tree and capture baselines for every object that
    /// resolves to an entity cache key (`__typename + id`). Recurses
    /// into nested objects and arrays — sibling to
    /// `documents.normalize`'s entity-walking, but baseline-only.
    fileprivate func captureBaselinesForEntityTree(_ layer: Layer, data: JSONValue) {
        switch data {
        case .object(let obj):
            if let key = graph.identify(obj) {
                captureBaseline(layer, recordId: key)
            }
            for (_, v) in obj {
                captureBaselinesForEntityTree(layer, data: v)
            }
        case .array(let arr):
            for item in arr {
                captureBaselinesForEntityTree(layer, data: item)
            }
        default:
            break
        }
    }

    fileprivate final class ConnectionAPIImpl: ConnectionAPI, @unchecked Sendable {
        let optimistic: Optimistic
        let layer: Layer
        let recording: Bool
        let canonicalKey: CacheKey
        var key: CacheKey { canonicalKey }

        init(optimistic: Optimistic, layer: Layer, recording: Bool, canonicalKey: CacheKey) {
            self.optimistic = optimistic
            self.layer = layer
            self.recording = recording
            self.canonicalKey = canonicalKey
        }

        func linkNode(_ ref: EntityRef, options: LinkNodeOptions) {
            // Connection-link primitive — purely structural. Inserts an
            // edge ref into the canonical connection record and synthesises
            // the edge record (`__typename`, `node` ref, optional meta).
            // Does NOT write entity-record scalar fields. Entity records
            // are owned by `documents.normalize` (auto from query /
            // mutation / subscription responses, or explicit via
            // `writeFragment`).
            //
            // Why: subscription pipelines auto-normalize each frame
            // BEFORE the user's for-await body runs. A user handler that
            // captures the frame's payload and later calls this primitive
            // in a deferred Task races against subsequent frames — if the
            // primitive wrote scalars from the captured (now-stale) node,
            // last-write-wins would silently revert later normalize state.
            // Taking an `EntityRef` instead of a node dict makes that
            // race impossible by construction: the API surface has no
            // scalar parameter to leak through.
            guard let entityKey = optimistic.resolveEntityRef(ref) else { return }
            if recording { optimistic.captureBaseline(layer, recordId: entityKey) }

            let op = ConnectionOp(connectionKey: canonicalKey, kind: .linkNode(
                entityKey: entityKey,
                meta: options.edge,
                position: options.position,
                anchor: options.anchor.flatMap { optimistic.resolveEntityRef($0) }
            ))
            if recording {
                optimistic.captureConnectionBaselines(layer, canonicalKey: canonicalKey)
                layer.connectionOps.append(op)
            }
            optimistic.applyConnectionOp(op)
        }

        func unlinkNode(_ ref: EntityRef) {
            guard let entityKey = optimistic.resolveEntityRef(ref) else { return }
            let op = ConnectionOp(connectionKey: canonicalKey, kind: .unlinkNode(entityKey: entityKey))
            if recording {
                optimistic.captureConnectionBaselines(layer, canonicalKey: canonicalKey)
                layer.connectionOps.append(op)
            }
            optimistic.applyConnectionOp(op)
        }

        func patch(_ update: [String: JSONValue]) {
            if update.isEmpty { return }
            let op = ConnectionOp(connectionKey: canonicalKey, kind: .patch(update))
            if recording {
                optimistic.captureConnectionBaselines(layer, canonicalKey: canonicalKey)
                if let pageInfoRef = optimistic.graph.getRecord(canonicalKey)?[CachebayConstants.connectionPageInfoField]?.ref {
                    optimistic.captureBaseline(layer, recordId: pageInfoRef)
                }
                layer.connectionOps.append(op)
            }
            optimistic.applyConnectionOp(op)
        }

        func patch(_ build: @Sendable (_ prev: [String: JSONValue]) -> [String: JSONValue]) {
            // Read-modify-write: pull the current canonical snapshot
            // (`[:]` if absent) and let the closure compute the patch.
            // Mirrors cachebay-web's `c.patch(prev => ({...}))`.
            let prev = optimistic.graph.getRecord(canonicalKey) ?? [:]
            let computed = build(prev)
            patch(computed)
        }

        func canonicalTypename(_ typename: String) -> String {
            optimistic.graph.canonicalTypename(typename)
        }
    }
}

// MARK: - Optimistic → Canonical replayer bridge

extension Optimistic: OptimisticReplayer {}
