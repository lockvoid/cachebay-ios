import XCTest
@testable import Cachebay

/// End-to-end integration tests for connection-watcher behaviour with the
/// real Operations + HTTP transport stack. These mirror the scenarios in
/// `cachebay/test/integration/svelte/optimistic-updates.svelte.test.ts`
/// and `relay-connections.svelte.test.ts` from cachebay-web — porting them
/// to the iOS port keeps the two implementations behaviour-equivalent and
/// catches divergences that pure unit tests miss (writeQuery shortcuts the
/// `executeQuery → notifyDataBySignature → updateDependenciesLocked` path
/// where production bugs actually live).
///
/// The motivating bug, observed on `28-apr-cachebay`: after a fresh launch
/// (empty cache) → projects watcher created with `cacheAndNetwork` →
/// network returned empty list → watcher fired with `edgeCount=0` → user
/// optimistically created a project via `linkNode` → watcher silently
/// failed to re-fire and the projects list stayed empty. The unit test
/// for `linkNode → watcher` in `WatcherSilencedByMissingScalarTests`
/// passed because it seeded the cache via `writeQuery` instead of the
/// `executeQuery → notifyDataBySignature` path the real app takes.
final class ConnectionWatcherIntegrationTests: XCTestCase {

    private let postsQuery = """
        query Posts($first: Int) {
            posts(first: $first) @connection(mode: "infinite") {
                pageInfo { endCursor hasNextPage }
                edges {
                    cursor
                    node { id title }
                }
            }
        }
        """

