import XCTest
@testable import Cachebay

/// Black-box port of `cachebay-web/test/unit/core/operations-execute-queries.test.ts`
/// + `cache-policy-validation.test.ts`. Verifies cache-policy fanout
/// (cache-only / cache-first / cache-and-network / network-only),
/// `onCacheData` willFetchFromNetwork flag, suspension window de-dup,
/// CombinedError construction, and default-policy fallback.
///
/// Implementation detail mapped:
///   web `mockDocuments.materialize` ⇒ iOS exercises the real
///   Documents/Graph stack via `MockHTTPTransport` + `executeQuery`.
final class OperationsCachePolicyTests: XCTestCase {

    private let postQuery = "query Post($id: ID!) { post(id: $id) { id title } }"

    private func makeClient(
        defaultPolicy: CachePolicy = .cacheFirst,
        suspensionTimeout: TimeInterval = 0,
        http: MockHTTPTransport = MockHTTPTransport()
    ) -> (CachebayClient, MockHTTPTransport) {
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: http),
                cachePolicy: defaultPolicy,
                suspensionTimeout: suspensionTimeout
            ))
        return (client, http)
    }

    private func canned(_ id: String, title: String) -> JSONValue {
        return .object([
            "post": .object([
                "__typename": "Post",
                "id": .string(id),
                "title": .string(title),
            ])
        ])
    }

    // MARK: - CombinedError construction

    /// Mirrors web `CombinedError: creates error from network error`.
    func test_combinedError_fromNetworkError_carriesNetworkMessage() {
        let net = NSError(domain: "X", code: 1, userInfo: [NSLocalizedDescriptionKey: "Network failed"])
        let err = CombinedError(networkError: net)
        XCTAssertNotNil(err.networkError)
        XCTAssertTrue(err.description.hasPrefix("[Network] "))
        XCTAssertTrue(err.graphqlErrors.isEmpty)
    }

    /// Mirrors web `CombinedError: creates error from GraphQL errors`.
    func test_combinedError_fromGraphQLErrors_listsAll() {
        let err = CombinedError(graphqlErrors: [
            GraphQLResponseError(message: "Field not found"),
            GraphQLResponseError(message: "Invalid argument"),
        ])
        XCTAssertNil(err.networkError)
        XCTAssertEqual(err.graphqlErrors.count, 2)
        XCTAssertTrue(err.description.contains("[GraphQL] Field not found"))
        XCTAssertTrue(err.description.contains("[GraphQL] Invalid argument"))
    }

    /// Mirrors web `CombinedError: prioritizes network error over
    /// GraphQL errors`. Description must show the network branch
    /// first; GraphQL errors are still preserved on the value.
    func test_combinedError_prioritizesNetworkOverGraphQL() {
        let net = NSError(domain: "X", code: 1, userInfo: [NSLocalizedDescriptionKey: "Network failed"])
        let err = CombinedError(networkError: net, graphqlErrors: [GraphQLResponseError(message: "Field not found")])
        XCTAssertTrue(err.description.hasPrefix("[Network] "))
        XCTAssertEqual(err.graphqlErrors.count, 1)
    }

    /// Mirrors web `CombinedError: converts to string`.
    func test_combinedError_descriptionStable() {
        let err = CombinedError(networkMessage: "Failed")
        XCTAssertEqual(err.description, "[Network] Failed")
    }

    // MARK: - network-only

    /// Mirrors web `network-only: always fetches from network and
    /// ignores cache`. Pre-warm cache, then network-only should still
    /// hit the wire.
    func test_networkOnly_alwaysFetches_evenWithWarmCache() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("post", respondWith: canned("p1", title: "Network"))
        try client.writeQuery(query: postQuery, variables: ["id": "p1"], data: canned("p1", title: "Cached"))
        XCTAssertEqual(http.calls.count, 0)

        _ = try await client.executeQuery(query: postQuery, variables: ["id": "p1"], cachePolicy: .networkOnly)
        XCTAssertEqual(http.calls.count, 1)
    }

    /// Mirrors web `network-only: invokes onNetworkData callback`.
    func test_networkOnly_invokesOnNetworkData() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("post", respondWith: canned("p1", title: "Hello"))

        let captured = CaptureBox<[JSONValue]>(value: [])
        _ = try await client.executeQuery(
            query: postQuery,
            variables: ["id": "p1"],
            cachePolicy: .networkOnly,
            onNetworkData: { captured.append($0) }
        )
        XCTAssertEqual(captured.value.count, 1)
        XCTAssertEqual(captured.value[0]["post"]?["title"]?.string, "Hello")
    }

    /// Mirrors web `network-only: invokes onError callback on network
    /// failure`. Mock returns an error frame; the per-call onError
    /// must fire and the result must carry the error.
    func test_networkOnly_invokesOnError_onTransportFailure() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("post") { _ in
            OperationResult(data: nil, error: CombinedError(networkMessage: "Network failed"))
        }

        let errors = CaptureBox<[CombinedError]>(value: [])
        let result = try await client.executeQuery(
            query: postQuery,
            variables: ["id": "p1"],
            cachePolicy: .networkOnly,
            onError: { e in errors.withLock { $0.append(e) } }
        )
        XCTAssertNil(result.data)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(errors.value.count, 1)
        XCTAssertEqual(errors.value[0].networkError, "Network failed")
    }

    // MARK: - cache-first

    /// Mirrors web `cache-first: returns cached data when canonical
    /// AND strict cache hit`. Data was previously written with the
    /// same vars → no network.
    func test_cacheFirst_strictAndCanonicalHit_skipsNetwork() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("post", respondWith: canned("p1", title: "Network"))
        try client.writeQuery(query: postQuery, variables: ["id": "p1"], data: canned("p1", title: "Cached"))

        let captured = CaptureBox<[(JSONValue, Bool)]>(value: [])
        let result = try await client.executeQuery(
            query: postQuery,
            variables: ["id": "p1"],
            cachePolicy: .cacheFirst,
            onCacheData: { data, willFetch in captured.withLock { $0.append((data, willFetch)) } }
        )
        XCTAssertEqual(result.data?["post"]?["title"]?.string, "Cached")
        XCTAssertEqual(http.calls.count, 0, "cache-first must not hit network on a strict+canonical hit")
        XCTAssertEqual(captured.value.count, 1)
        XCTAssertEqual(captured.value[0].1, false, "willFetchFromNetwork must be false on cache-first hit")
    }

    /// Mirrors web `cache-first: fetches from network when strict
    /// cache hit but canonical cache miss`. With suspension disabled
    /// and no prior write, the first call goes to network.
    func test_cacheFirst_emptyCache_fetchesNetwork() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("post", respondWith: canned("p1", title: "Network"))

        let result = try await client.executeQuery(
            query: postQuery,
            variables: ["id": "p1"],
            cachePolicy: .cacheFirst
        )
        XCTAssertEqual(result.data?["post"]?["title"]?.string, "Network")
        XCTAssertEqual(result.meta?.source, .network)
        XCTAssertEqual(http.calls.count, 1)
    }

    // MARK: - cache-only

    /// Mirrors web `cache-only: returns cached data when available`.
    func test_cacheOnly_withCacheHit_returnsCacheNeverNetwork() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("post", respondWith: canned("p1", title: "Network"))
        try client.writeQuery(query: postQuery, variables: ["id": "p1"], data: canned("p1", title: "Cached"))

        let cacheCalls = CaptureBox<[(JSONValue, Bool)]>(value: [])
        let result = try await client.executeQuery(
            query: postQuery,
            variables: ["id": "p1"],
            cachePolicy: .cacheOnly,
            onCacheData: { d, w in cacheCalls.withLock { $0.append((d, w)) } }
        )
        XCTAssertEqual(result.data?["post"]?["title"]?.string, "Cached")
        XCTAssertNil(result.error)
        XCTAssertEqual(http.calls.count, 0)
        XCTAssertEqual(cacheCalls.value.count, 1)
        XCTAssertEqual(cacheCalls.value[0].1, false, "willFetchFromNetwork must be false on cache-only hit")
    }

    /// Mirrors web `cache-only: returns CacheMissError when no cache`
    /// + onError invocation.
    func test_cacheOnly_withCacheMiss_returnsCacheMissError() async throws {
        let (client, http) = makeClient()
        let errors = CaptureBox<[CombinedError]>(value: [])
        let result = try await client.executeQuery(
            query: postQuery,
            variables: ["id": "miss"],
            cachePolicy: .cacheOnly,
            onError: { e in errors.withLock { $0.append(e) } }
        )
        XCTAssertNil(result.data)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(http.calls.count, 0)
        XCTAssertEqual(errors.value.count, 1)
        XCTAssertTrue(errors.value[0].networkError?.contains("Cache miss") ?? false)
    }

    // MARK: - cache-and-network

    /// Mirrors web `cache-and-network: returns network data after
    /// onCacheData with cached data`. With suspension disabled, both
    /// paths fire — onCacheData immediately, then network resolves.
    func test_cacheAndNetwork_withCacheHit_callsCacheAndThenNetwork() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("post", respondWith: canned("p1", title: "Network"))
        try client.writeQuery(query: postQuery, variables: ["id": "p1"], data: canned("p1", title: "Cached"))

        let cacheCalls = CaptureBox<[(JSONValue, Bool)]>(value: [])
        let netCalls = CaptureBox<[JSONValue]>(value: [])
        let result = try await client.executeQuery(
            query: postQuery,
            variables: ["id": "p1"],
            cachePolicy: .cacheAndNetwork,
            onCacheData: { d, w in cacheCalls.withLock { $0.append((d, w)) } },
            onNetworkData: { netCalls.append($0) }
        )

        XCTAssertEqual(result.data?["post"]?["title"]?.string, "Network")
        XCTAssertEqual(result.meta?.source, .network)
        XCTAssertEqual(cacheCalls.value.count, 1, "onCacheData must fire once on cache hit")
        XCTAssertEqual(cacheCalls.value[0].1, true, "willFetchFromNetwork must be true on cache-and-network")
        XCTAssertEqual(netCalls.value.count, 1)
        XCTAssertEqual(netCalls.value[0]["post"]?["title"]?.string, "Network")
        XCTAssertEqual(http.calls.count, 1)
    }

    /// Mirrors web `cache-and-network: handles network fetch errors
    /// and returns error`. Cache hit fires onCacheData, then network
    /// fails — onError fires and result.error is set.
    func test_cacheAndNetwork_withCacheHit_andNetworkError_callsBoth() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("post") { _ in
            OperationResult(data: nil, error: CombinedError(networkMessage: "Network fetch failed"))
        }
        try client.writeQuery(query: postQuery, variables: ["id": "p1"], data: canned("p1", title: "Cached"))

        let cacheCalls = CaptureBox<[(JSONValue, Bool)]>(value: [])
        let errors = CaptureBox<[CombinedError]>(value: [])
        let result = try await client.executeQuery(
            query: postQuery,
            variables: ["id": "p1"],
            cachePolicy: .cacheAndNetwork,
            onCacheData: { d, w in cacheCalls.withLock { $0.append((d, w)) } },
            onError: { e in errors.withLock { $0.append(e) } }
        )

        XCTAssertEqual(cacheCalls.value.count, 1, "cache callback must still fire on hit")
        XCTAssertEqual(cacheCalls.value[0].1, true)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(errors.value.count, 1)
        XCTAssertTrue(errors.value[0].networkError?.contains("Network fetch failed") ?? false)
    }

    /// Mirrors web `cache-and-network: fetches from network when no
    /// cache available`. No prior write → onCacheData NOT called, but
    /// network result still arrives.
    func test_cacheAndNetwork_withCacheMiss_doesNotCallCacheData() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("post", respondWith: canned("p1", title: "Network"))

        let cacheCalls = CaptureBox<[JSONValue]>(value: [])
        let result = try await client.executeQuery(
            query: postQuery,
            variables: ["id": "p1"],
            cachePolicy: .cacheAndNetwork,
            onCacheData: { d, _ in cacheCalls.append(d) }
        )

        XCTAssertEqual(result.data?["post"]?["title"]?.string, "Network")
        XCTAssertEqual(http.calls.count, 1)
        XCTAssertEqual(cacheCalls.value.count, 0, "no cache hit ⇒ no onCacheData")
    }

    // MARK: - meta.source field

    /// Mirrors web `meta.source: 'network' for network responses`.
    func test_meta_source_network_onNetworkResponse() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("post", respondWith: canned("p1", title: "X"))
        let r = try await client.executeQuery(query: postQuery, variables: ["id": "p1"], cachePolicy: .networkOnly)
        XCTAssertEqual(r.meta?.source, .network)
    }

    /// Mirrors web `meta.source: 'cache' for cache-first cache hit`.
    /// (Web uses `undefined`; iOS chose to mark cache hits explicitly
    /// with `.cache` — pinned by `ClientIntegrationTests` already, but
    /// the cache-only branch is also distinct: it returns `.cache`.)
    func test_meta_source_cache_onCacheOnlyHit() async throws {
        let (client, _) = makeClient()
        try client.writeQuery(query: postQuery, variables: ["id": "p1"], data: canned("p1", title: "Cached"))
        let r = try await client.executeQuery(query: postQuery, variables: ["id": "p1"], cachePolicy: .cacheOnly)
        XCTAssertEqual(r.meta?.source, .cache)
    }

    // MARK: - default cache policy from options

    /// Mirrors web `defaults: uses default cachePolicy from options
    /// when not provided in executeQuery`. Construct the client with
    /// `cacheFirst` as default, pre-warm cache, then call without an
    /// explicit policy → no network hit.
    func test_optionsDefaultPolicy_appliesWhenCallerOmits() async throws {
        let (client, http) = makeClient(defaultPolicy: .cacheFirst)
        http.whenQueryContains("post", respondWith: canned("p1", title: "Network"))
        try client.writeQuery(query: postQuery, variables: ["id": "p1"], data: canned("p1", title: "Cached"))

        let r = try await client.executeQuery(query: postQuery, variables: ["id": "p1"])
        XCTAssertEqual(r.data?["post"]?["title"]?.string, "Cached")
        XCTAssertEqual(http.calls.count, 0)
    }

    /// Mirrors web `executeQuery cachePolicy takes priority over
    /// options cachePolicy`. Default = cacheFirst, but caller asks
    /// network-only — must hit the wire.
    func test_callerCachePolicy_overridesOptionsDefault() async throws {
        let (client, http) = makeClient(defaultPolicy: .cacheFirst)
        http.whenQueryContains("post", respondWith: canned("p1", title: "Network"))
        try client.writeQuery(query: postQuery, variables: ["id": "p1"], data: canned("p1", title: "Cached"))

        let r = try await client.executeQuery(
            query: postQuery,
            variables: ["id": "p1"],
            cachePolicy: .networkOnly
        )
        XCTAssertEqual(r.data?["post"]?["title"]?.string, "Network")
        XCTAssertEqual(http.calls.count, 1)
    }

    // MARK: - Cache policy validation (port of cache-policy-validation.test.ts)

    /// Mirrors web `accepts 'cache-first' / 'cache-only' / 'network-only' /
    /// 'cache-and-network'` block. iOS's `CachePolicy` is an enum, so
    /// invalid values are caught at compile time — only the valid path
    /// is testable here, but we still verify each enum case round-trips
    /// through `executeQuery` without crashing.
    func test_allCachePolicyEnumCases_acceptedByExecuteQuery() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("post", respondWith: canned("p1", title: "Hello"))
        // Pre-warm so cacheOnly succeeds.
        _ = try await client.executeQuery(query: postQuery, variables: ["id": "p1"], cachePolicy: .networkOnly)

        for policy in CachePolicy.allCases {
            let r = try await client.executeQuery(
                query: postQuery,
                variables: ["id": "p1"],
                cachePolicy: policy
            )
            XCTAssertNotNil(r.data ?? r.error, "executeQuery with \(policy) should produce data or error")
        }
    }

    // MARK: - Suspension window

    /// Mirrors web `suspension window: returns cached data`. Two calls
    /// with the same strict signature inside the suspension window
    /// reuse the previous result without hitting the network. Also
    /// verifies onCacheData fires with willFetchFromNetwork = false.
    func test_suspensionWindow_secondCallReusesCachedResult() async throws {
        let (client, http) = makeClient(suspensionTimeout: 1.0)
        http.whenQueryContains("post", respondWith: canned("p1", title: "Network"))

        // First call seeds the suspension window.
        _ = try await client.executeQuery(
            query: postQuery,
            variables: ["id": "p1"],
            cachePolicy: .cacheFirst
        )
        XCTAssertEqual(http.calls.count, 1)

        // Second call within suspension window must NOT hit network.
        let cacheCalls = CaptureBox<[(JSONValue, Bool)]>(value: [])
        let r = try await client.executeQuery(
            query: postQuery,
            variables: ["id": "p1"],
            cachePolicy: .cacheFirst,
            onCacheData: { d, w in cacheCalls.withLock { $0.append((d, w)) } }
        )
        XCTAssertEqual(http.calls.count, 1, "suspension must dedupe identical concurrent requests")
        XCTAssertEqual(r.data?["post"]?["title"]?.string, "Network")
        XCTAssertEqual(cacheCalls.value.count, 1)
        XCTAssertEqual(cacheCalls.value[0].1, false, "suspension hit ⇒ willFetchFromNetwork = false")
    }

    /// Mirrors web `suspension window should NOT reuse suspended
    /// response when pagination params change`. With the same canonical
    /// signature but a different strict signature (different
    /// pagination), the second request must NOT be suppressed.
    func test_suspensionWindow_doesNotReuseAcrossDifferentStrictSignatures() async throws {
        let (client, http) = makeClient(suspensionTimeout: 1.0)
        let pagedQuery = """
            query GetPosts($first: Int!, $after: String) {
                posts(first: $first, after: $after) {
                    edges { cursor node { id title } }
                    pageInfo { hasNextPage endCursor }
                }
            }
            """
        let firstPage: JSONValue = .object([
            "posts": .object([
                "__typename": "PostConnection",
                "edges": .array([
                    .object([
                        "__typename": "PostEdge", "cursor": "c1",
                        "node": .object(["__typename": "Post", "id": "1", "title": "First"]),
                    ])
                ]),
                "pageInfo": .object([
                    "__typename": "PageInfo",
                    "hasNextPage": true, "endCursor": "c1",
                ]),
            ])
        ])
        let secondPage: JSONValue = .object([
            "posts": .object([
                "__typename": "PostConnection",
                "edges": .array([
                    .object([
                        "__typename": "PostEdge", "cursor": "c2",
                        "node": .object(["__typename": "Post", "id": "2", "title": "Second"]),
                    ])
                ]),
                "pageInfo": .object([
                    "__typename": "PageInfo",
                    "hasNextPage": false, "endCursor": "c2",
                ]),
            ])
        ])
        http.whenQueryContains("posts") { vars in
            if vars["first"]?.int == 20 {
                return OperationResult(data: secondPage)
            }
            return OperationResult(data: firstPage)
        }

        // First page request.
        _ = try await client.executeQuery(
            query: pagedQuery,
            variables: ["first": .int(10), "after": .null],
            cachePolicy: .cacheFirst
        )
        XCTAssertEqual(http.calls.count, 1)

        // Second page within suspension window — different pagination
        // arg ⇒ different strict signature ⇒ MUST hit the wire.
        let r = try await client.executeQuery(
            query: pagedQuery,
            variables: ["first": .int(20), "after": .null],
            cachePolicy: .cacheFirst
        )
        XCTAssertEqual(http.calls.count, 2, "different pagination must bypass suspension")
        XCTAssertEqual(r.data?["posts"]?["edges"]?.array?.first?["node"]?["id"]?.string, "2")
    }

    // MARK: - onCacheData willFetchFromNetwork flag

    /// Mirrors web `network-only: onCacheData not called (ignores cache)`.
    func test_networkOnly_doesNotCallOnCacheData_evenWithWarmCache() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("post", respondWith: canned("p1", title: "Network"))
        try client.writeQuery(query: postQuery, variables: ["id": "p1"], data: canned("p1", title: "Cached"))

        let cacheCalls = CaptureBox<[JSONValue]>(value: [])
        _ = try await client.executeQuery(
            query: postQuery,
            variables: ["id": "p1"],
            cachePolicy: .networkOnly,
            onCacheData: { d, _ in cacheCalls.append(d) }
        )
        XCTAssertEqual(cacheCalls.value.count, 0, "network-only must never invoke onCacheData")
    }

    // MARK: - Variables defaulting

    /// Mirrors web `executeQuery: uses empty object for missing
    /// variables`. Calling `executeQuery` without variables must still
    /// reach the transport with an empty variables map (not nil/missing
    /// arg) — keeps signature/canonicalisation deterministic.
    func test_executeQuery_missingVariables_defaultsToEmptyDict() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains(
            "me",
            respondWith: .object([
                "me": .object(["__typename": "User", "id": "u1", "name": "Alice"])
            ]))
        _ = try await client.executeQuery(query: "query { me { id name } }", cachePolicy: .networkOnly)

        XCTAssertEqual(http.calls.count, 1)
        // The request should land with an empty variables dict.
        XCTAssertTrue(
            http.calls[0].variables.isEmpty,
            "missing variables must materialise as an empty dictionary on the wire"
        )
    }

    /// Mirrors web `cache-first with cache miss: onCacheData not
    /// called`. No prior write → onCacheData stays silent; network
    /// resolves the request.
    func test_cacheFirst_withCacheMiss_doesNotCallOnCacheData() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("post", respondWith: canned("p1", title: "Network"))

        let cacheCalls = CaptureBox<[JSONValue]>(value: [])
        let r = try await client.executeQuery(
            query: postQuery,
            variables: ["id": "p1"],
            cachePolicy: .cacheFirst,
            onCacheData: { d, _ in cacheCalls.append(d) }
        )
        XCTAssertEqual(cacheCalls.value.count, 0, "no cached data ⇒ no onCacheData")
        XCTAssertEqual(r.data?["post"]?["title"]?.string, "Network")
        XCTAssertEqual(http.calls.count, 1)
    }
}
