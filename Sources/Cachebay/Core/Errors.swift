import Foundation

public enum CachebayError: Error, CustomStringConvertible, Sendable {
    case cacheMiss(String)
    case invalidJSON(String)
    case invalidPlan(String)
    case networkError(String)
    case graphql(messages: [String])
    case staleResponse
    case invalidCachePolicy(String)
    case invalidConnection(String)
    case invalidFragment(String)

    public var description: String {
        switch self {
        case .cacheMiss(let s): return "[cache-miss] \(s)"
        case .invalidJSON(let s): return "[invalid-json] \(s)"
        case .invalidPlan(let s): return "[invalid-plan] \(s)"
        case .networkError(let s): return "[network] \(s)"
        case .graphql(let ms): return "[graphql] " + ms.joined(separator: "; ")
        case .staleResponse: return "[stale] a newer request superseded this one"
        case .invalidCachePolicy(let s): return "[invalid-cache-policy] \(s)"
        case .invalidConnection(let s): return "[invalid-connection] \(s)"
        case .invalidFragment(let s): return "[invalid-fragment] \(s)"
        }
    }
}

public struct GraphQLResponseError: Error, Hashable, Sendable {
    public let message: String
    public let path: [String]?
    public let locations: [Location]?
    public let extensions: [String: JSONValue]?

    public struct Location: Hashable, Sendable {
        public let line: Int
        public let column: Int
        public init(line: Int, column: Int) {
            self.line = line; self.column = column
        }
    }

    public init(message: String, path: [String]? = nil, locations: [Location]? = nil, extensions: [String: JSONValue]? = nil) {
        self.message = message
        self.path = path
        self.locations = locations
        self.extensions = extensions
    }
}

/// Aggregated error covering both network and GraphQL errors — parallels
/// the JS `CombinedError`. Returned in `OperationResult.error` and delivered
/// to watchers when a cache signature's in-flight request fails.
public struct CombinedError: Error, CustomStringConvertible, Sendable, Hashable {
    public let networkError: String?
    public let graphqlErrors: [GraphQLResponseError]

    public init(networkError: Error? = nil, graphqlErrors: [GraphQLResponseError] = []) {
        if let networkError {
            // Keep only the message so the whole type remains Sendable/Hashable.
            self.networkError = "\(networkError)"
        } else {
            self.networkError = nil
        }
        self.graphqlErrors = graphqlErrors
    }

    public init(networkMessage: String?, graphqlErrors: [GraphQLResponseError] = []) {
        self.networkError = networkMessage
        self.graphqlErrors = graphqlErrors
    }

    public var description: String {
        if let net = networkError { return "[Network] \(net)" }
        if !graphqlErrors.isEmpty {
            return graphqlErrors.map { "[GraphQL] \($0.message)" }.joined(separator: "\n")
        }
        return "[Error] unspecified"
    }

    public var localizedDescription: String { description }
}

public extension CombinedError {
    static func cacheMiss(_ message: String = "Cache miss: no data available for cache-only query") -> CombinedError {
        CombinedError(networkMessage: message)
    }
    static func stale() -> CombinedError {
        CombinedError(networkMessage: "Response ignored: newer request in flight")
    }
}
