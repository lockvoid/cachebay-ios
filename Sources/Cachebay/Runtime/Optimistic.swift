import Foundation

/// How `b.patch(_:_:mode:)` reconciles its patch with the existing
/// entity record. `.merge` (default) shallow-merges fields;
/// `.replace` writes exactly the patch and drops everything else.
public enum EntityPatchMode: Sendable {
    case merge
    case replace
}

/// Where `b.connection(...).addNode` inserts the new edge. `.before`
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

public struct AddNodeOptions: Sendable {
    public var position: EdgePosition = .end
    public var anchor: EntityRef? = nil
    public var edge: [String: JSONValue]? = nil
    /// Optional fragment plan for plan-aware entity writes. When provided,
    /// `addNode` walks the fragment plan to (a) initialize nested
    /// `@connection` canonicals as empty (or from inline `edges`/`pageInfo`
    /// in the node data) and (b) strip selection-set fields from the
    /// entity-record patch so existing ref/refList links stay intact.
    /// Mirrors cachebay-web's `addNode(node, { fragment, fragmentName, variables })`.
    public var fragmentDocument: QueryDocument? = nil
    public var fragmentName: String? = nil
    public var fragmentVariables: [String: JSONValue] = [:]
    public init(position: EdgePosition = .end, anchor: EntityRef? = nil, edge: [String: JSONValue]? = nil) {
        self.position = position
        self.anchor = anchor
        self.edge = edge
    }
    public init(
        position: EdgePosition = .end,
        anchor: EntityRef? = nil,
        edge: [String: JSONValue]? = nil,
        fragmentDocument: QueryDocument?,
        fragmentName: String? = nil,
        fragmentVariables: [String: JSONValue] = [:]
    ) {
        self.position = position
        self.anchor = anchor
        self.edge = edge
        self.fragmentDocument = fragmentDocument
        self.fragmentName = fragmentName
        self.fragmentVariables = fragmentVariables
    }
}

public struct OptimisticTransaction: Sendable {
    public let commit: @Sendable (_ data: JSONValue?) -> Void
    public let revert: @Sendable () -> Void
    /// Drop the layer without restoring baselines or re-running the
    /// builder closure. Use when the server's response was already
    /// normalized into the cache (via `executeMutation`'s pipeline)
    /// and is authoritative — calling `commit(_:)` here would
    /// `replaceRecord` each touched entity with the pre-optimistic
    /// snapshot, **wiping any server-side updates** to fields that
    /// the optimistic patch didn't touch (e.g. `Project.clips`
    /// updated on the server when only `Project.updatedAt` was
    /// optimistically patched).
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
    /// ```swift
    /// let tx = client.modifyOptimistic { tx, _ in
    ///     tx.patch(fragment: ProjectFields.self, id: id) { p in
    ///         p.updatedAt = Date().iso8601String
    ///     }
    /// }
    /// let result = try await client.executeMutation(...)
    /// if result.error != nil { tx.revert(); throw ... }
    /// tx.dispose()  // server already normalized; just drop the layer
    /// ```
    public let dispose: @Sendable () -> Void
}

public extension OptimisticTransaction {
    /// Typed commit for callers that have a typed mutation/operation
    /// response. Wraps the typed `__data` into the `JSONValue.object`
    /// shape the underlying `commit(_:)` closure expects, so the
    /// builder closure's `BuilderContext.data` (`ctx.data`) sees the
    /// canonical server data during the replay-commit cycle.
    ///
    /// Use this instead of `.commit(nil)` whenever you have a typed
    /// server response on the success branch — `.commit(nil)`
    /// discards the server data, which is correct only when no server
    /// response is available (or when the optimistic ops are already
    /// idempotent against the server's state).
    ///
    /// ```swift
    /// let result = try await client.executeMutation(...)
    /// // … typed entity available on result.data …
    /// optimistic.commit(result.data)
    /// ```
    func commit<O: OperationData>(_ data: O?) {
        commit(data.map { JSONValue.object($0.__data) })
    }
}

public enum BuilderPhase: Sendable { case optimistic; case commit }

public struct BuilderContext: Sendable {
    public let phase: BuilderPhase
    public let data: JSONValue?
}

/// The builder surface used inside `cache.modifyOptimistic { tx, ctx in ... }`.
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
}

