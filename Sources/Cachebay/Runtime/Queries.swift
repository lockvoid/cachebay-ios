import Foundation
import os

/// Options for `client.watchQuery(query:options:)`.
///
/// - `variables`: query variables; combined with the query plan to
///   produce the watcher signature (used for dep-tracked fanout).
/// - `immediate`: when `true` (default), `onData` fires synchronously
///   with the current cached value (if any) before the first network
///   delivery. `false` skips the initial emission.
/// - `onData`: called every time the materialized result changes.
/// - `onError`: optional, called for materialization or normalize
///   errors that prevented `onData` from firing.
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

/// Handle returned by `watchQuery`. Hold onto it for the lifetime of
/// the subscription; call `unsubscribe()` to release the watcher.
/// `update(variables:immediate:)` swaps the watcher's variables in
/// place — useful for paginated lists where args change but the
/// query stays the same.
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
    private let logger: Logger?
    let profiler: (any CachebayProfiler)?
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

    public init(graph: Graph, planner: Planner, documents: Documents, logger: Logger? = nil, profiler: (any CachebayProfiler)? = nil) {
        self.graph = graph
        self.planner = planner
        self.documents = documents
        self.logger = logger
        self.profiler = profiler
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
        // Match cachebay-web: when `immediate: false`, do NOT seed
        // `lastData` from the initial materialize. Seeding it means the
        // first dep-driven re-materialize compares the new data against
        // the seeded snapshot via `isDataDeepEqual`; if equal, the
        // emission is suppressed and the watcher never gets its first
        // `onData`. With `lastData` left as `nil`, the first dep change
        // reliably fires.
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
        // Profiler span covers materialize + diff + emits-list build,
        // but ends BEFORE the loop that invokes host `onData` callbacks
        // — pattern B from CachebayProfiler.swift. Host time stays out
        // of the fanout's reported duration without needing pause().
        let span = profiler?.begin("cachebay.watchers.fanout")
        lock.lock()
        var affected: Set<Int> = []
        for id in touched {
            if let set = depIndex[id] {
                affected.formUnion(set)
            }
        }
        if affected.isEmpty {
            // Useful diagnostic: a flush touched records but no watcher
            // depends on any of them. Indexed by `touched` shows whether
            // a connection canonical update is being missed because no
            // watcher registered the canonical key as a dependency.
            logger?.debug("[Cachebay] dep-fanout: touched=\(touched.count, privacy: .public) affected=0 watchersTotal=\(self.watchers.count, privacy: .public)")
            lock.unlock()
            span?.attribute("watcherCount", "0")
            span?.end()
            return
        }
        logger?.debug("[Cachebay] dep-fanout: touched=\(touched.count, privacy: .public) affected=\(affected.count, privacy: .public) watchersTotal=\(self.watchers.count, privacy: .public)")

        var emits: [(@Sendable (JSONValue) -> Void, JSONValue)] = []
        for id in affected {
            guard var w = watchers[id] else { continue }
            if w.skipNextPropagate { continue }
            let result = documents.materialize(plan: w.plan, variables: w.variables, options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: true))
            updateDependenciesLocked(id: id, next: result.dependencies)
            if result.source == .none {
                // Affected watcher couldn't materialize — the dep change
                // landed but the cache shape doesn't satisfy the watcher's
                // selection set. The per-field warning from `Documents`
                // names the culprit; this log gives the watcher identity
                // so you can correlate the two.
                logger?.warning("[Cachebay] watcher silenced: id=\(id, privacy: .public) signature=\(w.signature, privacy: .public) — dep changed but materialize returned .none (see materialize miss warnings above)")
                continue
            }
            let recycled = recycleSnapshots(w.lastData ?? .undefined, result.data, w.lastFingerprints ?? .undefined, result.fingerprints)
            if !isDataDeepEqual(recycled, w.lastData ?? .undefined) {
                w.lastData = recycled
                w.lastFingerprints = result.fingerprints
                watchers[id] = w
                emits.append((w.onData, recycled))
            }
        }
        lock.unlock()
        // End the span BEFORE invoking host onData callbacks — pattern B.
        // The fanout duration excludes host time by construction.
        span?.attribute("watcherCount", "\(affected.count)")
        span?.attribute("emittedCount", "\(emits.count)")
        span?.end()
        if profiler != nil && !emits.isEmpty {
            profiler?.record("cachebay.watchers.emitted", value: Double(emits.count))
        }
        for (cb, v) in emits { cb(v) }
    }

    // MARK: - Evict

    /// Evict all watchers' lastData and return a list of (plan, vars) for
    /// refetching. Mirrors cachebay-web `notifyEvictAll`.
    public func notifyEvictAll() -> [(plan: CachePlan, document: QueryDocument, variables: [String: JSONValue])] {
        // Match the architecture rule (see CachebayClient.swift): do
        // not invoke watcher callbacks while holding `lock`. Even with
        // `NSRecursiveLock` (safe for same-thread re-entry), a callback
        // that crosses a thread boundary and tries to acquire `lock`
        // from another thread blocks against this one. Collect the
        // resets while locked, release, then fan out.
        lock.lock()
        var refetchMap: [String: (plan: CachePlan, document: QueryDocument, variables: [String: JSONValue])] = [:]
        var resetCallbacks: [@Sendable (JSONValue) -> Void] = []
        for (id, _) in watchers {
            guard var w = watchers[id] else { continue }
            if w.lastData != nil {
                w.lastData = nil
                w.lastFingerprints = nil
                watchers[id] = w
                resetCallbacks.append(w.onData)
            }
            if refetchMap[w.signature] == nil {
                refetchMap[w.signature] = (w.plan, w.document, w.variables)
            }
        }
        lock.unlock()
        let undef: JSONValue = .undefined
        for cb in resetCallbacks { cb(undef) }
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
