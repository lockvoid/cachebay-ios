import XCTest
@testable import Cachebay
@testable import CachebayGraphQL

/// Replicates a production bug observed in `ferment-cuts-ios` on
/// 2026-04-27 that the existing typed-API and integration tests both
/// missed.
///
/// **Bug shape.** Real codegen output (e.g. `Projects.cachebay.swift`)
/// has two members:
///
/// * `static let networkQuery: String` — the GraphQL string the runtime
///   sends to the server. `cachebay-cli` runs `buildNetworkQuery` over
///   the document, which **strips** the `@connection` directive (the
///   server doesn't know that vendor extension).
/// * `static let document: QueryDocument` — `.plan(<precompiled plan>)`.
///   The precompiled plan carries the `@connection` metadata
///   (`isConnection: true`, `connectionFilters`, `connectionMode`) so
///   the runtime can take the connection-aware materialize path
///   (canonical key `@connection.posts({…})`, dedup against the
///   canonical, …).
///
/// The typed `watchQuery<Op>` and `executeQuery<Op>` overloads were
/// previously routing through the **string** overload by passing
/// `Op.networkQuery` — which made the planner re-parse the
/// directive-stripped string and produce a plan where
/// `isConnection = false` for every connection field. With that
/// mis-built plan, `readConnection` never runs, the materialize main
/// loop falls into the non-connection branch, and the watcher's deps
/// land on the strict per-page record (`@.posts({…})`) instead of the
/// canonical (`@connection.posts({…})`). `addNode` writes the
/// canonical, so a strict-keyed watcher silently misses every
/// optimistic update — the user creates a project, the projects list
/// stays blank.
///
/// The previous `TypedAPITests`/`ConnectionWatcherIntegrationTests`
/// missed it because their `Operation` fixtures set:
///
/// ```swift
/// static let networkQuery = "query { posts @connection(mode: …) { … } }"
/// static let document: QueryDocument = .source(networkQuery)
/// ```
///
/// — i.e. their `networkQuery` retained the `@connection` directive, so
/// the round-trip through the string overload still produced a
/// connection-aware plan. Real codegen strips the directive, so the
/// production code path is the one this fixture replicates.
final class TypedAPIDocumentRoutingTests: XCTestCase {

    // MARK: - Codegen-shaped Operation fixture

    /// The full GraphQL document the codegen sees before stripping.
    private static let fullSource = """
    query BugReproPosts {
        posts @connection(mode: "infinite") {
            __typename
            pageInfo { __typename hasNextPage }
            edges {
                __typename
                cursor
                node { __typename id title }
            }
        }
    }
    """

    /// The directive-stripped string the codegen actually emits as
    /// `networkQuery`. Built by `buildNetworkQuery` over the full
    /// document — same path real `cachebay-cli` takes.
    private static let strippedNetworkQuery: String = {
        let parsed = try! Parser.parse(TypedAPIDocumentRoutingTests.fullSource)
        return buildNetworkQuery(from: parsed)
    }()

    /// Plan compiled from the **full** source — so `isConnection` is
    /// preserved on the connection field. This is what real codegen
    /// pre-computes and stuffs into `Op.document = .plan(...)`.
    private static let precompiledPlan: CachePlan = {
        try! Compiler.compilePlan(source: TypedAPIDocumentRoutingTests.fullSource)
    }()

    struct BugReproPosts: Cachebay.Operation {
        typealias Variables = Cachebay.EmptyVariables

        /// MIRRORS REAL CODEGEN: directive-stripped string for the network.
        static var networkQuery: String { TypedAPIDocumentRoutingTests.strippedNetworkQuery }

        /// MIRRORS REAL CODEGEN: precompiled plan with `@connection` metadata intact.
        static var document: QueryDocument { .plan(TypedAPIDocumentRoutingTests.precompiledPlan) }

        struct Data: Sendable, Cachebay.OperationData {
            var __data: [String: JSONValue]
            init(__data: [String: JSONValue]) { self.__data = __data }
        }
    }

    // MARK: - Codegen-shaped Mutation / Subscription fixtures

    /// Mutation whose response carries a `@connection` field. Real
    /// codegen for such a mutation strips the directive from
    /// `networkQuery`; if the typed `executeMutation<Op>` re-parses
    /// `networkQuery`, normalize sees a non-connection plan and never
    /// runs `Canonical.updateConnection` — the canonical record is
    /// never written, watchers on it never fanout.
    private static let mutationFullSource = """
    mutation BugReproRefresh {
        posts @connection(mode: "infinite") {
            __typename
            pageInfo { __typename hasNextPage }
            edges {
                __typename
                cursor
                node { __typename id title }
            }
        }
    }
    """
    private static let mutationStrippedNetworkQuery: String = {
        let parsed = try! Parser.parse(TypedAPIDocumentRoutingTests.mutationFullSource)
        return buildNetworkQuery(from: parsed)
    }()
    private static let mutationPrecompiledPlan: CachePlan = {
        try! Compiler.compilePlan(source: TypedAPIDocumentRoutingTests.mutationFullSource)
    }()

