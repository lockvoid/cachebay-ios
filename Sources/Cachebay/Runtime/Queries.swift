import Foundation

public struct WatchQueryOptions: Sendable {
    public var variables: [String: JSONValue]
    public var immediate: Bool
    public var onData: @Sendable (_ data: JSONValue) -> Void
    public var onError: (@Sendable (_ error: CombinedError) -> Void)?

    public init(
        variables: [String: JSONValue] = [:],
        immediate: Bool = true,
        onData: @escaping @Sendable (_ data: JSONValue) -> Void,
        onError: (@Sendable (_ error: CombinedError) -> Void)? = nil
    ) {
        self.variables = variables
        self.immediate = immediate
        self.onData = onData
        self.onError = onError
    }
}

public struct WatchQueryHandle: Sendable {
    public let unsubscribe: @Sendable () -> Void
    public let update: @Sendable (_ variables: [String: JSONValue], _ immediate: Bool) -> Void
}

/// The `Queries` subsystem owns root-level watchers (queries + mutations +
/// subscriptions emit to these watchers by signature). It also materializes
/// ad-hoc `readQuery` and performs `writeQuery`.
public final class Queries: @unchecked Sendable {
    private let graph: Graph
    private let planner: Planner
    private let documents: Documents
    private let lock = NSRecursiveLock()

    private struct WatcherState {
        let id: Int
        var plan: CachePlan
        var document: QueryDocument
        var variables: [String: JSONValue]
        var signature: String
        let onData: @Sendable (_ data: JSONValue) -> Void
        let onError: (@Sendable (_ error: CombinedError) -> Void)?
        var deps: Set<CacheKey>
        var lastData: JSONValue?
        var lastFingerprints: JSONValue?
        var skipNextPropagate: Bool = false
    }

    private var watchers: [Int: WatcherState] = [:]
    private var depIndex: [CacheKey: Set<Int>] = [:]
    private var signatureToWatchers: [String: Set<Int>] = [:]
    private var watcherSeq: Int = 0

    public init(graph: Graph, planner: Planner, documents: Documents) {
        self.graph = graph
        self.planner = planner
        self.documents = documents
    }

    // MARK: - readQuery / writeQuery

    public func readQuery(plan: CachePlan, variables: [String: JSONValue]) -> JSONValue? {
        let result = documents.materialize(plan: plan, variables: variables, options: .init(canonical: true, fingerprint: true, preferCache: true, updateCache: false))
        if result.source == .none { return nil }
        return result.data
    }

    public func writeQuery(plan: CachePlan, variables: [String: JSONValue], data: JSONValue) {
        documents.normalize(plan: plan, variables: variables, data: data)
        graph.flush()
    }

    // MARK: - watchQuery

    public func watchQuery(plan: CachePlan, document: QueryDocument, options: WatchQueryOptions) -> WatchQueryHandle {
        lock.lock()
        watcherSeq += 1
        let id = watcherSeq
        let signature = plan.makeSignature(canonical: true, variables: options.variables)
        var state = WatcherState(
            id: id, plan: plan, document: document, variables: options.variables,
            signature: signature,
            onData: options.onData, onError: options.onError,
            deps: [], lastData: nil, lastFingerprints: nil
        )
        watchers[id] = state
        signatureToWatchers[signature, default: []].insert(id)

        // Initial materialize (cache-first). Track deps even on miss.
        let result = documents.materialize(plan: plan, variables: options.variables, options: .init(canonical: true, fingerprint: true, preferCache: true, updateCache: true))
        var mergedDeps = result.dependencies
        // Pre-register coarse plan-derived deps alongside the materializer-derived ones,
        // so a subsequent write to a field the plan recognises notifies this watcher even
        // if the initial read was a miss and didn't touch that record.
        mergedDeps.formUnion(plan.getDependencies(canonical: true, variables: options.variables))
        updateDependenciesLocked(id: id, next: mergedDeps)
        if options.immediate, result.source != .none {
            state.lastData = result.data
            state.lastFingerprints = result.fingerprints
            watchers[id] = state
            let data = result.data
            lock.unlock()
            options.onData(data)
            return makeHandle(id: id)
        }
        if result.source == .none {
            // deps already merged above
        } else {
            state.lastData = result.data
            state.lastFingerprints = result.fingerprints
            watchers[id] = state
        }
        lock.unlock()
        return makeHandle(id: id)
    }

