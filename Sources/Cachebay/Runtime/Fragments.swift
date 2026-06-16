import Foundation

public struct WatchFragmentOptions: Sendable {
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

public struct WatchFragmentHandle: Sendable {
    public let unsubscribe: @Sendable () -> Void
    public let update: @Sendable (_ id: CacheKey?, _ variables: [String: JSONValue]?, _ immediate: Bool) -> Void
}

public final class Fragments: @unchecked Sendable {
    private let planner: Planner
    private let documents: Documents
    let profiler: (any CachebayProfiler)?
    private let lock = NSRecursiveLock()

    private struct WatcherState {
        let id: Int
        var rootId: CacheKey
        var plan: CachePlan
        var document: QueryDocument
        var fragmentName: String?
        var variables: [String: JSONValue]
        var signature: String
        let onData: @Sendable (_ data: JSONValue) -> Void
        let onError: (@Sendable (_ error: CombinedError) -> Void)?
        var deps: Set<CacheKey>
        var lastData: JSONValue?
        var lastFingerprints: JSONValue?
    }

    private var watchers: [Int: WatcherState] = [:]
    private var depIndex: [CacheKey: Set<Int>] = [:]
    private var signatureToWatchers: [String: Set<Int>] = [:]
    private var watcherSeq: Int = 0

    public init(planner: Planner, documents: Documents, profiler: (any CachebayProfiler)? = nil) {
        self.planner = planner
        self.documents = documents
        self.profiler = profiler
    }

    public func readFragment(plan: CachePlan, rootId: CacheKey, variables: [String: JSONValue]) -> JSONValue? {
        let span = profiler?.begin("cachebay.readFragment")
        defer { span?.end() }
        let result = documents.materialize(plan: plan, variables: variables, options: .init(canonical: true, rootId: rootId, fingerprint: true, preferCache: true, updateCache: false))
        if result.source == .none { return nil }
        return result.data
    }

    public func writeFragment(plan: CachePlan, rootId: CacheKey, variables: [String: JSONValue], data: JSONValue) {
        let span = profiler?.begin("cachebay.writeFragment")
        defer { span?.end() }
        documents.normalize(plan: plan, variables: variables, data: data, rootId: rootId)
    }

    public func watchFragment(plan: CachePlan, document: QueryDocument, fragmentName: String?, rootId: CacheKey, options: WatchFragmentOptions) -> WatchFragmentHandle {
        lock.lock()
        watcherSeq += 1
        let id = watcherSeq
        let sig = "\(rootId)|\(plan.makeSignature(canonical: true, variables: options.variables))"
        var state = WatcherState(
            id: id, rootId: rootId, plan: plan, document: document, fragmentName: fragmentName,
            variables: options.variables, signature: sig, onData: options.onData, onError: options.onError,
            deps: [], lastData: nil, lastFingerprints: nil
        )
        watchers[id] = state
        signatureToWatchers[sig, default: []].insert(id)

        let result = documents.materialize(plan: plan, variables: options.variables, options: .init(canonical: true, rootId: rootId, fingerprint: true, preferCache: true, updateCache: true))
        updateDependenciesLocked(id: id, next: result.dependencies)
        if result.source != .none {
            state.lastData = result.data
            state.lastFingerprints = result.fingerprints
            watchers[id] = state
            if options.immediate {
                let data = result.data
                let onData = state.onData
                lock.unlock()
                onData(data)
                return makeHandle(id: id)
            }
        }
        lock.unlock()
        return makeHandle(id: id)
    }

    private func makeHandle(id: Int) -> WatchFragmentHandle {
        let frags = self
        return WatchFragmentHandle(
            unsubscribe: { [weak frags] in frags?.unsubscribe(id: id) },
            update: { [weak frags] newId, newVars, immediate in
                frags?.updateWatcher(id: id, newId: newId, newVariables: newVars, immediate: immediate)
            }
        )
    }