public protocol ConnectionAPI: AnyObject, Sendable {
    var key: CacheKey { get }
    func addNode(_ node: [String: JSONValue], options: AddNodeOptions)
    func removeNode(_ ref: EntityRef)
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
    /// the typed `removeNode<F>(fragment:id:)` overload can canonicalise
    /// the fragment's `onTypename` to the right cache namespace.
    func canonicalTypename(_ typename: String) -> String
}

public final class Optimistic: @unchecked Sendable {
    private let graph: Graph
    private let planner: Planner?
    private let lock = NSRecursiveLock()

    fileprivate enum EntityOpKind: Sendable { case write(patch: [String: JSONValue], mode: EntityPatchMode); case delete }
    fileprivate enum ConnectionOpKind: Sendable {
        case addNode(entityKey: CacheKey, meta: [String: JSONValue]?, position: EdgePosition, anchor: CacheKey?)
        case removeNode(entityKey: CacheKey)
        case patch([String: JSONValue])
    }
    fileprivate struct EntityOp: Sendable { let recordId: CacheKey; let kind: EntityOpKind }
    fileprivate struct ConnectionOp: Sendable { let connectionKey: CacheKey; let kind: ConnectionOpKind }

    fileprivate final class Layer: @unchecked Sendable {
        let id: Int
        var entityOps: [EntityOp] = []
        var connectionOps: [ConnectionOp] = []
        var touched: Set<CacheKey> = []
        let builder: @Sendable (_ tx: OptimisticBuilder, _ ctx: BuilderContext) -> Void
        init(id: Int, builder: @escaping @Sendable (_ tx: OptimisticBuilder, _ ctx: BuilderContext) -> Void) {
            self.id = id
            self.builder = builder
        }
    }

    fileprivate var layers: [Layer] = []
    private var nextLayerId: Int = 1
    /// One-shot pre-optimistic snapshot captured for every record touched by
    /// any layer. Restored on revert/commit before replaying surviving layers.
    private var committedBaselines: [CacheKey: [String: JSONValue]?] = [:]

    public init(graph: Graph, planner: Planner? = nil) {
        self.graph = graph
        self.planner = planner
    }

    public func modifyOptimistic(_ builder: @escaping @Sendable (_ tx: OptimisticBuilder, _ ctx: BuilderContext) -> Void) -> OptimisticTransaction {
        lock.lock()
        nextLayerId += 1
        let layer = Layer(id: nextLayerId, builder: builder)
        layers.append(layer)
        lock.unlock()

        let b = BuilderImpl(optimistic: self, layer: layer, recording: true)
        builder(b, BuilderContext(phase: .optimistic, data: nil))
        graph.flush()

        let weakSelf = self
        return OptimisticTransaction(
            commit: { [weak weakSelf] data in
                weakSelf?.commit(layer: layer, data: data)
            },
            revert: { [weak weakSelf] in
                weakSelf?.revert(layer: layer)
            },
            dispose: { [weak weakSelf] in
                weakSelf?.dispose(layer: layer)
            }
        )
    }

    /// Single-phase variant of `modifyOptimistic`. Skips the
    /// optimistic phase entirely and runs the builder once with
    /// `phase: .commit, data: nil`, applying ops directly to the
    /// base graph without recording a layer.
    ///
    /// Use this when you've already awaited the server's response
    /// and only want to write the result into cache via the builder
    /// API (`b.connection(...).addNode(...)` etc.). Avoids the
    /// "double-write" of the standard form, where the closure runs
    /// at both `.optimistic` AND `.commit` phases — wasteful when
    /// you know there's no temp/optimistic state to project.
    ///
    /// Mirrors cachebay-web's "commit-only" pattern for
    /// post-mutation cache writes; iOS callers reach it via
    /// `client.modifyOptimistic(autoCommit: true) { … }`.
    public func applyAutoCommit(_ builder: @Sendable (_ tx: OptimisticBuilder, _ ctx: BuilderContext) -> Void) {
        // Dummy layer — never appended to `layers`, never replayed,
        // never reverted. Held only so BuilderImpl has a stable
        // reference; in non-recording mode it's never read.
        let dummy = Layer(id: 0, builder: { _, _ in })
        let b = BuilderImpl(optimistic: self, layer: dummy, recording: false)
        builder(b, BuilderContext(phase: .commit, data: nil))
        graph.flush()
    }

