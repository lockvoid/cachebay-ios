import Foundation

/// Options for `client.executeQuery(query:options:)`.
///
/// - `cachePolicy`: per-call override; falls back to the client's
///   default when `nil`. See `CachePolicy`.
/// - `canonical`: read against the connection canonical (default) vs
///   the per-page strict key. Almost always `true`.
/// - `onCacheData`: fires synchronously with the cached value (if
///   any). `willFetchFromNetwork` indicates whether a network
///   request will follow (e.g. cache-and-network → `true`).
/// - `onNetworkData`: fires when the server response arrives.
/// - `onError`: fires for cache misses (cache-only), network errors,
///   or post-write materialization failures.
public struct ExecuteQueryOptions: Sendable {
    public var variables: [String: JSONValue]
    public var cachePolicy: CachePolicy?
    public var canonical: Bool = true
    public var onCacheData: (@Sendable (_ data: JSONValue, _ willFetchFromNetwork: Bool) -> Void)?
    public var onNetworkData: (@Sendable (_ data: JSONValue) -> Void)?
    public var onError: (@Sendable (_ error: CombinedError) -> Void)?

    public init(
        variables: [String: JSONValue] = [:],
        cachePolicy: CachePolicy? = nil,
        canonical: Bool = true,
        onCacheData: (@Sendable (_ data: JSONValue, _ willFetchFromNetwork: Bool) -> Void)? = nil,
        onNetworkData: (@Sendable (_ data: JSONValue) -> Void)? = nil,
        onError: (@Sendable (_ error: CombinedError) -> Void)? = nil
    ) {
        self.variables = variables
        self.cachePolicy = cachePolicy
        self.canonical = canonical
        self.onCacheData = onCacheData
        self.onNetworkData = onNetworkData
        self.onError = onError
    }
}

/// Options for `client.executeMutation(mutation:options:)`.
public struct ExecuteMutationOptions: Sendable {
    public var variables: [String: JSONValue]
    public var onData: (@Sendable (_ data: JSONValue) -> Void)?
    public var onError: (@Sendable (_ error: CombinedError) -> Void)?
    public init(
        variables: [String: JSONValue] = [:],
        onData: (@Sendable (_ data: JSONValue) -> Void)? = nil,
        onError: (@Sendable (_ error: CombinedError) -> Void)? = nil
    ) {
        self.variables = variables
        self.onData = onData
        self.onError = onError
    }
}

/// Options for `client.executeSubscription(query:options:)`.
public struct ExecuteSubscriptionOptions: Sendable {
    public var variables: [String: JSONValue]
    public init(variables: [String: JSONValue] = [:]) {
        self.variables = variables
    }
}

/// Operations subsystem: executes queries/mutations/subscriptions over the
/// transport, writes responses into the cache, and notifies watchers.
public final class Operations: @unchecked Sendable {
    private let transport: Transport
    private let planner: Planner
    private let documents: Documents
    private let queries: Queries

    private let suspensionTimeout: TimeInterval
    private let defaultPolicy: CachePolicy

    private let lock = NSLock()
    private var queryEpochs: [String: Int] = [:]
    private var lastEmitBySig: [String: TimeInterval] = [:]
    private var mutationClock: Int = 0
    private var subscriptionClock: Int = 0

    public init(
        transport: Transport,
        planner: Planner,
        documents: Documents,
        queries: Queries,
        defaultPolicy: CachePolicy = .cacheFirst,
        suspensionTimeout: TimeInterval = 1.0
    ) {
        self.transport = transport
        self.planner = planner
        self.documents = documents
        self.queries = queries
        self.defaultPolicy = defaultPolicy
        self.suspensionTimeout = suspensionTimeout
    }

    // MARK: - executeQuery

