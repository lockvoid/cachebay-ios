import Foundation

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
    public init(query: String, variables: [String: JSONValue], operationType: OperationType) {
        self.query = query
        self.variables = variables
        self.operationType = operationType
    }
}

public struct WSContext: Sendable {
    public let query: String
    public let variables: [String: JSONValue]
    public init(query: String, variables: [String: JSONValue]) {
        self.query = query
        self.variables = variables
    }
}

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

public protocol HTTPTransport: Sendable {
    func execute(_ context: HTTPContext) async throws -> OperationResult<JSONValue>
}

public protocol WSTransport: Sendable {
    /// Returns an async throwing stream of raw server events (each typically
    /// shaped like `{data: …, errors: …}`). Cachebay normalizes every frame
    /// independently before delivering.
    func subscribe(_ context: WSContext) -> AsyncThrowingStream<OperationResult<JSONValue>, Error>
}

public struct Transport: Sendable {
    public var http: HTTPTransport
    public var ws: WSTransport?
    public init(http: HTTPTransport, ws: WSTransport? = nil) {
        self.http = http
        self.ws = ws
    }
}
