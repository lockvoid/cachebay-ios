import XCTest
@testable import Cachebay

/// Port of `cachebay-web/test/unit/core/operations-performance.test.ts`.
///
/// The web tests count normalize/materialize calls via a `vi.mock` shim. iOS
/// has no analogue; the tests below pin the *observable* fanout behaviour
/// the counters were designed to protect:
/// - emission counts on watchers across cache policies
/// - bulk operation correctness over 5/10 sequential calls
/// - mutation single-fanout
/// - WITH-watcher / WITHOUT-watcher cache invalidation behaviour
///   (matched by checking whether subsequent reads see fresh graph writes).
final class OperationsPerformanceTests: XCTestCase {

    private let userQuery = "query GetUser($id: ID!) { user(id: $id) { id name } }"

    private func makeClient(
        suspensionTimeout: TimeInterval = 0
    ) -> (CachebayClient, MockHTTPTransport) {
        let http = MockHTTPTransport()
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: http),
                cachePolicy: .cacheFirst,
                suspensionTimeout: suspensionTimeout
            ))
        return (client, http)
    }

    private func userPayload(_ id: String, name: String) -> JSONValue {
        return .object([
            "user": .object([
                "__typename": "User",
                "id": .string(id),
                "name": .string(name),
            ])
        ])
    }

    // MARK: - executeQuery cache policies (single watcher fanout)

    /// Mirrors web `network-only: should materialize 1 time (skip cache check,
    /// read-back after normalize)`. Pins the watcher receives exactly one
    /// emission for one network result.
    func test_networkOnly_singleWatcher_emitsExactlyOnce() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("user", respondWith: userPayload("1", name: "Alice"))

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: false,
                onData: { emissions.append($0) }
            )
        )

        _ = try await client.executeQuery(
            query: userQuery,
            variables: ["id": "1"],
            cachePolicy: .networkOnly
        )
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(emissions.value.count, 1, "exactly 1 emission for one network result")
        XCTAssertEqual(emissions.value[0]["user"]?["name"]?.string, "Alice")
        handle.unsubscribe()
    }

    /// Mirrors web `cache-first with cache hit: should materialize 1 time
    /// (cache only)`. Pre-warm cache; cache-first must NOT hit the network
    /// and must deliver one cached emission to the watcher.
    func test_cacheFirst_cacheHit_skipsNetwork_andEmitsOnce() async throws {
        let (client, http) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Cached Alice"))
        http.whenQueryContains("user", respondWith: userPayload("1", name: "Network Alice"))

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: false,
                onData: { emissions.append($0) }
            )
        )

        _ = try await client.executeQuery(
            query: userQuery,
            variables: ["id": "1"],
            cachePolicy: .cacheFirst
        )
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(http.calls.count, 0, "cache-first with hit must NOT hit network")
        XCTAssertEqual(emissions.value.count, 1, "watcher fires once on the cache hit")
        XCTAssertEqual(emissions.value[0]["user"]?["name"]?.string, "Cached Alice")
        handle.unsubscribe()
    }

    /// Mirrors web `cache-first with cache miss: should materialize 2 times`.
    /// Without a prior write, cache-first hits the network. The watcher
    /// receives 1 emission from the network result (no stale cache to
    /// double-emit).
    func test_cacheFirst_cacheMiss_hitsNetwork_andEmitsOnce() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("user", respondWith: userPayload("1", name: "Alice"))

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: false,
                onData: { emissions.append($0) }
            )
        )

        _ = try await client.executeQuery(
            query: userQuery,
            variables: ["id": "1"],
            cachePolicy: .cacheFirst
        )
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(http.calls.count, 1)
        XCTAssertEqual(emissions.value.count, 1)
        XCTAssertEqual(emissions.value[0]["user"]?["name"]?.string, "Alice")
        handle.unsubscribe()
    }

    /// Mirrors web `cache-and-network: should materialize 2 times (cache +
    /// network)`. With a warm cache, the watcher should fire twice: once
    /// for the cached result, once for the network result.
    func test_cacheAndNetwork_warmCache_emitsTwice_cacheThenNetwork() async throws {
        let (client, http) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Cached Alice"))
        http.whenQueryContains("user", respondWith: userPayload("1", name: "Network Alice"))

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: false,
                onData: { emissions.append($0) }
            )
        )

        _ = try await client.executeQuery(
            query: userQuery,
            variables: ["id": "1"],
            cachePolicy: .cacheAndNetwork
        )
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(emissions.value.count, 2, "cache hit + network result ⇒ 2 emissions")
        XCTAssertEqual(emissions.value[0]["user"]?["name"]?.string, "Cached Alice")
        XCTAssertEqual(emissions.value[1]["user"]?["name"]?.string, "Network Alice")
        handle.unsubscribe()
    }

    /// Mirrors web `cache-only: should materialize 1, normalize 0 (no network)`.
    /// Watcher receives one cached emission; no network hit.
    func test_cacheOnly_warmCache_emitsOnce_noNetwork() async throws {
        let (client, http) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Cached Alice"))
        http.whenQueryContains("user", respondWith: userPayload("1", name: "Network Alice"))

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: false,
                onData: { emissions.append($0) }
            )
        )

        _ = try await client.executeQuery(
            query: userQuery,
            variables: ["id": "1"],
            cachePolicy: .cacheOnly
        )
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(http.calls.count, 0)
        XCTAssertEqual(emissions.value.count, 1)
        XCTAssertEqual(emissions.value[0]["user"]?["name"]?.string, "Cached Alice")
        handle.unsubscribe()
    }

    // MARK: - bulk operations

    /// Mirrors web `10 sequential queries (network-only): should normalize 10,
    /// materialize 10`. 10 distinct watchers, each receives exactly one
    /// emission for its own response.
    func test_tenSequentialNetworkOnlyQueries_eachWatcherFiresOnce() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("user") { vars in
            let id = vars["id"]?.string ?? "0"
            return OperationResult(
                data: .object([
                    "user": .object([
                        "__typename": "User",
                        "id": .string(id),
                        "name": .string("User \(id)"),
                    ])
                ]))
        }

        struct W { let box: CaptureBox<[JSONValue]>; let handle: WatchQueryHandle }
        var watchers: [W] = []
        for i in 1...10 {
            let box = CaptureBox<[JSONValue]>(value: [])
            let cb = box
            let h = try client.watchQuery(
                query: userQuery,
                options: WatchQueryOptions(
                    variables: ["id": .string(String(i))], immediate: false,
                    onData: { cb.append($0) }
                )
            )
            watchers.append(W(box: box, handle: h))
        }

        for i in 1...10 {
            _ = try await client.executeQuery(
                query: userQuery,
                variables: ["id": .string(String(i))],
                cachePolicy: .networkOnly
            )
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        for (i, w) in watchers.enumerated() {
            XCTAssertEqual(w.box.value.count, 1, "watcher #\(i + 1) fires exactly once for its own id")
            XCTAssertEqual(w.box.value[0]["user"]?["id"]?.string, String(i + 1))
        }

        XCTAssertEqual(http.calls.count, 10, "10 distinct network calls")
        for w in watchers { w.handle.unsubscribe() }
    }

    /// Mirrors web `pagination: 5 pages should normalize 5, materialize 5`.
    /// One paginated watcher across 5 pages must emit once per page (not
    /// twice, not zero).
    func test_pagination_fivePages_singleWatcher_emitsFiveTimes() async throws {
        let (client, http) = makeClient()
        let pagedQuery = """
            query GetPosts($after: String) {
                posts(after: $after) @connection(key: "posts") {
                    edges { cursor node { id __typename } }
                    pageInfo { endCursor hasNextPage }
                }
            }
            """
        http.whenQueryContains("posts") { vars in
            let after = vars["after"]?.string ?? "init"
            return OperationResult(
                data: .object([
                    "posts": .object([
                        "__typename": "PostConnection",
                        "edges": .array([
                            .object([
                                "__typename": "PostEdge",
                                "cursor": .string("c-\(after)"),
                                "node": .object(["__typename": "Post", "id": .string("p-\(after)")]),
                            ])
                        ]),
                        "pageInfo": .object([
                            "__typename": "PageInfo",
                            "endCursor": .string("c-\(after)"),
                            "hasNextPage": true,
                        ]),
                    ])
                ]))
        }

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: pagedQuery,
            options: WatchQueryOptions(
                variables: ["after": .null], immediate: false,
                onData: { emissions.append($0) }
            )
        )

        // 5 pages.
        for i in 0..<5 {
            let after: JSONValue = i == 0 ? .null : .string("cursor\(i)")
            _ = try await client.executeQuery(
                query: pagedQuery,
                variables: ["after": after],
                cachePolicy: .networkOnly
            )
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(http.calls.count, 5)
        XCTAssertEqual(emissions.value.count, 5, "watcher fires once per page (5 pages, 5 emissions)")
        handle.unsubscribe()
    }

    // MARK: - executeMutation

    /// Mirrors web `executeMutation: should normalize 1, materialize 1`.
    /// Single mutation produces exactly one fanout emission to a matching
    /// watcher (none in this test → just verify mutation completes once).
    func test_executeMutation_singleNormalize_singleResult() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains(
            "createUser",
            respondWith: .object([
                "createUser": .object([
                    "__typename": "User", "id": "2", "name": "Bob",
                ])
            ]))

        let mutation = """
            mutation CreateUser($name: String!) { createUser(name: $name) { id name } }
            """
        let result = try await client.executeMutation(
            query: mutation,
            variables: ["name": "Bob"]
        )
        XCTAssertEqual(result.data?["createUser"]?["name"]?.string, "Bob")
        XCTAssertEqual(http.calls.count, 1, "exactly one network call for the mutation")
    }

    // MARK: - Invalidation: WITH watcher prevents, WITHOUT watcher triggers

    /// Mirrors web `network-only / WITH watcher: invalidate NOT called`.
    /// With a live watcher, executeQuery does not invalidate the cache — the
    /// next preferCache materialize should be HOT.
    func test_networkOnly_withWatcher_doesNotInvalidateCache() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("user", respondWith: userPayload("1", name: "Alice"))

        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: false,
                onData: { _ in }
            )
        )

        _ = try await client.executeQuery(
            query: userQuery,
            variables: ["id": "1"],
            cachePolicy: .networkOnly
        )

        // Direct documents materialize: with watcher present the cache entry
        // must remain populated (HOT on a follow-up read).
        let plan = try Compiler.compilePlan(source: userQuery)
        let r = client.documents.materialize(plan: plan, variables: ["id": "1"], options: MaterializeOptions(preferCache: true))
        XCTAssertTrue(r.hot, "watcher present ⇒ no invalidation ⇒ HOT")
        handle.unsubscribe()
    }

    /// Mirrors web `network-only / WITHOUT watcher: invalidate called`.
    /// Without a watcher, executeQuery should invalidate the materialize
    /// cache so a follow-up read is COLD (re-materialized from graph).
    func test_networkOnly_withoutWatcher_invalidatesCache() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("user", respondWith: userPayload("1", name: "Alice"))

        _ = try await client.executeQuery(
            query: userQuery,
            variables: ["id": "1"],
            cachePolicy: .networkOnly
        )

        let plan = try Compiler.compilePlan(source: userQuery)
        let r = client.documents.materialize(plan: plan, variables: ["id": "1"], options: MaterializeOptions(preferCache: true))
        XCTAssertFalse(r.hot, "no watcher ⇒ invalidation ⇒ COLD on next read")
    }

    /// Mirrors web `cache-first / WITH watcher: invalidate NOT called`.
    func test_cacheFirst_withWatcher_doesNotInvalidateCache() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("user", respondWith: userPayload("1", name: "Alice"))

        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: false,
                onData: { _ in }
            )
        )
        _ = try await client.executeQuery(
            query: userQuery,
            variables: ["id": "1"],
            cachePolicy: .networkOnly
        )

        // cache-first now hits the cache — must remain populated.
        _ = try await client.executeQuery(
            query: userQuery,
            variables: ["id": "1"],
            cachePolicy: .cacheFirst
        )
        let plan = try Compiler.compilePlan(source: userQuery)
        let r = client.documents.materialize(plan: plan, variables: ["id": "1"], options: MaterializeOptions(preferCache: true))
        XCTAssertTrue(r.hot)
        handle.unsubscribe()
    }

    /// Mirrors web `cache-only / WITHOUT watcher: invalidate called`.
    /// Pre-populate cache, then run cache-only without a watcher: the
    /// materialize cache entry should be invalidated after delivery so
    /// later reads re-materialize.
    func test_cacheOnly_withoutWatcher_invalidatesCache() async throws {
        let (client, _) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Cached"))

        _ = try await client.executeQuery(
            query: userQuery,
            variables: ["id": "1"],
            cachePolicy: .cacheOnly
        )

        let plan = try Compiler.compilePlan(source: userQuery)
        let r = client.documents.materialize(plan: plan, variables: ["id": "1"], options: MaterializeOptions(preferCache: true))
        XCTAssertFalse(r.hot, "cache-only without watcher ⇒ invalidation ⇒ COLD")
    }

    /// Mirrors web `cache-first / WITHOUT watcher: invalidate called`
    /// (`operations-performance.test.ts:509`). Pre-populate cache, run
    /// cache-first without any watcher: the materialize cache entry
    /// must be invalidated after delivery so subsequent reads
    /// re-materialize from the graph.
    func test_cacheFirst_withoutWatcher_invalidatesCache() async throws {
        let (client, http) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Cached"))
        http.whenQueryContains("user", respondWith: userPayload("1", name: "Network"))

        _ = try await client.executeQuery(
            query: userQuery,
            variables: ["id": "1"],
            cachePolicy: .cacheFirst
        )

        let plan = try Compiler.compilePlan(source: userQuery)
        let r = client.documents.materialize(plan: plan, variables: ["id": "1"], options: MaterializeOptions(preferCache: true))
        XCTAssertFalse(r.hot, "cache-first without watcher ⇒ invalidation ⇒ COLD")
    }

    /// Mirrors web `cache-only / WITH watcher: invalidate NOT called`
    /// (`operations-performance.test.ts:551`). With an active watcher,
    /// the materialize cache entry must remain HOT so subsequent
    /// dep-driven reads short-circuit on the cached fingerprint.
    func test_cacheOnly_withWatcher_doesNotInvalidateCache() async throws {
        let (client, _) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Cached"))

        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: false,
                onData: { _ in }
            )
        )
        _ = try await client.executeQuery(
            query: userQuery,
            variables: ["id": "1"],
            cachePolicy: .cacheOnly
        )

        let plan = try Compiler.compilePlan(source: userQuery)
        let r = client.documents.materialize(plan: plan, variables: ["id": "1"], options: MaterializeOptions(preferCache: true))
        XCTAssertTrue(r.hot, "cache-only with watcher ⇒ no invalidate ⇒ HOT")
        handle.unsubscribe()
    }

    /// Mirrors web `cache-and-network / WITH watcher: invalidate NOT called`
    /// (`operations-performance.test.ts:626`). Same invariant: an
    /// active watcher prevents materialize-cache invalidation even
    /// for the dual-fetch policy.
    func test_cacheAndNetwork_withWatcher_doesNotInvalidateCache() async throws {
        let (client, http) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Cached"))
        http.whenQueryContains("user", respondWith: userPayload("1", name: "Network"))

        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: false,
                onData: { _ in }
            )
        )
        _ = try await client.executeQuery(
            query: userQuery,
            variables: ["id": "1"],
            cachePolicy: .cacheAndNetwork
        )

        let plan = try Compiler.compilePlan(source: userQuery)
        let r = client.documents.materialize(plan: plan, variables: ["id": "1"], options: MaterializeOptions(preferCache: true))
        XCTAssertTrue(r.hot, "cache-and-network with watcher ⇒ no invalidate ⇒ HOT")
        handle.unsubscribe()
    }

    /// Mirrors web `cache-and-network / WITHOUT watcher: invalidate called`.
    func test_cacheAndNetwork_withoutWatcher_invalidatesCache() async throws {
        let (client, http) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Cached"))
        http.whenQueryContains("user", respondWith: userPayload("1", name: "Network"))

        _ = try await client.executeQuery(
            query: userQuery,
            variables: ["id": "1"],
            cachePolicy: .cacheAndNetwork
        )

        let plan = try Compiler.compilePlan(source: userQuery)
        let r = client.documents.materialize(plan: plan, variables: ["id": "1"], options: MaterializeOptions(preferCache: true))
        XCTAssertFalse(r.hot, "cache-and-network without watcher ⇒ invalidation ⇒ COLD")
    }
}
