import XCTest
@testable import Cachebay

/// Web parity gap-fill for `core/optimistic.ts`:
///   - canonical-key form (`b.connection(key:)`) interop with selector form
///   - filter-isolated connections share key, others don't
///   - parent-isolated connections (`Query` vs `User:42`)
///   - ignored adds (no typename, no id, no entity ref)
///   - dedup of repeated linkNode within one builder updates edge meta
///   - linkNode-after-unlinkNode in the same layer
final class OptimisticConnectionAdvancedTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
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

        client.modifyOptimistic { b in
            b.connection(key: canonicalKey).linkNode(
                .object(["__typename": "Post", "id": "p1"]),
                options: LinkNodeOptions(position: .end)
            )
        }.dispose()
        client.modifyOptimistic { b in
            b.connection(ConnectionSelector(parent: .key("Query"), key: "posts")).linkNode(
                .object(["__typename": "Post", "id": "p2"]),
                options: LinkNodeOptions(position: .end)
            )
        }.dispose()

        XCTAssertEqual(
            nodeIds(client, canonicalKey), ["Post:p1", "Post:p2"],
            "selector-form and canonical-key form must resolve to the same connection record")
    }

    func test_connectionByKey_withFilters_isReachableBySelector() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = #"@connection.posts({"category":"tech"})"#

        client.modifyOptimistic { b in
            b.connection(key: canonicalKey).linkNode(
                .object(["__typename": "Post", "id": "t1"]),
                options: LinkNodeOptions(position: .end)
            )
        }.dispose()
        XCTAssertEqual(nodeIds(client, canonicalKey), ["Post:t1"])

        client.modifyOptimistic { b in
            b.connection(
                ConnectionSelector(
                    parent: .key("Query"),
                    key: "posts",
                    filters: ["category": .string("tech")]
                )
            ).unlinkNode(.key("Post:t1"))
        }.dispose()
        XCTAssertEqual(
            nodeIds(client, canonicalKey), [],
            "unlinkNode via selector with same filters must hit the canonical-key connection")
    }

    func test_anchoredInsert_viaCanonicalKey() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        client.modifyOptimistic { b in
            let c = b.connection(key: canonicalKey)
            c.linkNode(.object(["__typename": "Post", "id": "p1"]), options: LinkNodeOptions(position: .end))
            c.linkNode(.object(["__typename": "Post", "id": "p3"]), options: LinkNodeOptions(position: .end))
        }.dispose()

        client.modifyOptimistic { b in
            b.connection(key: canonicalKey).linkNode(
                .object(["__typename": "Post", "id": "p2"]),
                options: LinkNodeOptions(position: .after, anchor: .key("Post:p1"))
            )
        }.dispose()

        XCTAssertEqual(nodeIds(client, canonicalKey), ["Post:p1", "Post:p2", "Post:p3"])
    }

    // MARK: - filter / parent isolation

    func test_filteredConnections_isolatedByCategory() throws {
        let client = makeClient()
        let techKey: CacheKey = #"@connection.posts({"category":"tech"})"#
        let lifeKey: CacheKey = #"@connection.posts({"category":"life"})"#

        client.modifyOptimistic { b in
            let tech = b.connection(
                ConnectionSelector(
                    parent: .key("Query"), key: "posts", filters: ["category": .string("tech")]
                ))
            tech.linkNode(.object(["__typename": "Post", "id": "p1"]), options: LinkNodeOptions(position: .end))
            let life = b.connection(
                ConnectionSelector(
                    parent: .key("Query"), key: "posts", filters: ["category": .string("life")]
                ))
            life.linkNode(.object(["__typename": "Post", "id": "p2"]), options: LinkNodeOptions(position: .end))
        }.dispose()

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

        client.modifyOptimistic { b in
            b.connection(ConnectionSelector(parent: .key("Query"), key: "posts"))
                .linkNode(.object(["__typename": "Post", "id": "p10"]), options: LinkNodeOptions(position: .end))

            b.connection(ConnectionSelector(parent: .object(["__typename": "User", "id": "42"]), key: "posts"))
                .linkNode(.object(["__typename": "Post", "id": "p11"]), options: LinkNodeOptions(position: .end))
        }.dispose()

        XCTAssertEqual(nodeIds(client, "@connection.posts({})"), ["Post:p10"])
        XCTAssertEqual(nodeIds(client, "@connection.User:42.posts({})"), ["Post:p11"])
    }

    // MARK: - ignored adds

    func test_addNode_withoutTypename_isIgnored() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        client.modifyOptimistic { b in
            // No `__typename` → graph.identify returns nil → linkNode bails.
            b.connection(ConnectionSelector(parent: .key("Query"), key: "posts"))
                .linkNode(.object(["id": "x1", "title": "No typename"]), options: LinkNodeOptions(position: .end))
        }.dispose()

        XCTAssertEqual(nodeIds(client, canonicalKey), [])
    }

    func test_addNode_withoutId_isIgnored() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        client.modifyOptimistic { b in
            b.connection(ConnectionSelector(parent: .key("Query"), key: "posts"))
                .linkNode(.object(["__typename": "Post", "title": "No id"]), options: LinkNodeOptions(position: .end))
        }.dispose()

        XCTAssertEqual(nodeIds(client, canonicalKey), [])
    }

    func test_removeNode_withInvalidObjectRef_isIgnored() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        // Seed a real edge first.
        client.modifyOptimistic { b in
            b.connection(ConnectionSelector(parent: .key("Query"), key: "posts"))
                .linkNode(.object(["__typename": "Post", "id": "p1"]), options: LinkNodeOptions(position: .end))
        }.dispose()

        client.modifyOptimistic { b in
            // No id — identify returns nil — must be a safe no-op.
            b.connection(ConnectionSelector(parent: .key("Query"), key: "posts"))
                .unlinkNode(.object(["__typename": "Post"]))
        }.dispose()

        XCTAssertEqual(nodeIds(client, canonicalKey), ["Post:p1"])
    }

    // MARK: - dedup-by-id refreshes meta

    func test_addNode_dedup_refreshesEdgeMetaInPlace() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        client.modifyOptimistic { b in
            let c = b.connection(ConnectionSelector(parent: .key("Query"), key: "posts"))
            c.linkNode(
                .object(["__typename": "Post", "id": "p1"]),
                options: LinkNodeOptions(position: .end, edge: ["score": .int(1), "cursor": .string("c-old")])
            )
            c.linkNode(
                .object(["__typename": "Post", "id": "p1"]),
                options: LinkNodeOptions(position: .end, edge: ["score": .int(42), "cursor": .string("c-new")])
            )
        }.dispose()

        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edges.count, 1, "second linkNode dedups against the first by node id")
        let edgeKey = edges[0]
        XCTAssertEqual(
            client.graph.getField(edgeKey, "score")?.int, 42,
            "edge meta from the second add must overwrite the first")
        XCTAssertEqual(client.graph.getField(edgeKey, "cursor")?.string, "c-new")
    }

    // MARK: - unlinkNode then linkNode with same id (no existing canonical)

    func test_removeAndAdd_inOneLayer_creates_canonical() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        // No prior canonical record exists.
        XCTAssertNil(client.graph.getRecord(canonicalKey))

        // Seed entity (linkNode is purely structural).
        client.graph.replaceRecord(
            "Post:p1",
            [
                CachebayConstants.typenameField: .string("Post"),
                "id": .string("p1"),
                "title": .string("Recovered"),
            ])
        client.graph.flush()

        client.modifyOptimistic { b in
            let c = b.connection(ConnectionSelector(parent: .key("Query"), key: "posts"))
            c.unlinkNode(.object(["__typename": "Post", "id": "p1"]))  // no-op
            c.linkNode(
                .key("Post:p1"),
                options: LinkNodeOptions(position: .end))
        }.dispose()

        XCTAssertEqual(nodeIds(client, canonicalKey), ["Post:p1"])
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Recovered")
    }
}
