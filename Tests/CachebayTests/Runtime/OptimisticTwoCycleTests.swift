import XCTest
@testable import Cachebay

/// Coverage for the **split-closure commit** semantic — the optimistic
/// closure runs once at `modifyOptimistic` time with no data, and the
/// commit closure runs once at `tx.commit { … }` time, capturing typed
/// server data from outer scope. This is what lets a caller use a temp
/// id during the optimistic pass and swap to the real server id on
/// commit, without ever touching a `JSONValue?` `ctx.data` plumbing.
///
/// File renamed in v0.8.0 from "two-cycle commit" — the old name
/// referred to the SAME closure being replayed twice (`.optimistic`
/// then `.commit`). New mental model: two SEPARATE closures, one per
/// phase, each captures from outer scope.
final class OptimisticTwoCycleTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
    }

    // MARK: - Entity patch with commit-phase data

    func test_patch_commitClosureCapturesServerPayload() throws {
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

        // Optimistic closure writes the temp/draft title.
        let tx = client.modifyOptimistic { b in
            b.patch(.key("Post:p1"), ["title": .string("Drafting…")], mode: .merge)
        }
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Drafting…")

        // Commit closure captures the (here, simulated) server-confirmed
        // title from outer scope and writes it. The optimistic closure
        // does NOT re-run; baseline is restored, then this commit closure
        // runs once.
        let serverTitle = "Server confirmed"
        tx.commit { b in
            b.patch(.key("Post:p1"), ["title": .string(serverTitle)], mode: .merge)
        }
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Server confirmed")
    }

    // MARK: - Connection linkNode temp-id swap on commit

    func test_linkNode_tempIdReplacedByServerIdOnCommit() throws {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        let canonicalKey: CacheKey = "@connection.posts({})"

        // Optimistic closure: write temp entity + link temp id.
        let tempId = "tmp:1"
        let tx = client.modifyOptimistic { b in
            b.patch(
                .key("Post:\(tempId)"),
                [
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string(tempId),
                    "title": .string("Drafting…"),
                ], mode: .merge)
            b.connection(selector).linkNode(
                .key("Post:\(tempId)"),
                options: LinkNodeOptions(position: .start)
            )
        }

        // Optimistic state: edge points at Post:tmp:1.
        let optimisticEdges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(optimisticEdges.count, 1)
        let optimisticNode = optimisticEdges.first.flatMap { client.graph.getField($0, "node")?.ref }
        XCTAssertEqual(optimisticNode, "Post:tmp:1")

        // Commit closure: write real entity + link real id. Baseline
        // restore drops Post:tmp:1 AND its edge automatically — the
        // commit closure only has to add the real-id row + edge.
        let realId = "p9"
        let realTitle = "From Server"
        tx.commit { b in
            b.patch(
                .key("Post:\(realId)"),
                [
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string(realId),
                    "title": .string(realTitle),
                ], mode: .merge)
            b.connection(selector).linkNode(
                .key("Post:\(realId)"),
                options: LinkNodeOptions(position: .start)
            )
        }

        let committedEdges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        let committedNodes = committedEdges.compactMap { client.graph.getField($0, "node")?.ref }
        XCTAssertEqual(committedNodes, ["Post:p9"], "temp:1 must be gone, p9 must be in its place at start")
        XCTAssertEqual(client.graph.getField("Post:p9", "title")?.string, "From Server")
    }

    // MARK: - linkNode edge-meta updates between phases

    func test_linkNode_edgeMeta_updatedBetweenPhases() throws {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        let canonicalKey: CacheKey = "@connection.posts({})"

        // Optimistic edge has temp cursor.
        let tx = client.modifyOptimistic { b in
            b.connection(selector).linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p10"),
                ]),
                options: LinkNodeOptions(position: .start, edge: ["cursor": .string("tmp-cursor")])
            )
        }

        let optimisticEdge = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList?.first
        XCTAssertEqual(optimisticEdge.flatMap { client.graph.getField($0, "cursor")?.string }, "tmp-cursor")

        // Commit closure relinks with the server-confirmed cursor.
        // linkNode is idempotent on dedup — the existing edge meta is
        // updated in place.
        let realCursor = "real-cursor"
        tx.commit { b in
            b.connection(selector).linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p10"),
                ]),
                options: LinkNodeOptions(position: .start, edge: ["cursor": .string(realCursor)])
            )
        }

        let committedEdge = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList?.first
        XCTAssertEqual(committedEdge.flatMap { client.graph.getField($0, "cursor")?.string }, "real-cursor")
    }
}