    struct BugReproRefresh: Cachebay.Operation {
        typealias Variables = Cachebay.EmptyVariables
        static var networkQuery: String { TypedAPIDocumentRoutingTests.mutationStrippedNetworkQuery }
        static var document: QueryDocument { .plan(TypedAPIDocumentRoutingTests.mutationPrecompiledPlan) }
        struct Data: Sendable, Cachebay.OperationData {
            var __data: [String: JSONValue]
            init(__data: [String: JSONValue]) { self.__data = __data }
        }
    }

    /// Subscription that yields a `@connection`-decorated payload. Same
    /// reasoning: real codegen strips the directive from
    /// `networkQuery`, the typed `executeSubscription<Op>` previously
    /// re-parsed it, and the canonical was never written.
    private static let subscriptionFullSource = """
    subscription BugReproStream {
        posts @connection(mode: "infinite") {
            __typename
            pageInfo { __typename hasNextPage }
            edges {
                __typename
                cursor
                node { __typename id title }
            }
        }
    }
    """
    private static let subscriptionStrippedNetworkQuery: String = {
        let parsed = try! Parser.parse(TypedAPIDocumentRoutingTests.subscriptionFullSource)
        return buildNetworkQuery(from: parsed)
    }()
    private static let subscriptionPrecompiledPlan: CachePlan = {
        try! Compiler.compilePlan(source: TypedAPIDocumentRoutingTests.subscriptionFullSource)
    }()

    struct BugReproStream: Cachebay.Operation {
        typealias Variables = Cachebay.EmptyVariables
        static var networkQuery: String { TypedAPIDocumentRoutingTests.subscriptionStrippedNetworkQuery }
        static var document: QueryDocument { .plan(TypedAPIDocumentRoutingTests.subscriptionPrecompiledPlan) }
        struct Data: Sendable, Cachebay.OperationData {
            var __data: [String: JSONValue]
            init(__data: [String: JSONValue]) { self.__data = __data }
        }
    }

    private static let connectionResponse: JSONValue = .object([
        "posts": .object([
            "__typename": .string("PostConnection"),
            "pageInfo": .object([
                "__typename": .string("PageInfo"),
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
            ]),
        ])
    ])

    // MARK: - UNIT: planner divergence (the why)

    /// **Failing unit test.** Documents the planner's behaviour: a plan
    /// compiled from `Op.networkQuery` (the stripped string) does NOT
    /// carry `isConnection` for the connection field, while a plan
    /// compiled from the full source does. The typed API previously
    /// routed through the stripped string and inherited this regression.
    func test_unit_planFromStrippedNetworkQuery_losesConnectionMetadata() throws {
        let planFromFullSource = Self.precompiledPlan
        let planFromStripped = try Compiler.compilePlan(source: Self.strippedNetworkQuery)

        let postsFromFull = planFromFullSource.root.first { $0.responseKey == "posts" }
        let postsFromStripped = planFromStripped.root.first { $0.responseKey == "posts" }

        XCTAssertNotNil(postsFromFull, "compiler should preserve the `posts` field")
        XCTAssertNotNil(postsFromStripped, "compiler should preserve the `posts` field even on stripped source")

        XCTAssertEqual(postsFromFull?.isConnection, true, "plan compiled from the full source MUST mark `posts` as a connection")
        XCTAssertEqual(postsFromStripped?.isConnection, false, "plan compiled from the directive-stripped `networkQuery` LOSES `isConnection` — this is exactly why the typed runtime must NOT round-trip through `Op.networkQuery`; it must use `Op.document` (the precompiled plan).")
    }

    // MARK: - INTEGRATION: the actual user-facing failure

