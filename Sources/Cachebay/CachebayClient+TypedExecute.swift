import Foundation

// Typed parity for the v1.0 `CachebayOperation` API: writeQuery, the synchronous
// (token-returning) execute overloads, and subscriptions. Mirrors the JSON-shaped
// runtime exactly; the only difference from the removed dict-wrapper overloads is
// the decode boundary — `Op.Data(cachebayJSON:)` in, `data.cachebayJSON` out.

public extension CachebayClient {

    // MARK: - writeQuery

    /// Synchronous typed write into the cache — for seeding fixtures or restoring a
    /// snapshot. Mutations should go through `modifyOptimistic`.
    func write<Op: CachebayOperation>(query op: Op.Type, variables: Op.Variables, data: Op.Data) throws {
        let plan = try planner.getPlan(Op.document)
        queries.writeQuery(plan: plan, variables: variables.__cachebay, data: data.cachebayJSON)
    }

    // MARK: - execute (sync, token)

    /// Sync query. Returns immediately; the network call runs on a detached task.
    /// Hold the token to `cancel()`; callbacks check `isCancelled` before firing.
    @discardableResult
    func execute<Op: CachebayOperation>(
        _ op: Op.Type,
        variables: Op.Variables,
        cachePolicy: CachePolicy? = nil,
        onCacheData: (@Sendable (_ data: Op.Data, _ willFetchFromNetwork: Bool) -> Void)? = nil,
        onNetworkData: (@Sendable (_ data: Op.Data) -> Void)? = nil,
        onError: (@Sendable (CombinedError) -> Void)? = nil
    ) -> CachebayToken {
        let token = CachebayToken()
        var wrappedOnCache: (@Sendable (Op.Data, Bool) -> Void)? = nil
        if let cb = onCacheData {
            wrappedOnCache = { [token] d, w in
                if token.isCancelled { return }; cb(d, w)
            }
        }
        var wrappedOnNetwork: (@Sendable (Op.Data) -> Void)? = nil
        if let cb = onNetworkData {
            wrappedOnNetwork = { [token] d in
                if token.isCancelled { return }; cb(d)
            }
        }
        var wrappedOnError: (@Sendable (CombinedError) -> Void)? = nil
        if let cb = onError {
            wrappedOnError = { [token] e in
                if token.isCancelled { return }; cb(e)
            }
        }

        let plan: CachePlan
        do { plan = try planner.getPlan(Op.document) } catch { wrappedOnError?(CombinedError(networkError: error)); return token }

        var cacheCb: (@Sendable (JSONValue, Bool) -> Void)? = nil
        if let typed = wrappedOnCache { cacheCb = { json, w in if let d = Op.Data(cachebayJSON: json) { typed(d, w) } } }
        var netCb: (@Sendable (JSONValue) -> Void)? = nil
        if let typed = wrappedOnNetwork { netCb = { json in if let d = Op.Data(cachebayJSON: json) { typed(d) } } }

        let opts = ExecuteQueryOptions(
            variables: variables.__cachebay,
            cachePolicy: cachePolicy,
            onCacheData: cacheCb,
            onNetworkData: netCb,
            onError: wrappedOnError
        )
        let outcome = operations.tryDeliverFromCacheSync(plan: plan, options: opts)
        if case .terminal = outcome { return token }

        var netOpts = opts
        netOpts.cachePolicy = .networkOnly
        netOpts.onCacheData = nil
        let task = Task.detached { [weak self] in
            guard let self else { return }
            _ = await self.operations.performNetworkOnly(plan: plan, options: netOpts)
        }
        token.attachTask(task)
        return token
    }