    /// Replay summary: which entity keys were added (`addNode`) and
    /// which were removed (`removeNode`) within the scope of this
    /// replay. Mirrors cachebay-web's
    /// `replayOptimistic({connections}) → {added: Set, removed: Set}`.
    public struct ReplayResult: Sendable {
        public let added: Set<CacheKey>
        public let removed: Set<CacheKey>
        public init(added: Set<CacheKey> = [], removed: Set<CacheKey> = []) {
            self.added = added
            self.removed = removed
        }
    }

    @discardableResult
    public func replay(connectionKeys: [CacheKey]) -> ReplayResult {
        lock.lock()
        let sorted = layers.sorted { $0.id < $1.id }
        lock.unlock()
        let scope = connectionKeys.isEmpty ? nil : Set(connectionKeys)
        var added: Set<CacheKey> = []
        var removed: Set<CacheKey> = []
        for layer in sorted {
            for op in layer.entityOps { applyEntityOp(op) }
            for op in layer.connectionOps {
                if let scope, !scope.contains(op.connectionKey) { continue }
                applyConnectionOp(op)
                switch op.kind {
                case .addNode(let entityKey, _, _, _):
                    added.insert(entityKey)
                case .removeNode(let entityKey):
                    removed.insert(entityKey)
                case .patch:
                    break
                }
            }
        }
        return ReplayResult(added: added, removed: removed)
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

    private func commit(layer: Layer, data: JSONValue?) {
        lock.lock()
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

        let b = BuilderImpl(optimistic: self, layer: layer, recording: false)
        layer.builder(b, BuilderContext(phase: .commit, data: data))
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
        case .addNode(let entityKey, let meta, let position, let anchor):
            insertEdge(into: op.connectionKey, entityKey: entityKey, meta: meta, position: position, anchor: anchor)
        case .removeNode(let entityKey):
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
            connectionMode: nil, pageArgs: nil, selId: ""
        )
        return Keys.buildConnectionCanonicalKey(field: field, parentId: parentId, variables: filters)
    }

    // MARK: - Plan-aware addNode helpers

    /// Stamp `__typename` from the plan's `rootTypename` when the node
    /// data omits it. Mirrors web's `processedNode = { __typename: plan.rootTypename, ...processedNode }`
    /// (`optimistic.ts:961`).
    fileprivate func stampTypenameFromPlan(_ node: [String: JSONValue], plan: CachePlan) -> [String: JSONValue] {
        if node[CachebayConstants.typenameField] != nil { return node }
        if plan.rootTypename.isEmpty { return node }
        var out = node
        out[CachebayConstants.typenameField] = .string(plan.rootTypename)
        return out
    }

    /// Strip fields with selection sets (entities, sub-entities, connections)
    /// from the entity-record patch. Without this, the merge in
    /// `graph.putRecord(entityKey, node)` would overwrite existing
    /// `ref`/`refList`/`null` links with raw arrays/objects from the
    /// node's `__data`, triggering "unexpected link shape" misses on
    /// the materialize path. We keep `__typename`, scalars, and
    /// scalar-array fields. Selection-set fields are handled by
    /// `initializeNestedConnections` (or by the server-cycle normalize).
    ///
    /// Two-pass strip:
    ///   1. **Plan-aware** — every field the fragment plan marks with
    ///      a selection set, regardless of the data shape. Catches the
    ///      "fragment field with empty array data" case
    ///      (`clips: []` for a connection-typed field).
    ///   2. **Shape-aware** — for fields the plan doesn't know about
    ///      (e.g. extra selections on the operation outside the
    ///      fragment), strip values that look like sub-entities: an
    ///      `.object(...)` carrying `__typename`, or an `.array(...)`
    ///      whose first object element carries `__typename`. Catches
    ///      mutation-level extras like `elements { ... }` selected
    ///      outside the spread fragment.
    ///
    /// Plain JSON-scalar objects (no `__typename`) and scalar arrays
    /// survive both passes — those are valid graph values.
    fileprivate func stripSelectionSetFields(_ node: [String: JSONValue], fromPlanFields fields: [PlanField]) -> [String: JSONValue] {
        var out = node
        // Pass 1: plan-aware strip.
        for field in fields where field.selectionSet != nil {
            out.removeValue(forKey: field.responseKey)
        }
        // Pass 2: shape-aware strip for fields the plan didn't cover.
        for (k, v) in out {
            if k == CachebayConstants.typenameField || k == CachebayConstants.idField { continue }
            if isEntityShaped(v) { out.removeValue(forKey: k) }
        }
        return out
    }