    private func makeHandle(id: Int) -> WatchQueryHandle {
        let queries = self
        return WatchQueryHandle(
            unsubscribe: { [weak queries] in
                queries?.unsubscribe(id: id)
            },
            update: { [weak queries] vars, immediate in
                queries?.updateWatcher(id: id, variables: vars, immediate: immediate)
            }
        )
    }

    private func unsubscribe(id: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let w = watchers.removeValue(forKey: id) else { return }
        for d in w.deps {
            if var set = depIndex[d] {
                set.remove(id)
                if set.isEmpty { depIndex.removeValue(forKey: d) }
                else { depIndex[d] = set }
            }
        }
        if var set = signatureToWatchers[w.signature] {
            set.remove(id)
            if set.isEmpty {
                signatureToWatchers.removeValue(forKey: w.signature)
                documents.invalidate(plan: w.plan, variables: w.variables, canonical: true, fingerprint: true)
            } else {
                signatureToWatchers[w.signature] = set
            }
        }
    }

    private func updateWatcher(id: Int, variables: [String: JSONValue], immediate: Bool) {
        lock.lock()
        guard var w = watchers[id] else { lock.unlock(); return }
        let oldVars = w.variables
        let oldSig = w.signature
        w.variables = variables
        let newSig = w.plan.makeSignature(canonical: true, variables: variables)

        if newSig != oldSig {
            if var oldSet = signatureToWatchers[oldSig] {
                oldSet.remove(id)
                if oldSet.isEmpty {
                    signatureToWatchers.removeValue(forKey: oldSig)
                    documents.invalidate(plan: w.plan, variables: oldVars, canonical: true, fingerprint: true)
                } else {
                    signatureToWatchers[oldSig] = oldSet
                }
            }
            w.signature = newSig
            signatureToWatchers[newSig, default: []].insert(id)
        }

        if immediate {
            let result = documents.materialize(plan: w.plan, variables: variables, options: .init(canonical: true, fingerprint: true, preferCache: true, updateCache: true))
            updateDependenciesLocked(id: id, next: result.dependencies)
            if result.source != .none {
                let recycled = recycleSnapshots(w.lastData ?? .undefined, result.data, w.lastFingerprints ?? .undefined, result.fingerprints)
                if !isDataDeepEqual(recycled, w.lastData ?? .undefined) {
                    w.lastData = recycled
                    w.lastFingerprints = result.fingerprints
                    watchers[id] = w
                    let data = recycled
                    let onData = w.onData
                    lock.unlock()
                    onData(data)
                    return
                }
            }
        }
        watchers[id] = w
        lock.unlock()
    }

    // MARK: - Called by operations after network response

    /// Deliver an already-materialized result directly to watchers with the
    /// given canonical signature, bypassing the dep-based flush.
    @discardableResult
    public func notifyDataBySignature(_ signature: String, data: JSONValue, fingerprints: JSONValue, dependencies: Set<CacheKey>) -> Bool {
        lock.lock()
        guard let ids = signatureToWatchers[signature], !ids.isEmpty else { lock.unlock(); return false }

        var callbacks: [(@Sendable (JSONValue) -> Void, JSONValue)] = []
        callbacks.reserveCapacity(ids.count)
        for id in ids {
            guard var w = watchers[id] else { continue }
            updateDependenciesLocked(id: id, next: dependencies)
            let recycled = recycleSnapshots(w.lastData ?? .undefined, data, w.lastFingerprints ?? .undefined, fingerprints)
            if !isDataDeepEqual(recycled, w.lastData ?? .undefined) {
                w.lastData = recycled
                w.lastFingerprints = fingerprints
                w.skipNextPropagate = true
                watchers[id] = w
                callbacks.append((w.onData, recycled))
                // Reset skipNextPropagate on the next tick via Task.
                let weakSelf = self
                let wid = id
                Task { @Sendable in
                    weakSelf.clearSkip(id: wid)
                }
            }
        }
        lock.unlock()
        for (cb, val) in callbacks { cb(val) }
        return true
    }

