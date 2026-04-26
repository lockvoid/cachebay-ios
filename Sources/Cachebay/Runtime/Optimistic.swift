import Foundation

public enum EntityPatchMode: Sendable {
    case merge
    case replace
}

public enum EdgePosition: Sendable {
    case start
    case end
    case before
    case after
}

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
    public init(position: EdgePosition = .end, anchor: EntityRef? = nil, edge: [String: JSONValue]? = nil) {
        self.position = position
        self.anchor = anchor
        self.edge = edge
    }
}

public struct OptimisticTransaction: Sendable {
    public let commit: @Sendable (_ data: JSONValue?) -> Void
    public let revert: @Sendable () -> Void
}

public enum BuilderPhase: Sendable { case optimistic; case commit }

public struct BuilderContext: Sendable {
    public let phase: BuilderPhase
    public let data: JSONValue?
}

/// The builder surface used inside `cache.modifyOptimistic { tx, ctx in ... }`.
public protocol OptimisticBuilder: AnyObject, Sendable {
    func patch(_ target: EntityRef, _ patch: [String: JSONValue], mode: EntityPatchMode)
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
    /// See `OptimisticBuilder.canonicalTypename(_:)` — exposed here so
    /// the typed `removeNode<F>(fragment:id:)` overload can canonicalise
    /// the fragment's `onTypename` to the right cache namespace.
    func canonicalTypename(_ typename: String) -> String
}

public final class Optimistic: @unchecked Sendable {
    private let graph: Graph
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

    public init(graph: Graph) {
        self.graph = graph
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
            }
        )
    }

    public func replay(connectionKeys: [CacheKey]) {
        lock.lock()
        let sorted = layers.sorted { $0.id < $1.id }
        lock.unlock()
        let scope = connectionKeys.isEmpty ? nil : Set(connectionKeys)
        for layer in sorted {
            for op in layer.entityOps { applyEntityOp(op) }
            for op in layer.connectionOps {
                if let scope, !scope.contains(op.connectionKey) { continue }
                applyConnectionOp(op)
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
            edgeRefs.remove(at: idx)
            canonical[CachebayConstants.connectionEdgesField] = .refList(edgeRefs)
            graph.replaceRecord(canonicalKey, canonical)
        }
        ConnectionIndex.remove(graph: graph, canonicalKey: canonicalKey, nodeKey: entityKey)
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
            guard let entityKey = optimistic.graph.identify(node) else { return }
            // Ensure the entity is written so readers can materialize it.
            if recording { optimistic.captureBaseline(layer, recordId: entityKey) }
            optimistic.graph.putRecord(entityKey, node)

            let op = ConnectionOp(connectionKey: canonicalKey, kind: .addNode(
                entityKey: entityKey,
                meta: options.edge,
                position: options.position,
                anchor: options.anchor.flatMap { optimistic.resolveEntityRef($0) }
            ))
            if recording {
                optimistic.captureBaseline(layer, recordId: canonicalKey)
                layer.connectionOps.append(op)
            }
            optimistic.applyConnectionOp(op)
        }

        func removeNode(_ ref: EntityRef) {
            guard let entityKey = optimistic.resolveEntityRef(ref) else { return }
            let op = ConnectionOp(connectionKey: canonicalKey, kind: .removeNode(entityKey: entityKey))
            if recording {
                optimistic.captureBaseline(layer, recordId: canonicalKey)
                layer.connectionOps.append(op)
            }
            optimistic.applyConnectionOp(op)
        }

        func patch(_ update: [String: JSONValue]) {
            if update.isEmpty { return }
            let op = ConnectionOp(connectionKey: canonicalKey, kind: .patch(update))
            if recording {
                optimistic.captureBaseline(layer, recordId: canonicalKey)
                if let pageInfoRef = optimistic.graph.getRecord(canonicalKey)?[CachebayConstants.connectionPageInfoField]?.ref {
                    optimistic.captureBaseline(layer, recordId: pageInfoRef)
                }
                layer.connectionOps.append(op)
            }
            optimistic.applyConnectionOp(op)
        }

        func canonicalTypename(_ typename: String) -> String {
            optimistic.graph.canonicalTypename(typename)
        }
    }
}

// MARK: - Optimistic → Canonical replayer bridge

extension Optimistic: OptimisticReplayer {}