    /// True when the value carries entity-record shape: a typed object
    /// (`__typename`) or an array of typed objects. These need refs in
    /// the graph, never inline storage on the parent record.
    fileprivate func isEntityShaped(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let o):
            return o[CachebayConstants.typenameField] != nil
        case .array(let arr):
            for item in arr {
                if case .object(let o) = item, o[CachebayConstants.typenameField] != nil { return true }
            }
            return false
        default:
            return false
        }
    }

    /// Walk the fragment plan's root and initialize empty `@connection`
    /// canonical records for every connection field. Idempotent — skips
    /// connections that already exist in the graph. Uses inline
    /// `edges`/`pageInfo` from `data` when present (rare for optimistic
    /// adds, common for fragment-with-inline-data tests). Mirrors web
    /// `initializeNestedConnections` (`optimistic.ts:742`).
    fileprivate func initializeNestedConnections(
        layer: Layer,
        recording: Bool,
        parentKey: CacheKey,
        fields: [PlanField],
        variables: [String: JSONValue],
        data: [String: JSONValue]
    ) {
        for field in fields {
            if field.isConnection {
                let connectionKey = Keys.buildConnectionCanonicalKey(field: field, parentId: parentKey, variables: variables)
                // Idempotency: existing canonical wins. Optimistic
                // re-init must never destroy server-merged pagination
                // state.
                if graph.getRecord(connectionKey) != nil { continue }

                if recording {
                    captureBaseline(layer, recordId: connectionKey)
                    captureBaseline(layer, recordId: "\(connectionKey).pageInfo")
                    captureBaseline(layer, recordId: cursorIndexKey(connectionKey))
                }

                // Pull inline pageInfo / edges from the node data when
                // present. Empty defaults otherwise.
                var inlinePageInfo: [String: JSONValue] = [:]
                var inlineEdges: [JSONValue] = []
                if case .object(let connData) = data[field.responseKey] ?? .undefined {
                    if case .object(let pi) = connData[CachebayConstants.connectionPageInfoField] ?? .undefined {
                        inlinePageInfo = pi
                    }
                    if case .array(let edges) = connData[CachebayConstants.connectionEdgesField] ?? .undefined {
                        inlineEdges = edges
                    }
                }

                // Write pageInfo record.
                let pageInfoKey: CacheKey = "\(connectionKey).pageInfo"
                var pageInfoRecord: [String: JSONValue] = [
                    CachebayConstants.typenameField: .string(CachebayConstants.connectionPageInfoTypename),
                    "startCursor": inlinePageInfo["startCursor"] ?? .null,
                    "endCursor": inlinePageInfo["endCursor"] ?? .null,
                    "hasNextPage": inlinePageInfo["hasNextPage"] ?? .bool(false),
                    "hasPreviousPage": inlinePageInfo["hasPreviousPage"] ?? .bool(false),
                ]
                // Carry through any extra pageInfo fields the caller passed.
                for (k, v) in inlinePageInfo where pageInfoRecord[k] == nil {
                    pageInfoRecord[k] = v
                }
                graph.replaceRecord(pageInfoKey, pageInfoRecord)

                // Process inline edges (write node, build edge record, push ref).
                var edgeRefs: [CacheKey] = []
                for (i, edgeAny) in inlineEdges.enumerated() {
                    guard case .object(let edge) = edgeAny else { continue }
                    guard case .object(let nodeObj) = edge["node"] ?? .undefined else { continue }
                    guard let nodeKey = graph.identify(nodeObj) else { continue }

                    if recording { captureBaseline(layer, recordId: nodeKey) }
                    graph.putRecord(nodeKey, nodeObj)

                    let edgeKey: CacheKey = "\(connectionKey).edges.\(i)"
                    var edgeRecord: [String: JSONValue] = [:]
                    let nodeTypename = nodeObj[CachebayConstants.typenameField]?.string ?? ""
                    let edgeTypename = nodeTypename.isEmpty ? "Edge" : "\(nodeTypename)Edge"
                    edgeRecord[CachebayConstants.typenameField] = edge[CachebayConstants.typenameField] ?? .string(edgeTypename)
                    edgeRecord["node"] = .ref(nodeKey)
                    for (k, v) in edge where k != CachebayConstants.typenameField && k != "node" {
                        edgeRecord[k] = v
                    }
                    if recording { captureBaseline(layer, recordId: edgeKey) }
                    graph.replaceRecord(edgeKey, edgeRecord)
                    edgeRefs.append(edgeKey)
                }

                // Write the connection canonical record.
                let connectionRecord: [String: JSONValue] = [
                    CachebayConstants.typenameField: .string(CachebayConstants.connectionTypename),
                    CachebayConstants.connectionEdgesField: .refList(edgeRefs),
                    CachebayConstants.connectionPageInfoField: .ref(pageInfoKey),
                ]
                graph.replaceRecord(connectionKey, connectionRecord)

                // Initialize an empty cursor index for this connection.
                writeCursorIndex(connectionKey, [:])
                continue
            }

            // Recurse into nested entity selections (non-connection
            // fields with selection sets). When the data carries a
            // sub-entity object, walk its plan against the resolved
            // child id so nested connections inside sub-entities get
            // initialised too.
            if let children = field.selectionSet, !children.isEmpty {
                if case .object(let childObj) = data[field.responseKey] ?? .undefined {
                    if let childId = graph.identify(childObj) {
                        initializeNestedConnections(
                            layer: layer,
                            recording: recording,
                            parentKey: childId,
                            fields: children,
                            variables: variables,
                            data: childObj
                        )
                    }
                }
            }
        }
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

        func addNode(_ node: [String: JSONValue], options: AddNodeOptions) {
            // Plan-aware path: when a fragment is provided, walk the plan
            // root to (a) initialize nested @connection canonicals and
            // (b) compute an entity-record patch that excludes
            // selection-set fields so existing ref/refList links stay
            // intact. This matches cachebay-web's
            // `addNode(node, { fragment, fragmentName, variables })`
            // (`optimistic.ts:742` `initializeNestedConnections`).
            let entityPatch: [String: JSONValue]
            if let doc = options.fragmentDocument, let planner = optimistic.planner,
               let plan = try? planner.getPlan(doc, fragmentName: options.fragmentName) {
                let stamped = optimistic.stampTypenameFromPlan(node, plan: plan)
                guard let entityKey = optimistic.graph.identify(stamped) else { return }
                if recording { optimistic.captureBaseline(layer, recordId: entityKey) }
                optimistic.initializeNestedConnections(
                    layer: layer,
                    recording: recording,
                    parentKey: entityKey,
                    fields: plan.root,
                    variables: options.fragmentVariables,
                    data: stamped
                )
                entityPatch = optimistic.stripSelectionSetFields(stamped, fromPlanFields: plan.root)
                optimistic.graph.putRecord(entityKey, entityPatch)

                if recording {
                    layer.entityOps.append(EntityOp(
                        recordId: entityKey,
                        kind: .write(patch: entityPatch, mode: .merge)
                    ))
                }

                let op = ConnectionOp(connectionKey: canonicalKey, kind: .addNode(
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
                return
            }

            // Raw path (no fragment): identical to before — caller
            // is responsible for shape correctness.
            guard let entityKey = optimistic.graph.identify(node) else { return }
            if recording { optimistic.captureBaseline(layer, recordId: entityKey) }
            optimistic.graph.putRecord(entityKey, node)

            // Match cachebay-web: also record the entity write as an
            // `EntityOp` so `replay(connectionKeys:)` reasserts the
            // optimistic node fields. Without this op, a canonical
            // merger (e.g. a paginated network response that targets
            // the same connection) would normalize over the entity
            // record and the optimistic-only fields would be lost; only
            // the edge would be replayed.
            if recording {
                layer.entityOps.append(EntityOp(
                    recordId: entityKey,
                    kind: .write(patch: node, mode: .merge)
                ))
            }

            let op = ConnectionOp(connectionKey: canonicalKey, kind: .addNode(
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

        func removeNode(_ ref: EntityRef) {
            guard let entityKey = optimistic.resolveEntityRef(ref) else { return }
            let op = ConnectionOp(connectionKey: canonicalKey, kind: .removeNode(entityKey: entityKey))
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