    public func executeQuery(plan: CachePlan, options: ExecuteQueryOptions) async -> OperationResult<JSONValue> {
        let policy = options.cachePolicy ?? defaultPolicy
        let vars = options.variables
        let canonicalSig = plan.makeSignature(canonical: true, variables: vars)
        let strictSig = plan.makeSignature(canonical: false, variables: vars)

        // Cache read (skipped for pure network-only).
        var cached: MaterializeResult? = nil
        if policy != .networkOnly {
            cached = documents.materialize(plan: plan, variables: vars, options: .init(canonical: true, fingerprint: true, preferCache: true, updateCache: true))
        }

        // Mirror cachebay-web: when a cached read fires `onCacheData` but
        // no watcher consumes it via `notifyDataBySignature`, the
        // materialize cache entry is now stale relative to any future
        // graph mutation that doesn't fan out to a watcher. Invalidate
        // it so the next read re-materializes from the graph.
        @Sendable func deliverCached(_ c: MaterializeResult, willFetchFromNetwork: Bool) {
            options.onCacheData?(c.data, willFetchFromNetwork)
            let propagated = queries.notifyDataBySignature(canonicalSig, data: c.data, fingerprints: c.fingerprints, dependencies: c.dependencies)
            if !propagated {
                documents.invalidate(plan: plan, variables: vars, canonical: true, fingerprint: true)
            }
        }

        // Suspension window: a recent result for this signature → serve cached terminally
        // to de-dupe a burst of equivalent requests.
        if isWithinSuspension(strictSig) {
            if let c = cached, c.source != .none {
                deliverCached(c, willFetchFromNetwork: false)
                return OperationResult(data: c.data, error: nil, meta: .init(source: .cache))
            }
        }

        switch policy {
        case .cacheOnly:
            if let c = cached, c.source != .none {
                deliverCached(c, willFetchFromNetwork: false)
                return OperationResult(data: c.data, error: nil, meta: .init(source: .cache))
            }
            let err = CombinedError.cacheMiss()
            options.onError?(err)
            _ = queries.notifyErrorBySignature(canonicalSig, error: err)
            return OperationResult(data: nil, error: err)

        case .cacheFirst:
            if let c = cached, c.canonicalOK, c.strictOK, c.strictSignature == strictSig {
                deliverCached(c, willFetchFromNetwork: false)
                return OperationResult(data: c.data, error: nil, meta: .init(source: .cache))
            }
            return await performRequest(plan: plan, options: options, canonicalSig: canonicalSig, strictSig: strictSig)

        case .cacheAndNetwork:
            if let c = cached, c.canonicalOK {
                deliverCached(c, willFetchFromNetwork: true)
            }
            return await performRequest(plan: plan, options: options, canonicalSig: canonicalSig, strictSig: strictSig)

        case .networkOnly:
            return await performRequest(plan: plan, options: options, canonicalSig: canonicalSig, strictSig: strictSig)
        }
    }