    private func unsubscribe(id: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let w = watchers.removeValue(forKey: id) else { return }
        for d in w.deps {
            if var set = depIndex[d] {
                set.remove(id)
                if set.isEmpty { depIndex.removeValue(forKey: d) } else { depIndex[d] = set }
            }
        }
        if var set = signatureToWatchers[w.signature] {
            set.remove(id)
            if set.isEmpty {
                signatureToWatchers.removeValue(forKey: w.signature)
                documents.invalidate(plan: w.plan, variables: w.variables, canonical: true, rootId: w.rootId, fingerprint: true)
            } else {
                signatureToWatchers[w.signature] = set
            }
        }
    }

    private func updateWatcher(id: Int, newId: CacheKey?, newVariables: [String: JSONValue]?, immediate: Bool) {
        lock.lock()
        guard var w = watchers[id] else { lock.unlock(); return }
        let oldSig = w.signature
        let oldId = w.rootId
        let oldVars = w.variables
        if let newId { w.rootId = newId }
        if let newVariables { w.variables = newVariables }
        let newSig = "\(w.rootId)|\(w.plan.makeSignature(canonical: true, variables: w.variables))"
        if newSig != oldSig {
            if var oldSet = signatureToWatchers[oldSig] {
                oldSet.remove(id)
                if oldSet.isEmpty {
                    signatureToWatchers.removeValue(forKey: oldSig)
                    documents.invalidate(plan: w.plan, variables: oldVars, canonical: true, rootId: oldId, fingerprint: true)
                } else {
                    signatureToWatchers[oldSig] = oldSet
                }
            }
            w.signature = newSig
            signatureToWatchers[newSig, default: []].insert(id)
        }

        if immediate {
            let result = documents.materialize(plan: w.plan, variables: w.variables, options: .init(canonical: true, rootId: w.rootId, fingerprint: true, preferCache: true, updateCache: true))
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

    public func notifyDataByDependencies(_ touched: Set<CacheKey>) {
        // Same shape as Queries.notifyDataByDependencies: span ends
        // before invoking host onData callbacks (pattern B).
        let span = profiler?.begin("cachebay.watchers.fanout")
        lock.lock()
        var affected: Set<Int> = []
        for id in touched {
            if let set = depIndex[id] { affected.formUnion(set) }
        }
        if affected.isEmpty {
            lock.unlock()
            span?.attribute("watcherCount", "0")
            span?.attribute("kind", "fragment")
            span?.end()
            return
        }

        var emits: [(@Sendable (JSONValue) -> Void, JSONValue)] = []
        for id in affected {
            guard var w = watchers[id] else { continue }
            let result = documents.materialize(plan: w.plan, variables: w.variables, options: .init(canonical: true, rootId: w.rootId, fingerprint: true, preferCache: false, updateCache: true))
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
        span?.attribute("watcherCount", "\(affected.count)")
        span?.attribute("emittedCount", "\(emits.count)")
        span?.attribute("kind", "fragment")
        span?.end()
        for (cb, v) in emits { cb(v) }
    }

    public func notifyEvictAll() {
        lock.lock()
        var emits: [@Sendable () -> Void] = []
        for (id, _) in watchers {
            guard var w = watchers[id] else { continue }
            if w.lastData != nil {
                w.lastData = nil
                w.lastFingerprints = nil
                watchers[id] = w
                let cb = w.onData
                emits.append({ cb(.undefined) })
            }
        }
        lock.unlock()
        for e in emits { e() }
    }

    private func updateDependenciesLocked(id: Int, next: Set<CacheKey>) {
        guard var w = watchers[id] else { return }
        let old = w.deps
        if old == next { return }
        for d in old where !next.contains(d) {
            if var set = depIndex[d] {
                set.remove(id)
                if set.isEmpty { depIndex.removeValue(forKey: d) } else { depIndex[d] = set }
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
