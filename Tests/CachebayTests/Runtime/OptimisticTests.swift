import XCTest
@testable import Cachebay

final class OptimisticTests: XCTestCase {
    private func makeClient() -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
    }

    func test_patch_replace_mode() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "Post:p1", fragment: "fragment P on Post { id title body }",
            data: .object([
                "__typename": "Post", "id": "p1", "title": "T", "body": "B",
            ]))
        let tx = client.modifyOptimistic { b in
            b.patch(.key("Post:p1"), ["__typename": "Post", "id": "p1", "title": "Fresh"], mode: .replace)
        }
        // `body` should be gone under replace.
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Fresh")
        XCTAssertNil(client.graph.getField("Post:p1", "body"))
        tx.revert()
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "T")
        XCTAssertEqual(client.graph.getField("Post:p1", "body")?.string, "B")
    }

    func test_two_layers_revert_first_preserves_second() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "Post:p1", fragment: "fragment P on Post { id title }",
            data: .object([
                "__typename": "Post", "id": "p1", "title": "A",
            ]))
        let tx1 = client.modifyOptimistic { b in
            b.patch(.key("Post:p1"), ["title": "A-l1"], mode: .merge)
        }
        let tx2 = client.modifyOptimistic { b in
            b.patch(.key("Post:p1"), ["title": "A-l2"], mode: .merge)
        }
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "A-l2")
        tx1.revert()
        // L2 still on top; it should remain the visible state.
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "A-l2")
        tx2.revert()
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "A")
    }

    func test_delete_then_revert_restores() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "Post:p1", fragment: "fragment P on Post { id title }",
            data: .object([
                "__typename": "Post", "id": "p1", "title": "Gone",
            ]))
        let tx = client.modifyOptimistic { b in
            b.delete(.key("Post:p1"))
        }
        XCTAssertNil(client.graph.getRecord("Post:p1"))
        tx.revert()
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Gone")
    }

    func test_addNode_start_and_end() throws {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        let tx = client.modifyOptimistic { b in
            let c = b.connection(selector)
            c.linkNode(.object(["__typename": "Post", "id": "p1"]), options: LinkNodeOptions(position: .start))
            c.linkNode(.object(["__typename": "Post", "id": "p2"]), options: LinkNodeOptions(position: .end))
            c.linkNode(.object(["__typename": "Post", "id": "p3"]), options: LinkNodeOptions(position: .start))
        }
        // Expect order: [p3, p1, p2]
        let canonicalKey = "@connection.posts({})"
        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edges.count, 3)
        var ids: [String] = []
        for ek in edges {
            if let nref = client.graph.getField(ek, "node")?.ref { ids.append(nref) }
        }
        XCTAssertEqual(ids, ["Post:p3", "Post:p1", "Post:p2"])
        tx.revert()
        XCTAssertEqual(client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList?.count ?? 0, 0)
    }

    func test_addNode_dedup_by_entity() throws {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        let _tx = client.modifyOptimistic { b in
            let c = b.connection(selector)
            c.linkNode(.object(["__typename": "Post", "id": "p1"]), options: LinkNodeOptions(position: .start))
            // Same entity — should no-op on edges list.
            c.linkNode(.object(["__typename": "Post", "id": "p1"]), options: LinkNodeOptions(position: .end))
        }
        let canonicalKey = "@connection.posts({})"
        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edges.count, 1)
        withExtendedLifetime(_tx) {}
    }

    func test_connection_patch_pageInfo() throws {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        let _tx = client.modifyOptimistic { b in
            let c = b.connection(selector)
            c.patch([
                "pageInfo": .object(["hasNextPage": false, "endCursor": "c1"]),
                "totalCount": 42,
            ])
        }
        let canonicalKey = "@connection.posts({})"
        let pageInfoRef = client.graph.getField(canonicalKey, CachebayConstants.connectionPageInfoField)?.ref
        XCTAssertNotNil(pageInfoRef)
        XCTAssertEqual(client.graph.getField(pageInfoRef!, "hasNextPage")?.bool, false)
        XCTAssertEqual(client.graph.getField(pageInfoRef!, "endCursor")?.string, "c1")
        XCTAssertEqual(client.graph.getField(canonicalKey, "totalCount")?.int, 42)
        withExtendedLifetime(_tx) {}
    }
}
