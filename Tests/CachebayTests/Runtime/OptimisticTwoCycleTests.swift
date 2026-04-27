import XCTest
@testable import Cachebay

/// Coverage for the **two-cycle commit** semantic — the same builder
/// closure is run once with `phase: .optimistic` (no `ctx.data`) and
/// once with `phase: .commit` (server payload in `ctx.data`). This is
/// what lets a caller use a temp id during the optimistic pass and
/// swap to the real server id on commit, without writing a second
/// builder by hand. Every consumer-facing optimistic mutation flow
/// in ferment relies on this — the existing iOS test surface only
/// touched the basic commit-no-data case.
final class OptimisticTwoCycleTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    // MARK: - Entity patch with commit-phase data

    func test_patch_commitWithData_replaysWithServerPayload() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("baseline"),
            ])
        )

        // Builder reads `ctx.data?["title"]` — `.optimistic` phase has
        // no data so the temp-title applies; `.commit(serverPayload)`
        // re-runs the same builder with `ctx.data` populated, so the
        // server-confirmed title overwrites.
        let tx = client.modifyOptimistic { b, ctx in
            let title: JSONValue = ctx.data?["title"] ?? .string("Drafting…")
            b.patch(.key("Post:p1"), ["title": title], mode: .merge)
        }

        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Drafting…")

        tx.commit(.object(["title": .string("Server confirmed")]))
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Server confirmed")
    }

    // MARK: - Connection addNode temp-id swap on commit

    func test_addNode_tempIdReplacedByServerIdOnCommit() throws {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        let canonicalKey: CacheKey = "@connection.posts({})"

        // Optimistic pass uses a temp id; commit pass reuses ctx.data
        // for the real server-assigned id. The runtime has to drop the
        // temp edge and lay the real one in its place.
        let tx = client.modifyOptimistic { b, ctx in
            let id = ctx.data?["id"]?.string ?? "tmp:1"
            let title = ctx.data?["title"]?.string ?? "Drafting…"
            b.connection(selector).addNode(
                ["__typename": "Post", "id": .string(id), "title": .string(title)],
                options: AddNodeOptions(position: .start)
            )
        }

        // Optimistic state: edge points at Post:tmp:1.
        let optimisticEdges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(optimisticEdges.count, 1)
        let optimisticNode = optimisticEdges.first.flatMap { client.graph.getField($0, "node")?.ref }
        XCTAssertEqual(optimisticNode, "Post:tmp:1")

        // Commit with server data — temp edge replaced by Post:p9.
        tx.commit(.object(["id": .string("p9"), "title": .string("From Server")]))

        let committedEdges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        let committedNodes = committedEdges.compactMap { client.graph.getField($0, "node")?.ref }
        XCTAssertEqual(committedNodes, ["Post:p9"], "temp:1 must be gone, p9 must be in its place at start")
        XCTAssertEqual(client.graph.getField("Post:p9", "title")?.string, "From Server")
    }

    // MARK: - addNode edge-meta updates between phases

    func test_addNode_edgeMeta_updatedBetweenPhases() throws {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        let canonicalKey: CacheKey = "@connection.posts({})"

        let tx = client.modifyOptimistic { b, ctx in
            let cursor = ctx.data?["cursor"]?.string ?? "tmp-cursor"
            b.connection(selector).addNode(
                ["__typename": "Post", "id": "p10", "title": "Hello"],
                options: AddNodeOptions(position: .start, edge: ["cursor": .string(cursor)])
            )
        }

        // Optimistic edge has temp cursor.
        let optimisticEdge = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList?.first
        XCTAssertEqual(optimisticEdge.flatMap { client.graph.getField($0, "cursor")?.string }, "tmp-cursor")

        tx.commit(.object(["cursor": .string("real-cursor")]))

        let committedEdge = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList?.first
        XCTAssertEqual(committedEdge.flatMap { client.graph.getField($0, "cursor")?.string }, "real-cursor")
    }
}
