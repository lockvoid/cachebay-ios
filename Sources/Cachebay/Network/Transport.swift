import Foundation

/// GraphQL operation kind. Passed to `HTTPTransport.execute` so
/// custom transports can route queries / mutations / subscriptions
/// over different paths if needed.
public enum OperationType: Sendable, Hashable {
    case query
    case mutation
    case subscription
}

/// Context passed to `HTTPTransport.execute`. The transport should send
/// `query` (the networkQuery string) and `variables` to the server and return
/// `OperationResult(data:error:)`.
public struct HTTPContext: Sendable {
    public let query: String
    public let variables: [String: JSONValue]
    public let operationType: OperationType
    /// SHA-256 of `query` baked at build time, or `nil` for runtime-compiled
    /// operations. A persisted-query-aware transport can send this instead of
    /// (or alongside) `query`; plain transports ignore it.
    public let persistedHash: String?
    public init(query: String, variables: [String: JSONValue], operationType: OperationType, persistedHash: String? = nil) {
        self.query = query
        self.variables = variables
        self.operationType = operationType
        self.persistedHash = persistedHash
    }
}

/// Context passed to `WSTransport.subscribe`. The transport should
/// open a `graphql-transport-ws` (or compatible) subscription with
/// `query` + `variables` and yield raw server events.
public struct WSContext: Sendable {
    public let query: String
    public let variables: [String: JSONValue]
    /// SHA-256 of `query` baked at build time, or `nil` for runtime-compiled
    /// operations. Available for custom subscription transports that support
    /// persisted queries; the built-in transport ignores it.
    public let persistedHash: String?
    public init(query: String, variables: [String: JSONValue], persistedHash: String? = nil) {
        self.query = query
        self.variables = variables
        self.persistedHash = persistedHash
    }
}

/// The shape every operation entry point returns. `data` is the
/// materialized typed result (or raw JSON via the JSON-shaped
/// overloads); `error` carries network + GraphQL errors combined;
/// `meta.source` indicates whether the data came from cache or
/// network on cache-and-network policies.
public struct OperationResult<TData: Sendable>: Sendable {
    public var data: TData?
    public var error: CombinedError?
    public var meta: Meta?

    public struct Meta: Sendable, Hashable {
        public enum Source: Sendable, Hashable { case cache; case network }
        public var source: Source?
        public init(source: Source? = nil) { self.source = source }
    }

    public init(data: TData? = nil, error: CombinedError? = nil, meta: Meta? = nil) {
        self.data = data
        self.error = error
        self.meta = meta
    }
}

/// Send a GraphQL operation over HTTP and return the server's
/// response. Implement this for custom auth flows, retry policies,
/// or alternate wire formats. `URLSessionHTTPTransport` is the
/// built-in implementation.
public protocol HTTPTransport: Sendable {
    func execute(_ context: HTTPContext) async throws -> OperationResult<JSONValue>
}

/// Stream a GraphQL subscription. Returns an async throwing stream
/// of raw server events (each typically shaped like
/// `{data: …, errors: …}`). Cachebay normalizes every frame
/// independently before delivering.
public protocol WSTransport: Sendable {
    func subscribe(_ context: WSContext) -> AsyncThrowingStream<OperationResult<JSONValue>, Error>
}

/// Bundles HTTP + (optional) WS transports. Pass to
/// `CachebayOptions.transport` at client construction.
public struct Transport: Sendable {
    public var http: HTTPTransport
    public var ws: WSTransport?
    public init(http: HTTPTransport, ws: WSTransport? = nil) {
        self.http = http
        self.ws = ws
    }
}
