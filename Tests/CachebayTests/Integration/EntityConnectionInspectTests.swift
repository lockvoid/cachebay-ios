import XCTest
@testable import Cachebay

/// ENTITY-parented connection discovery — the shape the Ferment app's cook
/// admission rides: `query { project(id:) { cooks @connection } }` is
/// executed through the REAL pipeline, then
/// `inspect.getConnectionKeys(parent: .entity("Project:<id>"), key: "cooks")`
/// must find the canonical so a live `linkNode` can append a
/// subscription-delivered cook. Every other inspect/watcher test used a
/// ROOT-parented connection; this pins the entity-parented lookup, inline
/// AND fragment-hosted `@connection`. NB the parent string must be the
/// record's KEYSPACE key — with `interfaces` configured, implementers fold
/// into the interface keyspace, so callers derive the parent via
/// `identify`, never a hand-built `"Typename:id"` (the Ferment
/// translation-pill outage was exactly that, app-side).
final class EntityConnectionInspectTests: XCTestCase {

    private let cooksQuery = """
        query Cooks($projectId: ID!) {
            project(id: $projectId) {
                id
                cooks(first: 100000) @connection(mode: "infinite", filters: []) {
                    pageInfo { endCursor hasNextPage }
                    edges {
                        cursor
                        node { id key state }
                    }
                }
            }
        }
        """

    /// The Ferment app's REAL shape: the `@connection` lives inside a named
    /// fragment on the entity, not inline in the query.
    private let fragmentCooksQuery = """
        query Cooks($projectId: ID!) {
            project(id: $projectId) {
                ...ProjectCooksFields
            }
        }
        fragment ProjectCooksFields on Project {
            id
            cooks(first: 100000) @connection(mode: "infinite", filters: []) {
                pageInfo { endCursor hasNextPage }
                edges {
                    cursor
                    node { id key state }
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

    private func projectCooksResponse() -> JSONValue {
        .object([
            "project": .object([
                "__typename": .string("Project"),
                "id": .string("6"),
                "cooks": .object([
                    "__typename": .string("CookConnection"),
                    "pageInfo": .object([
                        "__typename": .string("PageInfo"),
                        "endCursor": .string("c1"),
                        "hasNextPage": .bool(false),
                    ]),
                    "edges": .array([
                        .object([
                            "__typename": .string("CookEdge"),
                            "cursor": .string("c1"),
                            "node": .object([
                                "__typename": .string("Cook"),
                                "id": .string("pmck/Element/e1/transcript"),
                                "key": .string("pmck/Element/e1/transcript"),
                                "state": .string("succeeded"),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        ])
    }

    func test_entityParentedConnection_isDiscoverable_and_linkNodeGrowsTheWatchedList() async throws {
        try await runScenario(query: self.cooksQuery)
    }

    /// The @connection selected THROUGH a named fragment (the app's actual
    /// document shape — `ProjectCooksFields on Project`).
    func test_fragmentHostedConnection_isDiscoverable_and_linkNodeGrowsTheWatchedList() async throws {
        try await runScenario(query: self.fragmentCooksQuery)
    }

    private func runScenario(query: String) async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("cooks", respondWith: self.projectCooksResponse())
        let client = self.makeClient(http: http)

        let received = CaptureBox<[JSONValue]>(value: [])
        let _ = try client.watchQuery(
            query: query,
            options: WatchQueryOptions(
                variables: ["projectId": .string("6")],
                immediate: true,
                onData: { received.append($0) }
            )
        )
        _ = try await client.executeQuery(
            query: query,
            variables: ["projectId": .string("6")],
            cachePolicy: .cacheAndNetwork
        )
        XCTAssertGreaterThanOrEqual(received.value.count, 1, "watcher must fire with the fetched list")

        // 1. Discovery under the ENTITY parent — [] silently no-ops every
        // live admission (the translation-pill outage).
        let keys = client.inspect.getConnectionKeys(parent: .entity("Project:6"), key: "cooks")
        XCTAssertFalse(
            keys.isEmpty,
            "entity-parented @connection must be discoverable via getConnectionKeys"
        )

        // 2. A live admission must grow the watched list — the
        // subscription → admit(linkNode) pipeline.
        try client.writeFragment(
            id: "Cook:pmck/Element/e1/transcript-de",
            fragment: "fragment C on Cook { id key state }",
            data: .object([
                CachebayConstants.typenameField: .string("Cook"),
                "id": .string("pmck/Element/e1/transcript-de"),
                "key": .string("pmck/Element/e1/transcript-de"),
                "state": .string("pending"),
            ])
        )
        let countBefore = received.value.count
        client.modifyOptimistic { b in
            for key in client.inspect.getConnectionKeys(parent: .entity("Project:6"), key: "cooks") {
                b.connection(key: key).linkNode(
                    .key("Cook:pmck/Element/e1/transcript-de"),
                    options: LinkNodeOptions(position: .end)
                )
            }
        }.dispose()

        XCTAssertGreaterThan(received.value.count, countBefore, "watcher must re-fire after the admission")
        guard let last = received.value.last,
            case .object(let root) = last,
            case .object(let project) = root["project"] ?? .undefined,
            case .object(let cooks) = project["cooks"] ?? .undefined,
            case .array(let edges) = cooks["edges"] ?? .undefined
        else {
            XCTFail("watcher data shape unexpected: \(received.value.last ?? .undefined)")
            return
        }
        XCTAssertEqual(edges.count, 2, "the admitted cook must join the watched list")
    }
}
