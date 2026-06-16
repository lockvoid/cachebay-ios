import XCTest
@testable import Cachebay

/// Coverage gap from the original `OptimisticTests` — that file only
/// covered `.start` / `.end` positions and basic dedup. Connections
/// in production use `.before` / `.after` with anchors heavily
/// (inserting a reply between two specific edges, splicing a search
/// result before an anchor, …), and the anchor-fallback semantics
/// matter when the anchor was evicted or never existed.
///
/// `unlinkNode` edge cases (no-op on missing entity, idempotent on
/// repeat removal) round out the surface — the previous tests only
/// exercised the happy path.
final class OptimisticConnectionTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
    }

    private let canonicalKey: CacheKey = "@connection.posts({})"

    /// Read the canonical's edge list as `[Post:id]` strings — easier
    /// to assert against than the per-edge ref list.
    private func nodeIds(_ client: CachebayClient) -> [String] {
        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        return edges.compactMap { client.graph.getField($0, "node")?.ref }
    }

    private func seedTwoEdges(_ client: CachebayClient) {
        // Seed entity records via direct graph writes — linkNode is purely
        // structural and does not write entity scalars.
        client.graph.replaceRecord(
            "Post:p1",
            [
                CachebayConstants.typenameField: .string("Post"),
                "id": .string("p1"),
                "title": .string("A"),
            ])
        client.graph.replaceRecord(
            "Post:p2",
            [
                CachebayConstants.typenameField: .string("Post"),
                "id": .string("p2"),
                "title": .string("B"),
            ])
        client.graph.flush()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        client.modifyOptimistic { b in
            let c = b.connection(selector)
            c.linkNode(.key("Post:p1"), options: LinkNodeOptions(position: .end))
            c.linkNode(.key("Post:p2"), options: LinkNodeOptions(position: .end))
        }.dispose()
    }

    // MARK: - .before with anchor

    func test_addNode_before_withAnchor_insertsAtAnchorIndex() throws {
        let client = makeClient()
        seedTwoEdges(client)
        XCTAssertEqual(nodeIds(client), ["Post:p1", "Post:p2"])

        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        client.modifyOptimistic { b in
            b.connection(selector).linkNode(
                .object(["__typename": "Post", "id": "p15"]),
                options: LinkNodeOptions(position: .before, anchor: .key("Post:p2"))
            )
        }.dispose()

        XCTAssertEqual(nodeIds(client), ["Post:p1", "Post:p15", "Post:p2"])
    }

    // MARK: - .after with anchor

    func test_addNode_after_withAnchor_insertsAfterAnchor() throws {
        let client = makeClient()
        seedTwoEdges(client)

        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        client.modifyOptimistic { b in
            b.connection(selector).linkNode(
                .object(["__typename": "Post", "id": "p15"]),
                options: LinkNodeOptions(position: .after, anchor: .key("Post:p1"))
            )
        }.dispose()

        XCTAssertEqual(nodeIds(client), ["Post:p1", "Post:p15", "Post:p2"])
    }

    // MARK: - anchor missing → fallback

    func test_addNode_before_missingAnchor_fallsBackToStart() throws {
        let client = makeClient()
        seedTwoEdges(client)

        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        client.modifyOptimistic { b in
            b.connection(selector).linkNode(
                .object(["__typename": "Post", "id": "p99"]),
                options: LinkNodeOptions(position: .before, anchor: .key("Post:nonexistent"))
            )
        }.dispose()

        XCTAssertEqual(nodeIds(client), ["Post:p99", "Post:p1", "Post:p2"], ".before w/ missing anchor must fall back to .start")
    }

    func test_addNode_after_missingAnchor_fallsBackToEnd() throws {
        let client = makeClient()
        seedTwoEdges(client)

        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        client.modifyOptimistic { b in
            b.connection(selector).linkNode(
                .object(["__typename": "Post", "id": "p99"]),
                options: LinkNodeOptions(position: .after, anchor: .key("Post:nonexistent"))
            )
        }.dispose()

        XCTAssertEqual(nodeIds(client), ["Post:p1", "Post:p2", "Post:p99"], ".after w/ missing anchor must fall back to .end")
    }

    // MARK: - unlinkNode edge cases

    func test_removeNode_removesEdge_butLeavesEntityRecord() throws {
        let client = makeClient()
        seedTwoEdges(client)

        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        client.modifyOptimistic { b in
            b.connection(selector).unlinkNode(.key("Post:p1"))
        }.dispose()

        XCTAssertEqual(nodeIds(client), ["Post:p2"], "p1's edge gone")
        XCTAssertNotNil(client.graph.getRecord("Post:p1"), "unlinkNode must NOT delete the entity record itself — only the edge link")
    }

    func test_removeNode_missingNode_isNoOp() throws {
        let client = makeClient()
        seedTwoEdges(client)
        let before = nodeIds(client)

        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        client.modifyOptimistic { b in
            b.connection(selector).unlinkNode(.key("Post:does-not-exist"))
        }.dispose()

        XCTAssertEqual(nodeIds(client), before, "removing a non-edge must not perturb the connection")
    }

    func test_removeNode_repeated_isIdempotent() throws {
        let client = makeClient()
        seedTwoEdges(client)

        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        client.modifyOptimistic { b in
            b.connection(selector).unlinkNode(.key("Post:p1"))
            b.connection(selector).unlinkNode(.key("Post:p1"))  // again — must not throw / bork the list
            b.connection(selector).unlinkNode(.key("Post:p1"))  // and again
        }.dispose()

        XCTAssertEqual(nodeIds(client), ["Post:p2"])
    }

    // MARK: - revert restores baseline

    func test_addNode_revert_restoresBaseline() throws {
        let client = makeClient()
        seedTwoEdges(client)
        let baseline = nodeIds(client)

        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        let tx = client.modifyOptimistic { b in
            b.connection(selector).linkNode(
                .object(["__typename": "Post", "id": "p99"]),
                options: LinkNodeOptions(position: .start)
            )
        }
        XCTAssertEqual(nodeIds(client).count, 3)

        tx.revert()
        XCTAssertEqual(nodeIds(client), baseline, "revert must restore the canonical edge list to its pre-layer state")
    }

    func test_removeNode_revert_restoresMissingEdge() throws {
        let client = makeClient()
        seedTwoEdges(client)
        let baseline = nodeIds(client)

        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        let tx = client.modifyOptimistic { b in
            b.connection(selector).unlinkNode(.key("Post:p1"))
        }
        XCTAssertEqual(nodeIds(client), ["Post:p2"])

        tx.revert()
        XCTAssertEqual(nodeIds(client), baseline, "revert must put the removed edge back")
    }
}
