import Foundation

/// Typed `CachebayClient` overloads layered on top of the JSON-shaped
/// public API. Each one takes an `Operation` type, accepts its
/// `Variables` struct, and hands back / dispatches the operation's
/// `Data` shape — collapsing the dictionary-prodding boilerplate
/// (`json.object → Op.Data(__data:) → root field unwrap`) every
/// callsite was repeating into a single generic wrapper.
///
/// All five overloads are thin: they delegate to the existing JSON
/// methods, so behaviour is identical (dependency tracking, cache
/// policies, `onCacheData`/`onNetworkData` callbacks, optimistic
/// layer interaction, …). Only the call-side ergonomics change.
public extension CachebayClient {

    // MARK: - readQuery

    /// Synchronous typed read from the cache. Returns `nil` on cache miss
    /// or if the plan can't be compiled.
    func readQuery<Op: Operation>(query op: Op.Type, variables: Op.Variables) -> Op.Data? {
        guard let plan = try? planner.getPlan(Op.document) else { return nil }
        guard let raw = queries.readQuery(plan: plan, variables: variables.__cachebay),
              case .object(let obj) = raw else { return nil }
        return Op.Data(__data: obj)
    }

    // MARK: - writeQuery

    /// Synchronous typed write into the cache — for seeding test fixtures
    /// or restoring a snapshot. Mutations should go through
    /// `modifyOptimistic` (entities via `b.patch(fragment:target:_:)`,
    /// connections via `b.connection(...).linkNode(node:options:)` /
    /// `unlinkNode`) so they participate in the layered commit/revert
    /// pipeline; `writeQuery` is the non-layered base-cache primitive.
    func writeQuery<Op: Operation>(query op: Op.Type, variables: Op.Variables, data: Op.Data) throws {
        let plan = try planner.getPlan(Op.document)
        queries.writeQuery(plan: plan, variables: variables.__cachebay, data: .object(data.__data))
    }

    // MARK: - watchQuery

    /// Subscribe to a query. `onData` fires with a typed `Op.Data` each
    /// time the underlying records change; `onError` mirrors the JSON
    /// API's error contract. Returns the same `WatchQueryHandle`
    /// — call `unsubscribe()` to tear down.
    @discardableResult
    func watchQuery<Op: Operation>(
        query op: Op.Type,
        variables: Op.Variables,
        immediate: Bool = true,
        onData: @escaping @Sendable (Op.Data) -> Void,
        onError: (@Sendable (CombinedError) -> Void)? = nil
    ) throws -> WatchQueryHandle {
        // Use `Op.document` (precompiled plan with `@connection`
        // metadata intact), NOT `Op.networkQuery` (which is the
        // directive-stripped string sent to the server). Routing
        // through the string overload would re-parse the stripped
        // query and produce a plan where every connection field has
        // `isConnection = false` — `readConnection` would never run,
        // and the watcher's deps would land on the strict per-page
        // record (`@.posts({…})`) instead of the canonical
        // (`@connection.posts({…})`). `linkNode` writes the canonical,
        // so a strict-keyed watcher silently misses every optimistic
        // update. See `TypedAPIDocumentRoutingTests`.
        let plan = try planner.getPlan(Op.document)
        return queries.watchQuery(
            plan: plan,
            document: Op.document,
            options: WatchQueryOptions(
                variables: variables.__cachebay,
                immediate: immediate,
                onData: { json in
                    guard case .object(let obj) = json else { return }
                    onData(Op.Data(__data: obj))
                },
                onError: onError
            )
        )
    }

    // MARK: - executeQuery

