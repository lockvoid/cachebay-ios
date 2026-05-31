import Foundation

/// A v1.0 typed-struct GraphQL operation.
///
/// Unlike the legacy `Operation` (whose `Data: OperationData` wraps a
/// `[String: JSONValue]` dict and reads fields lazily), `Data` here is a real
/// struct/enum that decodes **eagerly** from a materialized record via
/// `CachebayValue` — produced by the `@CachebayData` / `@CachebayInterface`
/// macros (CLI-emitted in production). Reads are direct field loads (~1 ns)
/// and value-diffing is the synthesized `Equatable`.
///
/// The decode boundary is the only difference from the JSON-shaped runtime:
/// `materialize` is unchanged; the typed entry points below decode its result
/// once via `Op.Data(cachebayJSON:)`. A required field that fails to decode is a
/// whole-record miss (proposal §7), surfaced as `nil`/skip — identical consumer
/// semantics to today's `strictOK = false` cache miss.
public protocol CachebayOperation: Sendable {
    associatedtype Variables: OperationVariables
    associatedtype Data: CachebayValue & Sendable
    /// Pre-compiled `CachePlan` (or fall-back source), same as `Operation`.
    static var document: QueryDocument { get }
}

public extension CachebayClient {
    /// Synchronous typed read from the cache. Returns `nil` on cache miss, an
    /// un-compilable plan, or if any required field fails to decode (§7).
    func read<Op: CachebayOperation>(_ op: Op.Type, variables: Op.Variables) -> Op.Data? {
        guard let plan = try? planner.getPlan(Op.document) else { return nil }
        guard let raw = queries.readQuery(plan: plan, variables: variables.__cachebay) else { return nil }
        return Op.Data(cachebayJSON: raw)
    }

    /// Subscribe to a query. `onData` fires with a typed `Op.Data` each time the
    /// underlying records change. Emissions whose eager decode fails (a required
    /// field went missing) are skipped — same contract as a `strictOK` miss.
    @discardableResult
    func watch<Op: CachebayOperation>(
        _ op: Op.Type,
        variables: Op.Variables,
        immediate: Bool = true,
        onData: @escaping @Sendable (Op.Data) -> Void,
        onError: (@Sendable (CombinedError) -> Void)? = nil
    ) throws -> WatchQueryHandle {
        // Use `Op.document` (precompiled plan, `@connection` metadata intact) so
        // connection watchers land on the canonical record — see the note in
        // `CachebayClient+Typed.watchQuery`.
        let plan = try planner.getPlan(Op.document)
        return queries.watchQuery(
            plan: plan,
            document: Op.document,
            options: WatchQueryOptions(
                variables: variables.__cachebay,
                immediate: immediate,
                onData: { json in
                    if let data = Op.Data(cachebayJSON: json) { onData(data) }
                },
                onError: onError
            )
        )
    }

    /// Run a query (cache + network per `cachePolicy`). Returns
    /// `OperationResult<Op.Data>`; the `onCacheData` / `onNetworkData` callbacks
    /// fire with typed, eagerly-decoded data. Network errors propagate via
    /// `result.error` — `try` is only for plan-compile failures.
    @discardableResult
    func execute<Op: CachebayOperation>(
        _ op: Op.Type,
        variables: Op.Variables,
        cachePolicy: CachePolicy? = nil,
        onCacheData: (@Sendable (_ data: Op.Data, _ willFetchFromNetwork: Bool) -> Void)? = nil,
        onNetworkData: (@Sendable (_ data: Op.Data) -> Void)? = nil,
        onError: (@Sendable (CombinedError) -> Void)? = nil
    ) async throws -> OperationResult<Op.Data> {
        var cacheCb: (@Sendable (JSONValue, Bool) -> Void)?
        if let typed = onCacheData {
            cacheCb = { json, willFetch in if let d = Op.Data(cachebayJSON: json) { typed(d, willFetch) } }
        }
        var netCb: (@Sendable (JSONValue) -> Void)?
        if let typed = onNetworkData {
            netCb = { json in if let d = Op.Data(cachebayJSON: json) { typed(d) } }
        }
        let plan = try planner.getPlan(Op.document)
        let opts = ExecuteQueryOptions(
            variables: variables.__cachebay,
            cachePolicy: cachePolicy,
            onCacheData: cacheCb,
            onNetworkData: netCb,
            onError: onError
        )
        let result = await operations.executeQuery(plan: plan, options: opts)
        return result.mapData { (json: JSONValue) -> Op.Data? in Op.Data(cachebayJSON: json) }
    }

    /// Run a mutation. Returns `OperationResult<Op.Data>` with the typed,
    /// eagerly-decoded response. `try` is only for plan-compile failures;
    /// GraphQL/network errors propagate via `result.error`.
    @discardableResult
    func execute<Op: CachebayOperation>(
        mutation op: Op.Type,
        variables: Op.Variables,
        onData: (@Sendable (_ data: Op.Data) -> Void)? = nil,
        onError: (@Sendable (CombinedError) -> Void)? = nil
    ) async throws -> OperationResult<Op.Data> {
        var dataCb: (@Sendable (JSONValue) -> Void)?
        if let typed = onData {
            dataCb = { json in if let d = Op.Data(cachebayJSON: json) { typed(d) } }
        }
        let plan = try planner.getPlan(Op.document)
        let opts = ExecuteMutationOptions(variables: variables.__cachebay, onData: dataCb, onError: onError)
        let result = await operations.executeMutation(plan: plan, options: opts)
        return result.mapData { (json: JSONValue) -> Op.Data? in Op.Data(cachebayJSON: json) }
    }
}
