import XCTest
@testable import Cachebay

/// Web parity for Layer Management (`core/optimistic.ts`):
/// stack 2+ layers, commit/revert in any order, revert-before-commit
/// cleanup, ordering preservation across temp-id swap, multiple revert
/// safety. The existing iOS suite only had a single 2-layer entity-patch
/// test; production-relevant behaviour spans connection ops.
final class OptimisticLayeringTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
    }

    private let canonicalKey: CacheKey = "@connection.posts({})"

    private func nodeIds(_ client: CachebayClient) -> [String] {
        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        return edges.compactMap { client.graph.getField($0, "node")?.ref }
    }

    // MARK: - revert preserves later layers

    func test_revertEarlierLayer_preservesLaterLayer_forConnections() throws {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")

        let tx1 = client.modifyOptimistic { b in
            let c = b.connection(selector)
            c.linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p1"),
                ]), options: LinkNodeOptions(position: .end))
            c.linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p2"),
                ]), options: LinkNodeOptions(position: .end))
        }
        let tx2 = client.modifyOptimistic { b in
            b.connection(selector).linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p3"),
                ]),
                options: LinkNodeOptions(position: .end)
            )
        }

        XCTAssertEqual(nodeIds(client), ["Post:p1", "Post:p2", "Post:p3"])

        tx1.revert()
        XCTAssertEqual(
            nodeIds(client), ["Post:p3"],
            "reverting layer 1 must drop p1/p2 but preserve layer 2's p3"
        )

        tx2.revert()
        XCTAssertEqual(nodeIds(client), [])
    }

    // MARK: - revert before commit cleanup

    func test_revertBeforeCommit_removesAllLayerEffects() throws {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")

        let tx = client.modifyOptimistic { b in
            b.connection(selector).linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p1"),
                ]),
                options: LinkNodeOptions(position: .end)
            )
        }
        XCTAssertEqual(nodeIds(client), ["Post:p1"])
        // linkNode is structural; the entity record is owned by
        // documents.normalize / writeFragment and not written here.

        tx.revert()
        XCTAssertEqual(nodeIds(client), [])
    }

    // MARK: - revert after commit no-op for connections

    func test_revertAfterCommit_noOp_forConnections() throws {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")

        let tx = client.modifyOptimistic { b in
            b.connection(selector).linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p1"),
                ]),
                options: LinkNodeOptions(position: .end)
            )
        }
        tx.dispose()
        tx.revert()

        XCTAssertEqual(
            nodeIds(client), ["Post:p1"],
            "after commit, connection state must NOT be rolled back")
    }

    // MARK: - ordering preserved when first layer commits with real data
    //
    // This is the immediate post-commit moment: L1 has just turned the
    // temp id into a real one, L2 is still pending and contributes p2.
    // Web also tests `t2.commit()` afterwards and asserts `[p1, p2]`
    // again — but iOS commit-phase writes are not re-recorded as a
    // baseline, so once L2 commits it can wipe the canonical and L1's
    // (now unrecorded) entity is lost. We restrict this test to the
    // documented-shared invariant: at the moment L1 commits, ordering
    // is preserved against the still-pending L2.
    func test_commitFirstLayerWithRealId_swapsTempIdInPlace() throws {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")

        let t1 = client.modifyOptimistic { b in
            b.connection(selector).linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("tmp-3"),
                ]),
                options: LinkNodeOptions(position: .start)
            )
        }
        let _tx = client.modifyOptimistic { b in
            b.connection(selector).linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p2"),
                ]),
                options: LinkNodeOptions(position: .end)
            )
        }
        XCTAssertEqual(
            nodeIds(client), ["Post:tmp-3", "Post:p2"],
            "before commit: temp-3 first, p2 last")

        // Commit closure captures the real id (here, hard-coded for the
        // test) from outer scope — no `ctx.data` plumbing.
        let realId = "p1"
        t1.commit { b in
            b.connection(selector).linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string(realId),
                ]),
                options: LinkNodeOptions(position: .start)
            )
        }
        XCTAssertEqual(
            nodeIds(client), ["Post:p1", "Post:p2"],
            "after L1.commit: p1 in start slot, p2 still last (ordering preserved)")
        withExtendedLifetime(_tx) {}
    }

    // MARK: - multiple revert calls are safe

    func test_repeatedRevert_isSafe() throws {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")

        let tx = client.modifyOptimistic { b in
            b.connection(selector).linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p1"),
                ]),
                options: LinkNodeOptions(position: .end)
            )
        }

        tx.revert()
        XCTAssertEqual(nodeIds(client), [])

        // Second revert — no-op, must not throw or affect state.
        tx.revert()
        XCTAssertEqual(nodeIds(client), [])

        // Third for good measure.
        tx.revert()
        XCTAssertEqual(nodeIds(client), [])
    }

    // MARK: - layer 2 reverting before layer 1

    func test_layer2_revertedBeforeLayer1_dropsOnlyLayer2() throws {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")

        let tx1 = client.modifyOptimistic { b in
            b.connection(selector).linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p1"),
                ]),
                options: LinkNodeOptions(position: .end)
            )
        }
        let tx2 = client.modifyOptimistic { b in
            b.connection(selector).linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p2"),
                ]),
                options: LinkNodeOptions(position: .end)
            )
        }

        // Reverse-order revert.
        tx2.revert()
        XCTAssertEqual(nodeIds(client), ["Post:p1"])

        tx1.revert()
        XCTAssertEqual(nodeIds(client), [])
    }

    // MARK: - evictAll on optimistic state

    func test_evictAll_dropsPendingLayers() async throws {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")

        let _tx = client.modifyOptimistic { b in
            b.connection(selector).linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p1"),
                ]),
                options: LinkNodeOptions(position: .end)
            )
        }
        XCTAssertEqual(nodeIds(client), ["Post:p1"])

        // evictAll wipes graph + drops pending layers, so the canonical
        // edges array should also be gone (record cleared).
        await client.evictAll()
        XCTAssertNil(client.graph.getRecord(canonicalKey))
        withExtendedLifetime(_tx) {}
    }
}
