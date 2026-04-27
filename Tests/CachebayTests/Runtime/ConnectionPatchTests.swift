import XCTest
@testable import Cachebay

/// `c.patch(update)` semantics — the existing `OptimisticTests` only
/// covers a single `pageInfo.hasNextPage` flip. These tests cover the
/// nuances that matter in production:
///
/// 1. `pageInfo` updates merge **field-by-field** on the linked
///    PageInfo record — supplying `{hasNextPage: true}` must not wipe
///    a prior `endCursor`.
/// 2. Other connection-level fields (`totalCount`, etc.) merge
///    shallowly onto the canonical record itself.
/// 3. Patches survive commit and revert correctly — same baseline
///    semantics as addNode/removeNode.
final class ConnectionPatchTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    private let canonicalKey: CacheKey = "@connection.posts({})"

    /// Seed a connection with one node and a populated PageInfo so we can
    /// observe field-level merge behaviour on the patch.
    private func seed(_ client: CachebayClient) {
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        client.modifyOptimistic { b, _ in
            let c = b.connection(selector)
            c.addNode(["__typename": "Post", "id": "p1", "title": "A"], options: AddNodeOptions(position: .end))
            c.patch([
                "pageInfo": .object([
                    "endCursor": .string("c-end"),
                    "hasNextPage": .bool(true),
                ]),
                "totalCount": .int(42),
            ])
        }.commit(nil)
    }

    private func pageInfoField(_ client: CachebayClient, _ field: String) -> JSONValue? {
        guard let pageInfoRef = client.graph.getField(canonicalKey, CachebayConstants.connectionPageInfoField)?.ref
        else { return nil }
        return client.graph.getField(pageInfoRef, field)
    }

    // MARK: - pageInfo merges field-by-field

    func test_patch_pageInfo_partialUpdate_preservesOtherFields() throws {
        let client = makeClient()
        seed(client)
        XCTAssertEqual(pageInfoField(client, "endCursor")?.string, "c-end")
        XCTAssertEqual(pageInfoField(client, "hasNextPage")?.bool, true)

        // Patch only one pageInfo field — the other must survive.
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        client.modifyOptimistic { b, _ in
            b.connection(selector).patch([
                "pageInfo": .object(["hasNextPage": .bool(false)]),
            ])
        }.commit(nil)

        XCTAssertEqual(pageInfoField(client, "endCursor")?.string, "c-end", "endCursor must survive a hasNextPage-only patch")
        XCTAssertEqual(pageInfoField(client, "hasNextPage")?.bool, false)
    }

    // MARK: - canonical-level extras merge

    func test_patch_canonicalExtras_mergeShallowly() throws {
        let client = makeClient()
        seed(client)
        XCTAssertEqual(client.graph.getField(canonicalKey, "totalCount")?.int, 42)

        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        client.modifyOptimistic { b, _ in
            b.connection(selector).patch(["totalCount": .int(43)])
        }.commit(nil)

        XCTAssertEqual(client.graph.getField(canonicalKey, "totalCount")?.int, 43, "totalCount must update")
        // The edges list — also a top-level connection field — must be untouched.
        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edges.count, 1, "edges list must not be wiped by a totalCount-only patch")
    }

    // MARK: - revert restores patched fields

    func test_patch_revert_restoresPriorPageInfo() throws {
        let client = makeClient()
        seed(client)
        let originalCursor = pageInfoField(client, "endCursor")?.string
        let originalHasNext = pageInfoField(client, "hasNextPage")?.bool
        XCTAssertEqual(originalCursor, "c-end")
        XCTAssertEqual(originalHasNext, true)

        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        let tx = client.modifyOptimistic { b, _ in
            b.connection(selector).patch([
                "pageInfo": .object([
                    "endCursor": .string("c-overwritten"),
                    "hasNextPage": .bool(false),
                ]),
            ])
        }
        XCTAssertEqual(pageInfoField(client, "endCursor")?.string, "c-overwritten")
        XCTAssertEqual(pageInfoField(client, "hasNextPage")?.bool, false)

        tx.revert()
        XCTAssertEqual(pageInfoField(client, "endCursor")?.string, originalCursor)
        XCTAssertEqual(pageInfoField(client, "hasNextPage")?.bool, originalHasNext)
    }

    // MARK: - empty patch is a no-op

    func test_patch_empty_isNoOp() throws {
        let client = makeClient()
        seed(client)
        let edgesBefore = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []

        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        let tx = client.modifyOptimistic { b, _ in
            b.connection(selector).patch([:])
        }
        // Layer was created but the no-op shouldn't have changed any state.
        let edgesAfter = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edgesAfter, edgesBefore)
        tx.revert()
    }
}
