import XCTest
@testable import Cachebay
@testable import CachebayGraphQL

/// Typed connection routing: the v1.0 `watch`/`execute`/`executeSubscription` must
/// use `Op.document` (the precompiled plan that retains `@connection` metadata),
/// NOT a re-parse of the directive-stripped network query. Otherwise the plan loses
/// `isConnection`, normalize skips `Canonical.updateConnection`, and watchers on the
/// canonical (`@connection.posts({…})`) silently miss every optimistic/mutation update.
///
/// This also exercises typed decode of a Relay `@connection` shape end-to-end.
final class TypedAPIDocumentRoutingTests: XCTestCase {

    private static let fullSource = """
        query BugReproPosts {
            posts @connection(mode: "infinite") {
                __typename
                pageInfo { __typename hasNextPage }
                edges { __typename cursor node { __typename id title } }
            }
        }
        """
    private static let strippedNetworkQuery: String = {
        let parsed = try! Parser.parse(fullSource)
        return buildNetworkQuery(from: parsed)
    }()
    private static let precompiledPlan: CachePlan = { try! Compiler.compilePlan(source: fullSource) }()

    // Minimal typed connection Data — declares only what the assertions read; decode
    // ignores the other selected fields. Connection/edge typenames aren't guarded.
    @CachebayData(typename: "")
    private struct PostsData: Sendable, Hashable, CachebayValue {
        let posts: Posts
        @CachebayData(typename: "")
        struct Posts: Sendable, Hashable, CachebayValue {
            let edges: [Edge]
            @CachebayData(typename: "")
            struct Edge: Sendable, Hashable, CachebayValue {
                let node: Node
                @CachebayData(typename: "Post")
                struct Node: Identifiable, Sendable, Hashable, CachebayValue {
                    let __typename: String
                    let id: String
                    let title: String
                }
            }
        }
    }

    private struct BugReproPosts: CachebayOperation {
        typealias Variables = EmptyVariables
        typealias Data = PostsData
        static var document: QueryDocument { .plan(TypedAPIDocumentRoutingTests.precompiledPlan) }
    }

    private static let mutationPlan: CachePlan = {
        try! Compiler.compilePlan(
            source: """
                mutation BugReproRefresh {
                    posts @connection(mode: "infinite") {
                        __typename
                        pageInfo { __typename hasNextPage }
                        edges { __typename cursor node { __typename id title } }
                    }
                }
                """)
    }()
    private struct BugReproRefresh: CachebayOperation {
        typealias Variables = EmptyVariables
        typealias Data = PostsData
        static var document: QueryDocument { .plan(TypedAPIDocumentRoutingTests.mutationPlan) }
    }

    private static let subscriptionPlan: CachePlan = {
        try! Compiler.compilePlan(
            source: """
                subscription BugReproStream {
                    posts @connection(mode: "infinite") {
                        __typename
                        pageInfo { __typename hasNextPage }
                        edges { __typename cursor node { __typename id title } }
                    }
                }
                """)
    }()
    private struct BugReproStream: CachebayOperation {
        typealias Variables = EmptyVariables
        typealias Data = PostsData
        static var document: QueryDocument { .plan(TypedAPIDocumentRoutingTests.subscriptionPlan) }
    }

    private static let connectionResponse: JSONValue = .object([
        "posts": .object([
            "__typename": .string("PostConnection"),
            "pageInfo": .object(["__typename": .string("PageInfo"), "hasNextPage": .bool(false)]),
            "edges": .array([
                .object([
                    "__typename": .string("PostEdge"), "cursor": .string("c1"),
                    "node": .object(["__typename": .string("Post"), "id": .string("p1"), "title": .string("First")]),
                ])
            ]),
        ])
    ])

    // UNIT: a plan from the stripped network query loses `isConnection` (the why).
    func test_unit_planFromStrippedNetworkQuery_losesConnectionMetadata() throws {
        let full = Self.precompiledPlan.root.first { $0.responseKey == "posts" }
        let stripped = try Compiler.compilePlan(source: Self.strippedNetworkQuery).root.first { $0.responseKey == "posts" }
        XCTAssertEqual(full?.isConnection, true, "full source MUST mark posts as a connection")
        XCTAssertEqual(stripped?.isConnection, false, "stripped query LOSES isConnection — typed API must use Op.document")
    }

    // INTEGRATION: typed watch + optimistic linkNode against the canonical re-fires.
    func test_integration_typedWatch_thenOptimisticAddNode_firesWatcher() async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains(
            "BugReproPosts",
            respondWith: .object([
                "posts": .object([
                    "__typename": .string("PostConnection"),
                    "edges": .array([]),
                    "pageInfo": .object(["__typename": .string("PageInfo"), "hasNextPage": .bool(false)]),
                ])
            ]))
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: http), cachePolicy: .cacheAndNetwork, suspensionTimeout: 0
            ))

        let received = CaptureBox<[PostsData]>(value: [])
        _ = try client.watch(BugReproPosts.self, variables: .init(), immediate: true) { data in received.value.append(data) }

        _ = try await client.execute(BugReproPosts.self, variables: .init(), cachePolicy: .cacheAndNetwork)
        let countAfterNetwork = received.value.count
        XCTAssertGreaterThanOrEqual(countAfterNetwork, 1, "watcher must fire on the empty network response")

        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object([CachebayConstants.typenameField: .string("Post"), "id": .string("p1"), "title": .string("Optimistic")])
        )
        client.modifyOptimistic { b in
            b.connection(key: "@connection.posts({})").linkNode(.key("Post:p1"), options: LinkNodeOptions(position: .start))
        }.dispose()

        XCTAssertGreaterThan(
            received.value.count, countAfterNetwork,
            "watcher must re-fire after the optimistic linkNode against the canonical")
        XCTAssertEqual(received.value.last?.posts.edges.count, 1)
        XCTAssertEqual(received.value.last?.posts.edges.first?.node.id, "p1")
    }

    // Mutation response with a @connection field normalizes into the canonical.
    func test_typedExecuteMutation_normalizesConnectionResponseIntoCanonical() async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("BugReproRefresh", respondWith: Self.connectionResponse)
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: http), cachePolicy: .cacheAndNetwork, suspensionTimeout: 0
            ))
        _ = try await client.execute(mutation: BugReproRefresh.self, variables: .init())

        let connectionRecords = client.graph.keysList().filter { $0.hasPrefix("@connection.") && $0.contains(".posts(") }
        XCTAssertFalse(connectionRecords.isEmpty, "typed execute(mutation:) must take the connection path and write a @connection.… record")
        XCTAssertNotNil(client.graph.getRecord("Post:p1"), "mutation response must normalize the entity record")
    }

    // Subscription frame with a @connection field normalizes into the canonical.
    func test_typedExecuteSubscription_normalizesConnectionFrameIntoCanonical() async throws {
        let ws = MockWSTransport(frames: [Self.connectionResponse])
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport(), ws: ws), cachePolicy: .cacheAndNetwork, suspensionTimeout: 0
            ))
        let stream = try client.executeSubscription(BugReproStream.self, variables: .init())
        for try await _ in stream { break }

        let connectionRecords = client.graph.keysList().filter { $0.hasPrefix("@connection.") && $0.contains(".posts(") }
        XCTAssertFalse(connectionRecords.isEmpty, "typed executeSubscription must use Op.document so per-frame normalize writes a @connection.… record")
        XCTAssertNotNil(client.graph.getRecord("Post:p1"), "subscription frame must normalize the entity record")
    }
}
