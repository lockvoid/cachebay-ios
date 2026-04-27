import XCTest
@testable import Cachebay

/// Web parity gap-fill for `core/optimistic.ts`:
///   - canonical-key form (`b.connection(key:)`) interop with selector form
///   - filter-isolated connections share key, others don't
///   - parent-isolated connections (`Query` vs `User:42`)
///   - ignored adds (no typename, no id, no entity ref)
///   - dedup of repeated addNode within one builder updates edge meta
///   - addNode-after-removeNode in the same layer
final class OptimisticConnectionAdvancedTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    private func nodeIds(_ client: CachebayClient, _ key: CacheKey) -> [String] {
        let edges = client.graph.getField(key, CachebayConstants.connectionEdgesField)?.refList ?? []
        return edges.compactMap { client.graph.getField($0, "node")?.ref }
    }

    // MARK: - canonical-key + selector interop

    func test_connectionByKey_andSelector_shareState() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        client.modifyOptimistic { b, _ in
            b.connection(key: canonicalKey).addNode(
                ["__typename": "Post", "id": "p1", "title": "P1"],
                options: AddNodeOptions(position: .end)
            )
        }.commit(nil)
        client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(parent: .key("Query"), key: "posts")).addNode(
                ["__typename": "Post", "id": "p2", "title": "P2"],
                options: AddNodeOptions(position: .end)
            )
        }.commit(nil)

        XCTAssertEqual(nodeIds(client, canonicalKey), ["Post:p1", "Post:p2"],
            "selector-form and canonical-key form must resolve to the same connection record")
    }

    func test_connectionByKey_withFilters_isReachableBySelector() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = #"@connection.posts({"category":"tech"})"#

        client.modifyOptimistic { b, _ in
            b.connection(key: canonicalKey).addNode(
                ["__typename": "Post", "id": "t1", "title": "Tech 1"],
                options: AddNodeOptions(position: .end)
            )
        }.commit(nil)
        XCTAssertEqual(nodeIds(client, canonicalKey), ["Post:t1"])

        client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(
                parent: .key("Query"),
                key: "posts",
                filters: ["category": .string("tech")]
            )).removeNode(.key("Post:t1"))
        }.commit(nil)
        XCTAssertEqual(nodeIds(client, canonicalKey), [],
            "removeNode via selector with same filters must hit the canonical-key connection")
    }

    func test_anchoredInsert_viaCanonicalKey() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        client.modifyOptimistic { b, _ in
            let c = b.connection(key: canonicalKey)
            c.addNode(["__typename": "Post", "id": "p1", "title": "P1"], options: AddNodeOptions(position: .end))
            c.addNode(["__typename": "Post", "id": "p3", "title": "P3"], options: AddNodeOptions(position: .end))
        }.commit(nil)

        client.modifyOptimistic { b, _ in
            b.connection(key: canonicalKey).addNode(
                ["__typename": "Post", "id": "p2", "title": "P2"],
                options: AddNodeOptions(position: .after, anchor: .key("Post:p1"))
            )
        }.commit(nil)

        XCTAssertEqual(nodeIds(client, canonicalKey), ["Post:p1", "Post:p2", "Post:p3"])
    }

    // MARK: - filter / parent isolation

    func test_filteredConnections_isolatedByCategory() throws {
        let client = makeClient()
        let techKey: CacheKey = #"@connection.posts({"category":"tech"})"#
        let lifeKey: CacheKey = #"@connection.posts({"category":"life"})"#

        client.modifyOptimistic { b, _ in
            let tech = b.connection(ConnectionSelector(
                parent: .key("Query"), key: "posts", filters: ["category": .string("tech")]
            ))
            tech.addNode(["__typename": "Post", "id": "p1", "title": "Tech"], options: AddNodeOptions(position: .end))
            let life = b.connection(ConnectionSelector(
                parent: .key("Query"), key: "posts", filters: ["category": .string("life")]
            ))
            life.addNode(["__typename": "Post", "id": "p2", "title": "Life"], options: AddNodeOptions(position: .end))
        }.commit(nil)

        XCTAssertEqual(nodeIds(client, techKey), ["Post:p1"])
        XCTAssertEqual(nodeIds(client, lifeKey), ["Post:p2"])
    }

    func test_parentIsolatedConnections() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "User:42",
            fragment: "fragment U on User { id }",
            data: .object(["__typename": "User", "id": "42"])
        )

        client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(parent: .key("Query"), key: "posts"))
              .addNode(["__typename": "Post", "id": "p10", "title": "Root"], options: AddNodeOptions(position: .end))

            b.connection(ConnectionSelector(parent: .object(["__typename": "User", "id": "42"]), key: "posts"))
              .addNode(["__typename": "Post", "id": "p11", "title": "User"], options: AddNodeOptions(position: .end))
        }.commit(nil)

        XCTAssertEqual(nodeIds(client, "@connection.posts({})"), ["Post:p10"])
        XCTAssertEqual(nodeIds(client, "@connection.User:42.posts({})"), ["Post:p11"])
    }

    // MARK: - ignored adds

    func test_addNode_withoutTypename_isIgnored() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        client.modifyOptimistic { b, _ in
            // No `__typename` → graph.identify returns nil → addNode bails.
            b.connection(ConnectionSelector(parent: .key("Query"), key: "posts"))
              .addNode(["id": "x1", "title": "No typename"], options: AddNodeOptions(position: .end))
        }.commit(nil)

        XCTAssertEqual(nodeIds(client, canonicalKey), [])
    }

    func test_addNode_withoutId_isIgnored() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(parent: .key("Query"), key: "posts"))
              .addNode(["__typename": "Post", "title": "No id"], options: AddNodeOptions(position: .end))
        }.commit(nil)

        XCTAssertEqual(nodeIds(client, canonicalKey), [])
    }

    func test_removeNode_withInvalidObjectRef_isIgnored() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        // Seed a real edge first.
        client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(parent: .key("Query"), key: "posts"))
              .addNode(["__typename": "Post", "id": "p1", "title": "P1"], options: AddNodeOptions(position: .end))
        }.commit(nil)

        client.modifyOptimistic { b, _ in
            // No id — identify returns nil — must be a safe no-op.
            b.connection(ConnectionSelector(parent: .key("Query"), key: "posts"))
              .removeNode(.object(["__typename": "Post"]))
        }.commit(nil)

        XCTAssertEqual(nodeIds(client, canonicalKey), ["Post:p1"])
    }

    // MARK: - dedup-by-id refreshes meta

    func test_addNode_dedup_refreshesEdgeMetaInPlace() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        client.modifyOptimistic { b, _ in
            let c = b.connection(ConnectionSelector(parent: .key("Query"), key: "posts"))
            c.addNode(
                ["__typename": "Post", "id": "p1", "title": "First"],
                options: AddNodeOptions(position: .end, edge: ["score": .int(1), "cursor": .string("c-old")])
            )
            c.addNode(
                ["__typename": "Post", "id": "p1", "title": "Updated"],
                options: AddNodeOptions(position: .end, edge: ["score": .int(42), "cursor": .string("c-new")])
            )
        }.commit(nil)

        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edges.count, 1, "second addNode dedups against the first by node id")
        let edgeKey = edges[0]
        XCTAssertEqual(client.graph.getField(edgeKey, "score")?.int, 42,
            "edge meta from the second add must overwrite the first")
        XCTAssertEqual(client.graph.getField(edgeKey, "cursor")?.string, "c-new")
        // Entity record shows the latest write too.
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Updated")
    }

    // MARK: - removeNode then addNode with same id (no existing canonical)

    func test_removeAndAdd_inOneLayer_creates_canonical() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        // No prior canonical record exists.
        XCTAssertNil(client.graph.getRecord(canonicalKey))

        client.modifyOptimistic { b, _ in
            let c = b.connection(ConnectionSelector(parent: .key("Query"), key: "posts"))
            c.removeNode(.object(["__typename": "Post", "id": "p1"]))   // no-op
            c.addNode(["__typename": "Post", "id": "p1", "title": "Recovered"],
                      options: AddNodeOptions(position: .end))
        }.commit(nil)

        XCTAssertEqual(nodeIds(client, canonicalKey), ["Post:p1"])
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Recovered")
    }
}