    private func makeClient(http: MockHTTPTransport) -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: http),
                cachePolicy: .cacheAndNetwork,
                suspensionTimeout: 0
            ))
    }

    // Tests are `async throws`. `MockHTTPTransport` returns synchronously,
    // so `executeQuery` never blocks; if a watcher is silenced the
    // subsequent `XCTAssert` fails synchronously rather than hanging.

    private func emptyConnectionResponse() -> JSONValue {
        .object([
            "posts": .object([
                "__typename": .string("PostConnection"),
                "edges": .array([]),
                "pageInfo": .object([
                    "__typename": .string("PageInfo"),
                    "endCursor": .null,
                    "hasNextPage": .bool(false),
                ]),
            ])
        ])
    }

    private func twoPostsResponse() -> JSONValue {
        .object([
            "posts": .object([
                "__typename": .string("PostConnection"),
                "pageInfo": .object([
                    "__typename": .string("PageInfo"),
                    "endCursor": .string("c2"),
                    "hasNextPage": .bool(false),
                ]),
                "edges": .array([
                    .object([
                        "__typename": .string("PostEdge"),
                        "cursor": .string("c1"),
                        "node": .object([
                            "__typename": .string("Post"),
                            "id": .string("p1"),
                            "title": .string("First"),
                        ]),
                    ]),
                    .object([
                        "__typename": .string("PostEdge"),
                        "cursor": .string("c2"),
                        "node": .object([
                            "__typename": .string("Post"),
                            "id": .string("p2"),
                            "title": .string("Second"),
                        ]),
                    ]),
                ]),
            ])
        ])
    }

    // MARK: - The exact ferment-cuts-ios bug

    /// Mirrors `ProjectsView` → `vm.watch()` → `executeQuery
    /// (cacheAndNetwork)` → server returns empty list → `[ProjectsVM]
    /// watcher fired: edgeCount=0` → user creates a project →
    /// `b.connection(key:).linkNode(node:)` → expectation: watcher fires
    /// again with the new node.
    ///
    /// In the buggy state the second fire never happens — the canonical
    /// fanout misses the watcher because the dep tracking for an
    /// optimistic write didn't survive the round-trip through
    /// `notifyDataBySignature → updateDependenciesLocked`. The
    /// `WatcherSilencedByMissingScalarTests` unit case passed even with
    /// the bug present because it seeded the cache through `writeQuery`
    /// (a different code path that doesn't invoke the signature-based
    /// notify).
    func test_addNode_afterEmptyCacheAndNetwork_firesWatcher() async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("posts", respondWith: self.emptyConnectionResponse())

        let client = self.makeClient(http: http)

        let received = CaptureBox<[JSONValue]>(value: [])
        let _ = try client.watchQuery(
            query: self.postsQuery,
            options: WatchQueryOptions(
                variables: ["first": .int(50)],
                immediate: true,
                onData: { received.append($0) }
            )
        )

        // Kick off `cacheAndNetwork` — same shape as
        // `ProjectQueries.watchProjects` does.
        _ = try await client.executeQuery(
            query: self.postsQuery,
            variables: ["first": .int(50)],
            cachePolicy: .cacheAndNetwork
        )

        let countAfterNetwork = received.value.count
        XCTAssertGreaterThanOrEqual(countAfterNetwork, 1, "watcher must fire at least once with the empty network response")

        // Optimistic linkNode by canonical key — same as
        // `b.connection(key: key).linkNode(node: created, options:)` in
        // `ProjectMutations.createProject`.
        let canonicalKey: CacheKey = "@connection.posts({})"
        // Seed entity scalars first — linkNode is purely structural.
        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object([
                CachebayConstants.typenameField: .string("Post"),
                "id": .string("p1"),
                "title": .string("Optimistic"),
            ])
        )
        client.modifyOptimistic { b in
            b.connection(key: canonicalKey).linkNode(
                .key("Post:p1"),
                options: LinkNodeOptions(position: .start)
            )
        }.dispose()

        // The watcher must re-fire with the new node visible. If it
        // doesn't, the projects list stays blank in production.
        XCTAssertGreaterThan(received.value.count, countAfterNetwork, "watcher must re-fire after optimistic linkNode against the canonical")

        guard let last = received.value.last,
            case .object(let root) = last,
            case .object(let posts) = root["posts"] ?? .undefined,
            case .array(let edges) = posts["edges"] ?? .undefined
        else {
            XCTFail("watcher data shape unexpected: \(received.value.last ?? .undefined)")
            return
        }
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges.first?["node"]?["id"]?.string, "p1")
    }

    /// Same but discovers the canonical key via `inspect.getConnectionKeys`
    /// — which is what production code does because the canonical's
    /// arg-set isn't always known statically.
    func test_addNode_viaInspectConnectionKeys_firesWatcher() async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("posts", respondWith: self.emptyConnectionResponse())

        let client = self.makeClient(http: http)

        let received = CaptureBox<[JSONValue]>(value: [])
        let _ = try client.watchQuery(
            query: self.postsQuery,
            options: WatchQueryOptions(
                variables: ["first": .int(50)],
                immediate: true,
                onData: { received.append($0) }
            )
        )

        _ = try await client.executeQuery(
            query: self.postsQuery,
            variables: ["first": .int(50)],
            cachePolicy: .cacheAndNetwork
        )

        let countAfterNetwork = received.value.count
        XCTAssertGreaterThanOrEqual(countAfterNetwork, 1)

        // Discover the canonical at runtime — same as
        // `CachebayService.client.inspect.getConnectionKeys(parent:
        // .root, key: "posts")` in `ProjectMutations.createProject`.
        let keys = client.inspect.getConnectionKeys(parent: .root, key: "posts")
        XCTAssertGreaterThanOrEqual(keys.count, 1, "the network response should have created at least one canonical record")

        // Seed entity scalars first — linkNode is purely structural.
        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object([
                CachebayConstants.typenameField: .string("Post"),
                "id": .string("p1"),
                "title": .string("Optimistic"),
            ])
        )
        client.modifyOptimistic { b in
            for key in keys {
                b.connection(key: key).linkNode(
                    .key("Post:p1"),
                    options: LinkNodeOptions(position: .start)
                )
            }
        }.dispose()

        XCTAssertGreaterThan(received.value.count, countAfterNetwork, "watcher must re-fire after optimistic linkNode (inspect.getConnectionKeys path)")
    }

    // MARK: - Mirror of cachebay-web "first render after remount"
    //
    // Web: `optimistic-updates.svelte.test.ts` →
    // "first render after remount shows cached union; network leader
    // without A4 resets to server slice".

    func test_remountWithOptimisticEdge_thenLeaderRefetchWithoutOptimistic_resetsToServer() async throws {
        // Two leader hits with the same payload (server doesn't know
        // about the optimistic A4).
        let leaderHits = CaptureBox<Int>(value: 0)
        let http = MockHTTPTransport()
        http.whenQueryContains("posts") { _ in
            leaderHits.value += 1
            return OperationResult(
                data: .object([
                    "posts": .object([
                        "__typename": .string("PostConnection"),
                        "pageInfo": .object([
                            "__typename": .string("PageInfo"),
                            "endCursor": .string("c3"),
                            "hasNextPage": .bool(false),
                        ]),
                        "edges": .array([
                            .object(["__typename": .string("PostEdge"), "cursor": .string("c1"), "node": .object(["__typename": .string("Post"), "id": .string("a1"), "title": .string("A1")])]),
                            .object(["__typename": .string("PostEdge"), "cursor": .string("c2"), "node": .object(["__typename": .string("Post"), "id": .string("a2"), "title": .string("A2")])]),
                            .object(["__typename": .string("PostEdge"), "cursor": .string("c3"), "node": .object(["__typename": .string("Post"), "id": .string("a3"), "title": .string("A3")])]),
                        ]),
                    ])
                ]))
        }

        let client = self.makeClient(http: http)

        // First mount → leader #1 lands.
        let received1 = CaptureBox<[JSONValue]>(value: [])
        let h1 = try client.watchQuery(
            query: self.postsQuery,
            options: WatchQueryOptions(
                variables: ["first": .int(3)],
                immediate: true,
                onData: { received1.append($0) }
            )
        )
        _ = try await client.executeQuery(
            query: self.postsQuery,
            variables: ["first": .int(3)],
            cachePolicy: .cacheAndNetwork
        )

        XCTAssertGreaterThanOrEqual(received1.value.count, 1)

        // Optimistically prepend A4. Seed entity scalars first — linkNode
        // is purely structural in v0.7.0.
        try client.writeFragment(
            id: "Post:a4",
            fragment: "fragment P on Post { id title }",
            data: .object([
                CachebayConstants.typenameField: .string("Post"),
                "id": .string("a4"),
                "title": .string("A4"),
            ])
        )
        client.modifyOptimistic { b in
            b.connection(key: "@connection.posts({})").linkNode(
                .key("Post:a4"),
                options: LinkNodeOptions(position: .start)
            )
        }.dispose()

        guard let last1 = received1.value.last,
            case .object(let root1) = last1,
            case .object(let posts1) = root1["posts"] ?? .undefined,
            case .array(let edges1) = posts1["edges"] ?? .undefined
        else {
            XCTFail("first watcher data shape unexpected")
            return
        }
        XCTAssertEqual(edges1.count, 4, "after optimistic A4, watcher must show 4 edges")
        XCTAssertEqual(edges1.first?["node"]?["id"]?.string, "a4")

        h1.unsubscribe()

        // Remount: a fresh watcher should still see A4 (it's in the
        // canonical) — and then the leader refetch (without A4) must
        // reset the canonical to the server slice and re-fire the
        // watcher with [a1, a2, a3].
        let received2 = CaptureBox<[JSONValue]>(value: [])
        let h2 = try client.watchQuery(
            query: self.postsQuery,
            options: WatchQueryOptions(
                variables: ["first": .int(3)],
                immediate: true,
                onData: { received2.append($0) }
            )
        )

        _ = try await client.executeQuery(
            query: self.postsQuery,
            variables: ["first": .int(3)],
            cachePolicy: .cacheAndNetwork
        )

        // Last fire must reflect the server slice without A4.
        guard let last2 = received2.value.last,
            case .object(let root2) = last2,
            case .object(let posts2) = root2["posts"] ?? .undefined,
            case .array(let edges2) = posts2["edges"] ?? .undefined
        else {
            XCTFail("second watcher data shape unexpected")
            return
        }
        let ids = edges2.compactMap { $0["node"]?["id"]?.string }
        XCTAssertEqual(ids, ["a1", "a2", "a3"], "leader refetch without A4 must reset canonical to server slice; A4 (optimistic, not in server response) must be discarded")

        h2.unsubscribe()
    }

    /// Companion: leader refetch INCLUDING the previously-optimistic id
    /// keeps it in the list. This guards against a regression where
    /// dedup against existing edges incorrectly drops incoming.
    func test_remount_then_leaderRefetchIncludingOptimisticId_keepsIt() async throws {
        let leaderHits = CaptureBox<Int>(value: 0)
        let http = MockHTTPTransport()
        http.whenQueryContains("posts") { _ in
            let hit = leaderHits.value
            leaderHits.value += 1
            if hit == 0 {
                return OperationResult(
                    data: .object([
                        "posts": .object([
                            "__typename": .string("PostConnection"),
                            "pageInfo": .object(["__typename": .string("PageInfo"), "endCursor": .string("c3"), "hasNextPage": .bool(false)]),
                            "edges": .array([
                                .object(["__typename": .string("PostEdge"), "cursor": .string("c1"), "node": .object(["__typename": .string("Post"), "id": .string("a1"), "title": .string("A1")])]),
                                .object(["__typename": .string("PostEdge"), "cursor": .string("c2"), "node": .object(["__typename": .string("Post"), "id": .string("a2"), "title": .string("A2")])]),
                                .object(["__typename": .string("PostEdge"), "cursor": .string("c3"), "node": .object(["__typename": .string("Post"), "id": .string("a3"), "title": .string("A3")])]),
                            ]),
                        ])
                    ]))
            }
            // Second refetch: server now returns A4 at the head and drops A3.
            return OperationResult(
                data: .object([
                    "posts": .object([
                        "__typename": .string("PostConnection"),
                        "pageInfo": .object(["__typename": .string("PageInfo"), "endCursor": .string("c2"), "hasNextPage": .bool(false)]),
                        "edges": .array([
                            .object(["__typename": .string("PostEdge"), "cursor": .string("c4"), "node": .object(["__typename": .string("Post"), "id": .string("a4"), "title": .string("A4-from-server")])]),
                            .object(["__typename": .string("PostEdge"), "cursor": .string("c1"), "node": .object(["__typename": .string("Post"), "id": .string("a1"), "title": .string("A1")])]),
                            .object(["__typename": .string("PostEdge"), "cursor": .string("c2"), "node": .object(["__typename": .string("Post"), "id": .string("a2"), "title": .string("A2")])]),
                        ]),
                    ])
                ]))
        }

        let client = self.makeClient(http: http)

        let received = CaptureBox<[JSONValue]>(value: [])
        let h = try client.watchQuery(
            query: self.postsQuery,
            options: WatchQueryOptions(
                variables: ["first": .int(3)],
                immediate: true,
                onData: { received.append($0) }
            )
        )
        _ = try await client.executeQuery(
            query: self.postsQuery,
            variables: ["first": .int(3)],
            cachePolicy: .cacheAndNetwork
        )

        // Seed entity scalars first — linkNode is purely structural in v0.7.0.
        try client.writeFragment(
            id: "Post:a4",
            fragment: "fragment P on Post { id title }",
            data: .object([
                CachebayConstants.typenameField: .string("Post"),
                "id": .string("a4"),
                "title": .string("A4-optimistic"),
            ])
        )
        client.modifyOptimistic { b in
            b.connection(key: "@connection.posts({})").linkNode(
                .key("Post:a4"),
                options: LinkNodeOptions(position: .start)
            )
        }.dispose()

        // Second leader refetch overwrites — the server's title for A4
        // must win (entity record merge), not be silently dropped.
        _ = try await client.executeQuery(
            query: self.postsQuery,
            variables: ["first": .int(3)],
            cachePolicy: .cacheAndNetwork
        )

        guard let last = received.value.last,
            case .object(let root) = last,
            case .object(let posts) = root["posts"] ?? .undefined,
            case .array(let edges) = posts["edges"] ?? .undefined
        else {
            XCTFail("watcher data shape unexpected")
            return
        }

        let ids = edges.compactMap { $0["node"]?["id"]?.string }
        XCTAssertEqual(ids, ["a4", "a1", "a2"], "second leader refetch must replace canonical with server slice")
        // Server's payload for A4 should win on the entity record.
        XCTAssertEqual(edges.first?["node"]?["title"]?.string, "A4-from-server")

        h.unsubscribe()
    }

    // MARK: - Mirror of ferment-cuts-ios ProjectsQuery (literal arg)

    private let postsQueryWithLiteralOrderBy = """
        query Posts($first: Int, $after: String) {
            posts(first: $first, after: $after, orderBy: "updatedAt") @connection(mode: "infinite") {
                pageInfo { endCursor hasNextPage }
                edges {
                    cursor
                    node { id title }
                }
            }
        }
        """

    /// Reproduce ferment-cuts-ios's `Projects` query exactly: a literal
    /// `orderBy: "updatedAt"` arg inside the connection field. The
    /// canonical key becomes `@connection.posts({"orderBy":"updatedAt"})`
    /// instead of `@connection.posts({})`. If the canonical-key
    /// construction in `inspect.getConnectionKeys` (used by
    /// `ProjectMutations.createProject`) doesn't agree with the watcher's
    /// canonical-key from `Documents.readConnection`, the dep fanout
    /// silently misses and the watcher never re-fires after `linkNode`.
    func test_addNode_withLiteralOrderByArg_firesWatcher() async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains(
            "posts",
            respondWith: .object([
                "posts": .object([
                    "__typename": .string("PostConnection"),
                    "edges": .array([]),
                    "pageInfo": .object([
                        "__typename": .string("PageInfo"),
                        "endCursor": .null,
                        "hasNextPage": .bool(false),
                    ]),
                ])
            ]))

        let client = self.makeClient(http: http)

        let received = CaptureBox<[JSONValue]>(value: [])
        _ = try client.watchQuery(
            query: self.postsQueryWithLiteralOrderBy,
            options: WatchQueryOptions(
                variables: ["first": .int(50), "after": .null],
                immediate: true,
                onData: { received.append($0) }
            )
        )

        _ = try await client.executeQuery(
            query: self.postsQueryWithLiteralOrderBy,
            variables: ["first": .int(50), "after": .null],
            cachePolicy: .cacheAndNetwork
        )

        let countAfterNetwork = received.value.count
        XCTAssertGreaterThanOrEqual(countAfterNetwork, 1, "watcher must fire on empty network response")

        // Discover canonical via inspect — the production path. Should
        // return `@connection.posts({"orderBy":"updatedAt"})`.
        let keys = client.inspect.getConnectionKeys(parent: .root, key: "posts")
        XCTAssertEqual(keys.count, 1, "exactly one canonical for the literal orderBy")
        XCTAssertEqual(keys.first, "@connection.posts({\"orderBy\":\"updatedAt\"})")

        // Seed entity scalars first — linkNode is purely structural.
        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object([
                CachebayConstants.typenameField: .string("Post"),
                "id": .string("p1"),
                "title": .string("Optimistic"),
            ])
        )
        client.modifyOptimistic { b in
            for key in keys {
                b.connection(key: key).linkNode(
                    .key("Post:p1"),
                    options: LinkNodeOptions(position: .start)
                )
            }
        }.dispose()

        XCTAssertGreaterThan(received.value.count, countAfterNetwork, "watcher must re-fire after linkNode against canonical with literal orderBy arg")

        guard let last = received.value.last,
            case .object(let root) = last,
            case .object(let posts) = root["posts"] ?? .undefined,
            case .array(let edges) = posts["edges"] ?? .undefined
        else {
            XCTFail("watcher data shape unexpected")
            return
        }
        XCTAssertEqual(edges.count, 1, "the optimistic node must land in the canonical and the watcher must see it")
        XCTAssertEqual(edges.first?["node"]?["id"]?.string, "p1")
    }
}