    /// Run a query (cache + network according to `cachePolicy`). Returns
    /// `OperationResult<Op.Data>`; the `onCacheData` / `onNetworkData`
    /// callbacks fire with typed data too. Network errors propagate via
    /// `result.error` — the `try` is only for plan-compile failures.
    @discardableResult
    func executeQuery<Op: Operation>(
        query op: Op.Type,
        variables: Op.Variables,
        cachePolicy: CachePolicy? = nil,
        onCacheData: (@Sendable (_ data: Op.Data, _ willFetchFromNetwork: Bool) -> Void)? = nil,
        onNetworkData: (@Sendable (_ data: Op.Data) -> Void)? = nil,
        onError: (@Sendable (CombinedError) -> Void)? = nil
    ) async throws -> OperationResult<Op.Data> {
        // Wrap the typed callbacks into JSON-shaped ones the underlying
        // executeQuery expects. The trampoline closures decode each
        // frame's `JSONValue` into `Op.Data` before forwarding.
        var cacheCb: (@Sendable (JSONValue, Bool) -> Void)?
        if let typed = onCacheData {
            cacheCb = { (json: JSONValue, willFetch: Bool) in
                guard case .object(let obj) = json else { return }
                typed(Op.Data(__data: obj), willFetch)
            }
        }
        var netCb: (@Sendable (JSONValue) -> Void)?
        if let typed = onNetworkData {
            netCb = { (json: JSONValue) in
                guard case .object(let obj) = json else { return }
                typed(Op.Data(__data: obj))
            }
        }
        // Use `Op.document` (precompiled plan) — same reasoning as
        // `watchQuery<Op>` above. Routing through the string overload
        // would re-parse `Op.networkQuery` (directive-stripped), kill
        // `isConnection` on every connection field, and produce a plan
        // whose materialize takes the non-connection path. The result
        // then propagates through `notifyDataBySignature` and overwrites
        // the watcher's deps with strict-page-keyed entries — `linkNode`
        // against the canonical fans out to nothing.
        let plan = try planner.getPlan(Op.document)
        let opts = ExecuteQueryOptions(
            variables: variables.__cachebay,
            cachePolicy: cachePolicy,
            onCacheData: cacheCb,
            onNetworkData: netCb,
            onError: onError
        )
        let result = await operations.executeQuery(plan: plan, options: opts)
        return result.mapData { (json: JSONValue) -> Op.Data? in
            guard case .object(let obj) = json else { return nil }
            return Op.Data(__data: obj)
        }
    }

    // MARK: - executeMutation

    /// Run a mutation. The returned `OperationResult<Op.Data>` carries
    /// the typed response data and any GraphQL/network errors — same
    /// shape as the JSON API.
    @discardableResult
    func executeMutation<Op: Operation>(
        mutation op: Op.Type,
        variables: Op.Variables,
        onData: (@Sendable (Op.Data) -> Void)? = nil,
        onError: (@Sendable (CombinedError) -> Void)? = nil
    ) async throws -> OperationResult<Op.Data> {
        var dataCb: (@Sendable (JSONValue) -> Void)?
        if let typed = onData {
            dataCb = { (json: JSONValue) in
                guard case .object(let obj) = json else { return }
                typed(Op.Data(__data: obj))
            }
        }
        // Use `Op.document` (precompiled plan with `@connection`
        // metadata) — same reasoning as `watchQuery<Op>` /
        // `executeQuery<Op>`. Routing through the string overload would
        // re-parse `Op.networkQuery` (directive-stripped) and produce
        // a plan where `isConnection = false`. Mutations whose
        // response includes a connection-decorated field would then
        // normalize without ever invoking `Canonical.updateConnection`,
        // so the canonical record is never written and watchers
        // depending on it silently miss every mutation-driven update.
        let plan = try planner.getPlan(Op.document)
        let opts = ExecuteMutationOptions(
            variables: variables.__cachebay,
            onData: dataCb,
            onError: onError
        )
        let result = await operations.executeMutation(plan: plan, options: opts)
        return result.mapData { (json: JSONValue) -> Op.Data? in
            guard case .object(let obj) = json else { return nil }
            return Op.Data(__data: obj)
        }
    }

    // MARK: - readFragment / writeFragment / watchFragment

    /// Synchronous typed read of a fragment off an entity by bare id.
    /// The cache key is built internally as `"\(F.onTypename):\(id)"`
    /// — callers pass just the id (`"p1"` or `42`), the fragment knows
    /// its target type. Returns `nil` on cache miss or plan-compile
    /// failure.
    func readFragment<F: Fragment, ID: LosslessStringConvertible>(
        fragment frag: F.Type,
        id: ID,
        variables: F.Variables
    ) -> F.Data? {
        let cacheKey = "\(graph.canonicalTypename(F.onTypename)):\(id)"
        guard let plan = try? planner.getPlan(F.document, fragmentName: F.fragmentName) else { return nil }
        guard let raw = fragments.readFragment(plan: plan, rootId: cacheKey, variables: variables.__cachebay),
              case .object(let obj) = raw else { return nil }
        return F.Data(__data: obj)
    }