    /// Sync mutation. Returns immediately; the network call runs on a detached task.
    @discardableResult
    func execute<Op: CachebayOperation>(
        mutation op: Op.Type,
        variables: Op.Variables,
        onData: (@Sendable (_ data: Op.Data) -> Void)? = nil,
        onError: (@Sendable (CombinedError) -> Void)? = nil
    ) -> CachebayToken {
        let token = CachebayToken()
        var wrappedOnData: (@Sendable (Op.Data) -> Void)? = nil
        if let cb = onData {
            wrappedOnData = { [token] d in
                if token.isCancelled { return }; cb(d)
            }
        }
        var wrappedOnError: (@Sendable (CombinedError) -> Void)? = nil
        if let cb = onError {
            wrappedOnError = { [token] e in
                if token.isCancelled { return }; cb(e)
            }
        }

        let plan: CachePlan
        do { plan = try planner.getPlan(Op.document) } catch { wrappedOnError?(CombinedError(networkError: error)); return token }

        var dataCb: (@Sendable (JSONValue) -> Void)? = nil
        if let typed = wrappedOnData { dataCb = { json in if let d = Op.Data(cachebayJSON: json) { typed(d) } } }
        let opts = ExecuteMutationOptions(variables: variables.__cachebay, onData: dataCb, onError: wrappedOnError)
        let task = Task.detached { [weak self] in
            guard let self else { return }
            _ = await self.operations.executeMutation(plan: plan, options: opts)
        }
        token.attachTask(task)
        return token
    }

    // MARK: - executeSubscription

    /// Stream-style typed subscription. Each event carries an optional `Op.Data`.
    ///
    /// `onFrame` receives the DECODED raw frame before normalization; return
    /// `.skip` to treat it as a pure signal (no store write, no watcher
    /// fanout, no stream data event). A frame that fails the typed decode
    /// bypasses the hook and falls back to `.normalize` (fail-open — the
    /// plain pipeline may still normalize what the typed decode couldn't
    /// represent).
    func executeSubscription<Op: CachebayOperation>(
        _ op: Op.Type,
        variables: Op.Variables,
        onFrame: (@Sendable (_ frame: Op.Data) -> FrameDisposition)? = nil
    ) throws -> AsyncThrowingStream<OperationResult<Op.Data>, Error> {
        let plan = try planner.getPlan(Op.document)
        var jsonOnFrame: (@Sendable (JSONValue) -> FrameDisposition)? = nil
        if let onFrame {
            jsonOnFrame = { json in Op.Data(cachebayJSON: json).map(onFrame) ?? .normalize }
        }
        let stream = operations.executeSubscription(
            plan: plan,
            options: ExecuteSubscriptionOptions(variables: variables.__cachebay, onFrame: jsonOnFrame)
        )
        return AsyncThrowingStream<OperationResult<Op.Data>, Error> { continuation in
            let task = Task<Void, Never> {
                do {
                    for try await event in stream {
                        continuation.yield(event.mapData { Op.Data(cachebayJSON: $0) })
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sync subscription. Returns a token; `onData` fires per server frame.
    /// `onFrame` — see the stream-style overload above.
    @discardableResult
    func executeSubscription<Op: CachebayOperation>(
        _ op: Op.Type,
        variables: Op.Variables,
        onFrame: (@Sendable (_ frame: Op.Data) -> FrameDisposition)? = nil,
        onData: (@Sendable (_ data: Op.Data) -> Void)? = nil,
        onError: (@Sendable (CombinedError) -> Void)? = nil
    ) -> CachebayToken {
        let token = CachebayToken()
        var wrappedOnData: (@Sendable (Op.Data) -> Void)? = nil
        if let cb = onData {
            wrappedOnData = { [token] d in
                if token.isCancelled { return }; cb(d)
            }
        }
        var wrappedOnError: (@Sendable (CombinedError) -> Void)? = nil
        if let cb = onError {
            wrappedOnError = { [token] e in
                if token.isCancelled { return }; cb(e)
            }
        }

        // A frame racing token.cancel() must not run the caller's hook (its
        // side effects — e.g. an enqueued refetch — would fire post-cancel)
        // nor write the store: hook users opted out of normalization for
        // frames they judge unsafe, and post-cancel nobody can judge. Gate
        // to `.skip`. Subscriptions without a hook keep today's behavior
        // (racing frames normalize until the stream terminates).
        var gatedOnFrame = onFrame
        if let hook = onFrame {
            gatedOnFrame = { [token] frame in token.isCancelled ? .skip : hook(frame) }
        }
        let task = Task.detached { [weak self] in
            guard let self else { return }
            do {
                let stream = try self.executeSubscription(op, variables: variables, onFrame: gatedOnFrame)
                for try await event in stream {
                    if token.isCancelled { return }
                    if let data = event.data { wrappedOnData?(data) }
                    if let error = event.error { wrappedOnError?(error) }
                }
            } catch is CancellationError {
            } catch {
                wrappedOnError?(CombinedError(networkError: error))
            }
        }
        token.attachTask(task)
        return token
    }
}