    private func performRequest(plan: CachePlan, options: ExecuteQueryOptions, canonicalSig: String, strictSig: String) async -> OperationResult<JSONValue> {
        let ctx = HTTPContext(query: plan.networkQuery, variables: options.variables, operationType: .query)

        // Epoch guard for staleness.
        let currentEpoch = bumpEpoch(for: canonicalSig)

        do {
            let result = try await transport.http.execute(ctx)
            let latest = readEpoch(for: canonicalSig)
            if latest != currentEpoch {
                let err = CombinedError.stale()
                return OperationResult(data: nil, error: err)
            }

            if let data = result.data {
                documents.normalize(plan: plan, variables: options.variables, data: data)
                let fresh = documents.materialize(plan: plan, variables: options.variables, options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: true))
                if fresh.source == .none {
                    // Match cachebay-web: a materialization failure
                    // after a successful network write is reported back
                    // to the caller via `onError` and the return value
                    // only — it is NOT a network error broadcast to all
                    // watchers. (Web fans out errors only on network/
                    // transport failures, not on cache-shape failures.)
                    let err = CombinedError(networkMessage: "[cachebay] Query materialization failed after network write")
                    options.onError?(err)
                    return OperationResult(data: nil, error: err)
                }
                markEmitted(strictSig)
                options.onNetworkData?(fresh.data)
                let propagated = queries.notifyDataBySignature(canonicalSig, data: fresh.data, fingerprints: fresh.fingerprints, dependencies: fresh.dependencies)
                if !propagated {
                    // Match cachebay-web: when no watcher consumes the
                    // network result, invalidate the materialize cache
                    // so the next read re-materializes from the freshly
                    // normalized graph state. Without this, a direct
                    // `executeQuery` call (no watcher) leaves a stale
                    // `materializeCache` entry from before the network
                    // write that wins on the next `preferCache: true`
                    // read.
                    documents.invalidate(plan: plan, variables: options.variables, canonical: true, fingerprint: true)
                }
                return OperationResult(data: fresh.data, error: result.error, meta: .init(source: .network))
            }

            markEmitted(strictSig)
            if let err = result.error {
                options.onError?(err)
                _ = queries.notifyErrorBySignature(canonicalSig, error: err)
            }
            return result
        } catch {
            let err = CombinedError(networkError: error)
            options.onError?(err)
            _ = queries.notifyErrorBySignature(canonicalSig, error: err)
            return OperationResult(data: nil, error: err)
        }
    }

    // MARK: - executeMutation

    public func executeMutation(plan: CachePlan, options: ExecuteMutationOptions) async -> OperationResult<JSONValue> {
        let clock = bumpMutationClock()
        let rootId = "@mutation.\(clock)"

        let ctx = HTTPContext(query: plan.networkQuery, variables: options.variables, operationType: .mutation)
        do {
            let result = try await transport.http.execute(ctx)
            if let data = result.data {
                documents.normalize(plan: plan, variables: options.variables, data: data, rootId: rootId)
                let fresh = documents.materialize(plan: plan, variables: options.variables, options: .init(canonical: true, rootId: rootId, fingerprint: true, preferCache: false, updateCache: false))
                if fresh.source == .none {
                    let err = CombinedError(networkMessage: "[cachebay] Mutation materialization failed")
                    options.onError?(err)
                    return OperationResult(data: nil, error: err)
                }
                if result.error == nil {
                    // Match cachebay-web ordering: watcher fanout
                    // first, then per-call `onData`. If `onData`
                    // synchronously triggers UI work that depends on
                    // watcher state (e.g. reads from a ProjectsView
                    // backed by the mutated connection), the watcher
                    // must already have been notified or the UI sees
                    // stale data for one tick.
                    let sig = plan.makeSignature(canonical: true, variables: options.variables)
                    let propagated = queries.notifyDataBySignature(sig, data: fresh.data, fingerprints: fresh.fingerprints, dependencies: fresh.dependencies)
                    if !propagated {
                        // Match cachebay-web: invalidate materialize
                        // cache when no watcher consumed the mutation
                        // result.
                        documents.invalidate(plan: plan, variables: options.variables, canonical: true, fingerprint: true)
                    }
                    options.onData?(fresh.data)
                }
                if let err = result.error { options.onError?(err) }
                return OperationResult(data: fresh.data, error: result.error)
            }
            if let err = result.error { options.onError?(err) }
            return OperationResult(data: nil, error: result.error)
        } catch {
            let err = CombinedError(networkError: error)
            options.onError?(err)
            return OperationResult(data: nil, error: err)
        }
    }

    // MARK: - executeSubscription

    public func executeSubscription(plan: CachePlan, options: ExecuteSubscriptionOptions) -> AsyncThrowingStream<OperationResult<JSONValue>, Error> {
        guard let ws = transport.ws else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: CachebayError.networkError("WS transport not configured"))
            }
        }
        let plannerRef = planner; _ = plannerRef
        let documentsRef = documents
        let queriesRef = queries
        let selfRef = self

        return AsyncThrowingStream { continuation in
            let task = Task { @Sendable in
                let ctx = WSContext(query: plan.networkQuery, variables: options.variables)
                let stream = ws.subscribe(ctx)
                do {
                    for try await event in stream {
                        if let data = event.data, !isEmptyObject(data) {
                            let c = selfRef.bumpSubscriptionClock()
                            let rootId = "@subscription.\(c)"
                            documentsRef.normalize(plan: plan, variables: options.variables, data: data, rootId: rootId)
                            let fresh = documentsRef.materialize(plan: plan, variables: options.variables, options: .init(canonical: true, rootId: rootId, fingerprint: true, preferCache: false, updateCache: false))
                            if fresh.source == .none {
                                continuation.yield(OperationResult(data: nil, error: CombinedError(networkMessage: "[cachebay] Subscription materialization failed")))
                                continue
                            }
                            let sig = plan.makeSignature(canonical: true, variables: options.variables)
                            _ = queriesRef.notifyDataBySignature(sig, data: fresh.data, fingerprints: fresh.fingerprints, dependencies: fresh.dependencies)
                            continuation.yield(OperationResult(data: fresh.data, error: event.error))
                        } else if let err = event.error {
                            continuation.yield(OperationResult(data: nil, error: err))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Suspension

    private func isWithinSuspension(_ signature: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let last = lastEmitBySig[signature] else { return false }
        return Date().timeIntervalSince1970 - last <= suspensionTimeout
    }

    private func markEmitted(_ signature: String) {
        lock.lock(); defer { lock.unlock() }
        lastEmitBySig[signature] = Date().timeIntervalSince1970
    }

    fileprivate func bumpSubscriptionClock() -> Int {
        lock.lock(); defer { lock.unlock() }
        subscriptionClock += 1
        return subscriptionClock
    }

    fileprivate func bumpMutationClock() -> Int {
        lock.lock(); defer { lock.unlock() }
        mutationClock += 1
        return mutationClock
    }

    fileprivate func bumpEpoch(for signature: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let next = (queryEpochs[signature] ?? 0) + 1
        queryEpochs[signature] = next
        return next
    }

    fileprivate func readEpoch(for signature: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return queryEpochs[signature] ?? 0
    }
}