    /// **Failing integration test.** End-to-end reproduction of the bug:
    /// a typed `watchQuery<Op>` + optimistic `addNode` flow against a
    /// codegen-shaped fixture. With the typed API routing through
    /// `Op.networkQuery`, the watcher's deps land on the strict
    /// per-page record and the optimistic `addNode` against the
    /// canonical fans out to nothing — watcher never re-fires.
    func test_integration_typedWatchQuery_thenOptimisticAddNode_firesWatcher() async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("BugReproPosts", respondWith: .object([
            "posts": .object([
                "__typename": .string("PostConnection"),
                "edges": .array([]),
                "pageInfo": .object([
                    "__typename": .string("PageInfo"),
                    "hasNextPage": .bool(false),
                ]),
            ])
        ]))

        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: http),
            cachePolicy: .cacheAndNetwork,
            suspensionTimeout: 0
        ))

        // Mirror the production flow: typed `watchQuery<Op>` (the
        // overload that lives in `CachebayClient+Typed.swift` and
        // routes — buggy — through `Op.networkQuery`).
        let received = CaptureBox<[JSONValue]>(value: [])
        _ = try client.watchQuery(
            query: BugReproPosts.self,
            variables: .init(),
            immediate: true,
            onData: { data in received.append(.object(data.__data)) }
        )

        // Hydrate the canonical with the empty network response — same
        // shape as `ProjectQueries.watchProjects` kicking off
        // `executeQuery(.cacheAndNetwork)` in production.
        _ = try await client.executeQuery(
            query: BugReproPosts.self,
            variables: .init(),
            cachePolicy: .cacheAndNetwork
        )

        let countAfterNetwork = received.value.count
        XCTAssertGreaterThanOrEqual(countAfterNetwork, 1, "watcher must fire on the empty network response")

        // Optimistic addNode against the canonical — the production
        // path used by `ProjectMutations.createProject`. The canonical
        // key for `posts` (no filters) is `@connection.posts({})`.
        let canonicalKey: CacheKey = "@connection.posts({})"
        client.modifyOptimistic { b, _ in
            b.connection(key: canonicalKey).addNode(
                [
                    "__typename": .string("Post"),
                    "id": .string("p1"),
                    "title": .string("Optimistic"),
                ],
                options: AddNodeOptions(position: .start)
            )
        }.commit(nil)

        XCTAssertGreaterThan(
            received.value.count, countAfterNetwork,
            "watcher must re-fire after the optimistic `addNode` against the canonical. If the typed `watchQuery<Op>` routes through `Op.networkQuery` (directive-stripped), the watcher's deps land on `@.posts({})` (strict) instead of `@connection.posts({})` (canonical). `addNode` writes the canonical and the dep-fanout finds nothing — watcher silently misses every optimistic update."
        )

        // The new emission must include the optimistic node.
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

    // MARK: - Mutation typed API regression

    /// Mutation response with a `@connection` field must normalize into
    /// the canonical record (`@connection.posts({})`). With the typed
    /// `executeMutation<Op>` re-parsing `Op.networkQuery` (directive-
    /// stripped), normalize sees no `@connection` directive and
    /// `Canonical.updateConnection` never runs — the canonical record
    /// is never written, and watchers depending on it silently miss
    /// every mutation-driven update.
    func test_typedExecuteMutation_normalizesConnectionResponseIntoCanonical() async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("BugReproRefresh", respondWith: TypedAPIDocumentRoutingTests.connectionResponse)

        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: http),
            cachePolicy: .cacheAndNetwork,
            suspensionTimeout: 0
        ))

        _ = try await client.executeMutation(
            mutation: BugReproRefresh.self,
            variables: .init()
        )

        // Connection-aware normalize must produce a canonical record
        // (`@connection.…`) somewhere in the graph. Mutations root
        // their writes at `@mutation.<plan.id>`, so the canonical key
        // is `@connection.@mutation.<id>.posts({})`. With the typed
        // executeMutation routing through `Op.networkQuery` (stripped),
        // the plan loses `isConnection`, normalize never invokes
        // `Canonical.updateConnection`, and no `@connection.*` record
        // is written — the regression we want to catch.
        let connectionRecords = client.graph.keysList().filter { $0.hasPrefix("@connection.") && $0.contains(".posts(") }
        XCTAssertFalse(
            connectionRecords.isEmpty,
            "typed executeMutation<Op> must use Op.document (precompiled plan with @connection metadata) so normalize takes the connection path and writes a `@connection.…` canonical record. None found."
        )
        // The Post:p1 entity must have been normalized.
        XCTAssertNotNil(
            client.graph.getRecord("Post:p1"),
            "mutation response must normalize the entity record"
        )
    }

    // MARK: - Subscription typed API regression

    /// Same shape for subscriptions: per-frame normalize must take the
    /// connection path. With `Op.networkQuery` (stripped) re-parsed,
    /// the directive is lost and the canonical never lands.
    func test_typedExecuteSubscription_normalizesConnectionFrameIntoCanonical() async throws {
        let ws = MockWSTransport(frames: [TypedAPIDocumentRoutingTests.connectionResponse])

        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport(), ws: ws),
            cachePolicy: .cacheAndNetwork,
            suspensionTimeout: 0
        ))

        let stream = try client.executeSubscription(
            subscription: BugReproStream.self,
            variables: .init()
        )

        // Drain one frame.
        for try await _ in stream { break }

        // Subscriptions root frames at `@subscription.<n>` so the
        // canonical key is `@connection.@subscription.<n>.posts({})`.
        // Pattern-match on `@connection.…posts(` to be agnostic to the
        // counter.
        let connectionRecords = client.graph.keysList().filter { $0.hasPrefix("@connection.") && $0.contains(".posts(") }
        XCTAssertFalse(
            connectionRecords.isEmpty,
            "typed executeSubscription<Op> must use Op.document so per-frame normalize writes a `@connection.…` canonical record. None found."
        )
        XCTAssertNotNil(
            client.graph.getRecord("Post:p1"),
            "subscription frame must normalize the entity record"
        )
    }
}
