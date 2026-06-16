import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Minimal HTTPTransport backed by `URLSession`. Sends GraphQL requests as
/// POST `application/json` bodies with `{query, variables}` and parses the
/// `{data, errors}` response.
public struct URLSessionHTTPTransport: HTTPTransport {
    public let url: URL
    public let session: URLSession
    public var headers: [String: String]
    public var requestModifier: (@Sendable (_ request: inout URLRequest) -> Void)?

    /// Optional profiler — when present, the JSON decode step of each
    /// response gets its own `cachebay.transport.http.decode` span. The
    /// wire RTT itself is intentionally NOT measured (server time isn't
    /// Cachebay's optimisation target); only the decode work that
    /// actually runs on the Cachebay side is timed.
    public let profiler: (any CachebayProfiler)?

    /// Automatic Persisted Queries (Apollo APQ). When `true` and the operation
    /// carries a baked `persistedHash`, the transport first POSTs the hash alone
    /// (no `query`); if the server replies `PersistedQueryNotFound`, it retries
    /// with the full query so the server registers it. Off by default — opt in
    /// once the server has APQ enabled.
    public var persistedQueries: Bool

    public init(
        url: URL,
        session: URLSession = .shared,
        headers: [String: String] = [:],
        requestModifier: (@Sendable (_ request: inout URLRequest) -> Void)? = nil,
        profiler: (any CachebayProfiler)? = nil,
        persistedQueries: Bool = false
    ) {
        self.url = url
        self.session = session
        self.headers = headers
        self.requestModifier = requestModifier
        self.profiler = profiler
        self.persistedQueries = persistedQueries
    }

    public func execute(_ context: HTTPContext) async throws -> OperationResult<JSONValue> {
        // APQ path: a baked hash + opt-in flag. Send the hash alone first; if the
        // server doesn't know it, register by retrying with the full query.
        if persistedQueries, let hash = context.persistedHash {
            let (first, firstErrors) = await send(
                Self.requestBody(query: nil, variables: context.variables, persistedHash: hash)
            )
            if Self.isPersistedQueryMiss(firstErrors) {
                return await send(
                    Self.requestBody(query: context.query, variables: context.variables, persistedHash: hash)
                ).0
            }
            return first
        }
        // Default: full query, no persisted-query extension (unchanged behavior).
        return await send(
            Self.requestBody(query: context.query, variables: context.variables, persistedHash: nil)
        ).0
    }

    /// Build a GraphQL POST body. Includes `query` only when provided (APQ's
    /// first attempt omits it), and the `extensions.persistedQuery` block only
    /// when a hash is provided.
    static func requestBody(query: String?, variables: [String: JSONValue], persistedHash: String?) -> JSONValue {
        var obj: [String: JSONValue] = ["variables": .object(variables)]
        if let query { obj["query"] = .string(query) }
        if let persistedHash {
            obj["extensions"] = .object([
                "persistedQuery": .object([
                    "version": .int(1),
                    "sha256Hash": .string(persistedHash),
                ])
            ])
        }
        return .object(obj)
    }

    /// `true` when the server signalled it can't resolve the persisted query —
    /// `PersistedQueryNotFound` (cold cache → register) or
    /// `PersistedQueryNotSupported` (APQ off → fall back). Either way we resend
    /// with the full query.
    static func isPersistedQueryMiss(_ errors: [GraphQLResponseError]) -> Bool {
        errors.contains { e in
            if e.message == "PersistedQueryNotFound" || e.message == "PersistedQueryNotSupported" {
                return true
            }
            if case .string(let code)? = e.extensions?["code"] {
                return code == "PERSISTED_QUERY_NOT_FOUND" || code == "PERSISTED_QUERY_NOT_SUPPORTED"
            }
            return false
        }
    }

    /// POST `body` and return the parsed result plus the raw GraphQL errors (so
    /// the APQ negotiation can inspect them). Network/HTTP failures map to an
    /// errored result with no GraphQL errors (never retried).
    private func send(_ body: JSONValue) async -> (OperationResult<JSONValue>, [GraphQLResponseError]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        requestModifier?(&request)

        do {
            request.httpBody = try body.encodeYYJSON(sortKeys: false, pretty: false)
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                return (OperationResult(data: nil, error: CombinedError(networkMessage: "HTTP \(http.statusCode): \(bodyText)")), [])
            }
            // Decode the response body — Cachebay's work, not the server's.
            // Wire RTT is excluded by the parent `executeQuery` span's
            // `excludingHost { ... }` wrapper; this span captures only
            // the parse + extract step. Useful when consumers see large
            // `firstEmit` durations and need to know whether the response
            // size is dominating before any normalize work begins.
            let decodeSpan = profiler?.begin("cachebay.transport.http.decode")
            decodeSpan?.attribute("bytes", "\(data.count)")
            let parsed = try JSONValue.from(json: data)
            let payloadData = parsed["data"] ?? .null
            let graphqlErrors = parseGraphQLErrors(parsed["errors"])
            decodeSpan?.end()
            let err: CombinedError? = graphqlErrors.isEmpty ? nil : CombinedError(graphqlErrors: graphqlErrors)
            if case .null = payloadData {
                return (OperationResult(data: nil, error: err), graphqlErrors)
            }
            return (OperationResult(data: payloadData, error: err), graphqlErrors)
        } catch {
            return (OperationResult(data: nil, error: CombinedError(networkError: error)), [])
        }
    }

    private func parseGraphQLErrors(_ v: JSONValue?) -> [GraphQLResponseError] {
        guard case .array(let arr) = v ?? .null else { return [] }
        var out: [GraphQLResponseError] = []
        for item in arr {
            guard case .object(let o) = item else { continue }
            let message = o["message"]?.string ?? "Unknown GraphQL error"
            var path: [String]? = nil
            if case .array(let a) = o["path"] ?? .null {
                path = a.compactMap { $0.string ?? $0.int.map { String($0) } }
            }
            var locations: [GraphQLResponseError.Location]? = nil
            if case .array(let a) = o["locations"] ?? .null {
                locations = a.compactMap {
                    guard case .object(let l) = $0,
                        let line = l["line"]?.int,
                        let col = l["column"]?.int
                    else { return nil }
                    return .init(line: Int(line), column: Int(col))
                }
            }
            var ext: [String: JSONValue]? = nil
            if case .object(let e) = o["extensions"] ?? .null { ext = e }
            out.append(GraphQLResponseError(message: message, path: path, locations: locations, extensions: ext))
        }
        return out
    }
}

#if canImport(FoundationNetworking)
    // Linux/Foundation stubs URLSession.data(for:); provide a bridge when necessary.
    extension URLSession {
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            try await withCheckedThrowingContinuation { cont in
                let task = self.dataTask(with: request) { data, response, error in
                    if let error { cont.resume(throwing: error); return }
                    guard let data, let response else {
                        cont.resume(throwing: URLError(.badServerResponse)); return
                    }
                    cont.resume(returning: (data, response))
                }
                task.resume()
            }
        }
    }
#endif
