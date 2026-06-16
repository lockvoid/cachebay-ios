import XCTest
@testable import Cachebay
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Automatic Persisted Queries (APQ) on `URLSessionHTTPTransport`.
///
/// Off by default. When on (and the operation carries a build-time
/// `persistedHash`), the transport POSTs the hash alone; on a
/// `PersistedQueryNotFound` it retries with the full query so the server
/// registers it. The hash itself is baked by `cachebay-cli` over the wire
/// `networkQuery` — the runtime never hashes.
final class PersistedQueryTransportTests: XCTestCase {

    // MARK: - requestBody (pure — the wire shapes)

    func test_requestBody_default_includesQuery_noExtensions() {
        let b = URLSessionHTTPTransport.requestBody(query: "Q", variables: ["a": .int(1)], persistedHash: nil)
        XCTAssertEqual(b["query"], .string("Q"))
        XCTAssertEqual(b["variables"], .object(["a": .int(1)]))
        XCTAssertNil(b["extensions"], "no persisted-query extension when no hash")
    }

    func test_requestBody_hashOnly_omitsQuery_addsExtensions() {
        let b = URLSessionHTTPTransport.requestBody(query: nil, variables: [:], persistedHash: "abc")
        XCTAssertNil(b["query"], "first APQ attempt sends the hash WITHOUT the query")
        XCTAssertEqual(b["extensions"]?["persistedQuery"]?["version"], .int(1))
        XCTAssertEqual(b["extensions"]?["persistedQuery"]?["sha256Hash"], .string("abc"))
    }

    func test_requestBody_retry_includesQueryAndExtensions() {
        let b = URLSessionHTTPTransport.requestBody(query: "Q", variables: [:], persistedHash: "abc")
        XCTAssertEqual(b["query"], .string("Q"), "the retry registers the query")
        XCTAssertEqual(b["extensions"]?["persistedQuery"]?["sha256Hash"], .string("abc"))
    }

    // MARK: - isPersistedQueryMiss (pure — when to retry)

    func test_miss_byMessage() {
        XCTAssertTrue(URLSessionHTTPTransport.isPersistedQueryMiss([GraphQLResponseError(message: "PersistedQueryNotFound")]))
        XCTAssertTrue(URLSessionHTTPTransport.isPersistedQueryMiss([GraphQLResponseError(message: "PersistedQueryNotSupported")]))
    }

    func test_miss_byExtensionsCode() {
        let e = GraphQLResponseError(message: "boom", extensions: ["code": .string("PERSISTED_QUERY_NOT_FOUND")])
        XCTAssertTrue(URLSessionHTTPTransport.isPersistedQueryMiss([e]))
    }

    func test_miss_falseForUnrelatedOrEmpty() {
        XCTAssertFalse(URLSessionHTTPTransport.isPersistedQueryMiss([GraphQLResponseError(message: "Validation failed")]))
        XCTAssertFalse(URLSessionHTTPTransport.isPersistedQueryMiss([]))
    }

    // MARK: - end-to-end negotiation (request count via a URLProtocol stub)

    private func transport(persistedQueries: Bool) -> URLSessionHTTPTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [APQStubURLProtocol.self]
        return URLSessionHTTPTransport(
            url: URL(string: "https://example.test/graphql")!,
            session: URLSession(configuration: config),
            persistedQueries: persistedQueries
        )
    }

    private func ctx(hash: String?) -> HTTPContext {
        HTTPContext(query: "query Q { ok }", variables: [:], operationType: .query, persistedHash: hash)
    }

    private static let okBody = Data(#"{"data":{"ok":true}}"#.utf8)
    private static let missBody = Data(#"{"errors":[{"message":"PersistedQueryNotFound"}]}"#.utf8)

    func test_apq_miss_retriesWithFullQuery() async throws {
        APQStubURLProtocol.reset([(200, Self.missBody), (200, Self.okBody)])
        let res = try await transport(persistedQueries: true).execute(ctx(hash: "abc123"))
        XCTAssertEqual(APQStubURLProtocol.count(), 2, "cold cache → hash-only then retry-with-query")
        XCTAssertEqual(res.data?["ok"], .bool(true))
        XCTAssertNil(res.error)
    }

    func test_apq_hit_singleRequest() async throws {
        APQStubURLProtocol.reset([(200, Self.okBody)])
        let res = try await transport(persistedQueries: true).execute(ctx(hash: "abc123"))
        XCTAssertEqual(APQStubURLProtocol.count(), 1, "warm cache → one request, hash only")
        XCTAssertEqual(res.data?["ok"], .bool(true))
    }

    func test_apq_disabled_doesNotNegotiate_evenWithHash() async throws {
        APQStubURLProtocol.reset([(200, Self.okBody)])
        let res = try await transport(persistedQueries: false).execute(ctx(hash: "abc123"))
        XCTAssertEqual(APQStubURLProtocol.count(), 1, "default off → plain full-query request")
        XCTAssertEqual(res.data?["ok"], .bool(true))
    }

    func test_apq_enabled_butNilHash_sendsFullQueryNoNegotiation() async throws {
        // Runtime-compiled plans have no hash → APQ is skipped, full query sent.
        APQStubURLProtocol.reset([(200, Self.okBody)])
        let res = try await transport(persistedQueries: true).execute(ctx(hash: nil))
        XCTAssertEqual(APQStubURLProtocol.count(), 1)
        XCTAssertEqual(res.data?["ok"], .bool(true))
    }
}

/// Minimal `URLProtocol` stub: serves a FIFO queue of `(status, body)` and
/// counts requests. Scoped to the test session via `protocolClasses`.
final class APQStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var queue: [(Int, Data)] = []
    nonisolated(unsafe) private static var requests = 0
    private static let lock = NSLock()

    static func reset(_ responses: [(Int, Data)]) {
        lock.lock(); defer { lock.unlock() }
        queue = responses
        requests = 0
    }

    static func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let next: (Int, Data) = {
            APQStubURLProtocol.lock.lock(); defer { APQStubURLProtocol.lock.unlock() }
            APQStubURLProtocol.requests += 1
            return APQStubURLProtocol.queue.isEmpty ? (200, Data("{}".utf8)) : APQStubURLProtocol.queue.removeFirst()
        }()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.0,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
