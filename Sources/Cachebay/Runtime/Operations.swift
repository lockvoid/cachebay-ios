import Foundation

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

        // Suspension window: a recent result for this signature → serve cached terminally
        // to de-dupe a burst of equivalent requests.
        if isWithinSuspension(strictSig) {
            if let c = cached, c.source != .none {
                options.onCacheData?(c.data, false)
                _ = queries.notifyDataBySignature(canonicalSig, data: c.data, fingerprints: c.fingerprints, dependencies: c.dependencies)
                return OperationResult(data: c.data, error: nil, meta: .init(source: .cache))
            }
        }

        switch policy {
        case .cacheOnly:
            if let c = cached, c.source != .none {
                options.onCacheData?(c.data, false)
                _ = queries.notifyDataBySignature(canonicalSig, data: c.data, fingerprints: c.fingerprints, dependencies: c.dependencies)
                return OperationResult(data: c.data, error: nil, meta: .init(source: .cache))
            }
            let err = CombinedError.cacheMiss()
            options.onError?(err)
            _ = queries.notifyErrorBySignature(canonicalSig, error: err)
            return OperationResult(data: nil, error: err)

        case .cacheFirst:
            if let c = cached, c.canonicalOK, c.strictOK, c.strictSignature == strictSig {
                options.onCacheData?(c.data, false)
                _ = queries.notifyDataBySignature(canonicalSig, data: c.data, fingerprints: c.fingerprints, dependencies: c.dependencies)
                return OperationResult(data: c.data, error: nil, meta: .init(source: .cache))
            }
            return await performRequest(plan: plan, options: options, canonicalSig: canonicalSig, strictSig: strictSig)

        case .cacheAndNetwork:
            if let c = cached, c.canonicalOK {
                options.onCacheData?(c.data, true)
                _ = queries.notifyDataBySignature(canonicalSig, data: c.data, fingerprints: c.fingerprints, dependencies: c.dependencies)
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
                    let err = CombinedError(networkMessage: "[cachebay] Query materialization failed after network write")
                    options.onError?(err)
                    _ = queries.notifyErrorBySignature(canonicalSig, error: err)
                    return OperationResult(data: nil, error: err)
                }
                markEmitted(strictSig)
                options.onNetworkData?(fresh.data)
                _ = queries.notifyDataBySignature(canonicalSig, data: fresh.data, fingerprints: fresh.fingerprints, dependencies: fresh.dependencies)
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
                    options.onData?(fresh.data)
                    // Also notify any watcher with this canonical signature (mutation replays).
                    let sig = plan.makeSignature(canonical: true, variables: options.variables)
                    _ = queries.notifyDataBySignature(sig, data: fresh.data, fingerprints: fresh.fingerprints, dependencies: fresh.dependencies)
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