    /// Typed fragment write keyed by bare entity id. Round-trips
    /// `data.__data` through the JSON-shaped runtime so the writer
    /// normalises like a network response.
    func writeFragment<F: Fragment, ID: LosslessStringConvertible>(
        fragment frag: F.Type,
        id: ID,
        variables: F.Variables,
        data: F.Data
    ) throws {
        let cacheKey = "\(graph.canonicalTypename(F.onTypename)):\(id)"
        let plan = try planner.getPlan(F.document, fragmentName: F.fragmentName)
        fragments.writeFragment(plan: plan, rootId: cacheKey, variables: variables.__cachebay, data: .object(data.__data))
        graph.flush()
    }

    /// Subscribe to a typed fragment view of an entity, keyed by bare
    /// id. Fires `onData` with a typed `F.Data` whenever the underlying
    /// entity's relevant fields change. Returns the JSON-shaped
    /// `WatchFragmentHandle` — `unsubscribe()` / `update(...)` work the
    /// same as the JSON API.
    @discardableResult
    func watchFragment<F: Fragment, ID: LosslessStringConvertible>(
        fragment frag: F.Type,
        id: ID,
        variables: F.Variables,
        immediate: Bool = true,
        onData: @escaping @Sendable (F.Data) -> Void,
        onError: (@Sendable (CombinedError) -> Void)? = nil
    ) throws -> WatchFragmentHandle {
        let cacheKey = "\(graph.canonicalTypename(F.onTypename)):\(id)"
        let plan = try planner.getPlan(F.document, fragmentName: F.fragmentName)
        return fragments.watchFragment(
            plan: plan,
            document: F.document,
            fragmentName: F.fragmentName,
            rootId: cacheKey,
            options: WatchFragmentOptions(
                variables: variables.__cachebay,
                immediate: immediate,
                onData: { json in
                    guard case .object(let obj) = json else { return }
                    onData(F.Data(__data: obj))
                },
                onError: onError
            )
        )
    }

    // MARK: - executeSubscription

    /// Stream-style typed subscription. Each yielded event carries an
    /// optional `Op.Data` (`nil` when the frame is purely an error).
    func executeSubscription<Op: Operation>(
        subscription op: Op.Type,
        variables: Op.Variables
    ) throws -> AsyncThrowingStream<OperationResult<Op.Data>, Error> {
        // Use `Op.document` (precompiled plan with `@connection`
        // metadata) — same reasoning as `executeMutation<Op>` /
        // `watchQuery<Op>` / `executeQuery<Op>`. Routing through the
        // string overload would re-parse `Op.networkQuery` (directive-
        // stripped) and produce a plan where every connection field
        // has `isConnection = false`. Subscription frames yielding a
        // connection payload would normalize without invoking
        // `Canonical.updateConnection`, so the canonical record never
        // lands.
        let plan = try planner.getPlan(Op.document)
        let stream = operations.executeSubscription(
            plan: plan,
            options: ExecuteSubscriptionOptions(variables: variables.__cachebay)
        )
        return AsyncThrowingStream<OperationResult<Op.Data>, Error> { continuation in
            let task = Task<Void, Never> {
                do {
                    for try await event in stream {
                        let typed = event.mapData { (json: JSONValue) -> Op.Data? in
                            guard case .object(let obj) = json else { return nil }
                            return Op.Data(__data: obj)
                        }
                        continuation.yield(typed)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - OperationResult helpers

public extension OperationResult {
    /// Project the result's data into a different shape, preserving the
    /// `error` / `meta` slots. Returns `nil` data when the input data
    /// can't be projected (e.g. the typed mapper returned nil for a
    /// non-object frame). `Meta` is rebuilt rather than copied because
    /// it's a generic-nested type — `OperationResult<TData>.Meta` and
    /// `OperationResult<U>.Meta` are distinct Swift types even though
    /// their stored layout is identical.
    func mapData<U: Sendable>(_ transform: (TData) -> U?) -> OperationResult<U> {
        let translatedMeta: OperationResult<U>.Meta? = meta.map { src in
            let translatedSource: OperationResult<U>.Meta.Source? = src.source.map { s in
                switch s {
                case .cache: return .cache
                case .network: return .network
                }
            }
            return OperationResult<U>.Meta(source: translatedSource)
        }
        return OperationResult<U>(
            data: data.flatMap(transform),
            error: error,
            meta: translatedMeta
        )
    }
}