    private func clearSkip(id: Int) {
        lock.lock(); defer { lock.unlock() }
        if var w = watchers[id] {
            w.skipNextPropagate = false
            watchers[id] = w
        }
    }

    /// Notify all watchers with the given signature of an error (e.g. network failure).
    @discardableResult
    public func notifyErrorBySignature(_ signature: String, error: CombinedError) -> Bool {
        lock.lock()
        guard let ids = signatureToWatchers[signature] else { lock.unlock(); return false }
        var errs: [(@Sendable (CombinedError) -> Void, CombinedError)] = []
        for id in ids {
            if let onError = watchers[id]?.onError {
                errs.append((onError, error))
            }
        }
        lock.unlock()
        for (cb, e) in errs { cb(e) }
        return true
    }

    /// Called by Graph.onChange (via CachebayClient) with the set of touched
    /// record IDs. Watchers whose deps intersect re-materialize.
    public func notifyDataByDependencies(_ touched: Set<CacheKey>) {
        lock.lock()
        var affected: Set<Int> = []
        for id in touched {
            if let set = depIndex[id] {
                affected.formUnion(set)
            }
        }
        if affected.isEmpty { lock.unlock(); return }

        var emits: [(@Sendable (JSONValue) -> Void, JSONValue)] = []
        for id in affected {
            guard var w = watchers[id] else { continue }
            if w.skipNextPropagate { continue }
            let result = documents.materialize(plan: w.plan, variables: w.variables, options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: true))
            updateDependenciesLocked(id: id, next: result.dependencies)
            if result.source == .none { continue }
            let recycled = recycleSnapshots(w.lastData ?? .undefined, result.data, w.lastFingerprints ?? .undefined, result.fingerprints)
            if !isDataDeepEqual(recycled, w.lastData ?? .undefined) {
                w.lastData = recycled
                w.lastFingerprints = result.fingerprints
                watchers[id] = w
                emits.append((w.onData, recycled))
            }
        }
        lock.unlock()
        for (cb, v) in emits { cb(v) }
    }

    // MARK: - Evict

    /// Evict all watchers' lastData and return a list of (plan, vars) for
    /// refetching. Mirrors cachebay-web `notifyEvictAll`.
    public func notifyEvictAll() -> [(plan: CachePlan, document: QueryDocument, variables: [String: JSONValue])] {
        lock.lock(); defer { lock.unlock() }
        var refetchMap: [String: (plan: CachePlan, document: QueryDocument, variables: [String: JSONValue])] = [:]
        for (id, _) in watchers {
            guard var w = watchers[id] else { continue }
            if w.lastData != nil {
                w.lastData = nil
                w.lastFingerprints = nil
                watchers[id] = w
                let cb = w.onData
                let undef: JSONValue = .undefined
                // Intentional; we want watchers to observe a reset.
                // Do not deadlock — callback can read but not mutate state while we hold the lock.
                cb(undef)
            }
            if refetchMap[w.signature] == nil {
                refetchMap[w.signature] = (w.plan, w.document, w.variables)
            }
        }
        return Array(refetchMap.values)
    }

    // MARK: - Dep index

    private func updateDependenciesLocked(id: Int, next: Set<CacheKey>) {
        guard var w = watchers[id] else { return }
        let old = w.deps
        if old == next { return }
        for d in old where !next.contains(d) {
            if var set = depIndex[d] {
                set.remove(id)
                if set.isEmpty { depIndex.removeValue(forKey: d) }
                else { depIndex[d] = set }
            }
        }
        for d in next where !old.contains(d) {
            depIndex[d, default: []].insert(id)
        }
        w.deps = next
        watchers[id] = w
    }

    public func inspect() -> (total: Int, signatures: Int) {
        lock.lock(); defer { lock.unlock() }
        return (watchers.count, signatureToWatchers.count)
    }
}
