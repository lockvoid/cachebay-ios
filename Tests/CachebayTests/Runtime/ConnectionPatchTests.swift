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

    // MARK: - patch via canonical-key string
    //
    // Web parity: cachebay-web's `o.connection(canonicalKey).patch(...)`
    // updates the connection record exactly like the selector form. This
    // verifies that with an existing canonical (pre-seeded), patch flips
    // pageInfo + connection-level extras when called via canonical-key.

    func test_patch_viaCanonicalKey_updatesPageInfoAndExtras() throws {
        let client = makeClient()
        let key = canonicalKey

        // Pre-seed a canonical with totalCount + populated pageInfo via
        // a write-fragment style — we just write directly to the graph.
        let pageInfoKey: CacheKey = "\(key).pageInfo"
        client.graph.replaceRecord(pageInfoKey, [
            CachebayConstants.typenameField: .string("PageInfo"),
            "endCursor": .string("e1"),
            "hasNextPage": .bool(true),
        ])
        client.graph.replaceRecord(key, [
            CachebayConstants.typenameField: .string("PostConnection"),
            CachebayConstants.connectionEdgesField: .refList([]),
            CachebayConstants.connectionPageInfoField: .ref(pageInfoKey),
            "totalCount": .int(1),
        ])
        client.graph.flush()

        client.modifyOptimistic { b, _ in
            let c = b.connection(key: key)
            c.patch([
                "totalCount": .int(2),
                "pageInfo": .object([
                    "startCursor": .string("s1"),
                    "hasNextPage": .bool(false),
                ]),
            ])
        }.commit(nil)

        XCTAssertEqual(client.graph.getField(key, "totalCount")?.int, 2)
        XCTAssertEqual(client.graph.getField(pageInfoKey, "endCursor")?.string, "e1",
            "endCursor must survive a partial pageInfo patch")
        XCTAssertEqual(client.graph.getField(pageInfoKey, "startCursor")?.string, "s1")
        XCTAssertEqual(client.graph.getField(pageInfoKey, "hasNextPage")?.bool, false)
    }

    // MARK: - closure-builder form (web `optimistic.test.ts:481`)
    //
    // Web supports `c.patch(prev => ({...}))` where the closure
    // receives the current canonical snapshot and returns the patch
    // dict. Use case: `prev => ({ totalCount: prev.totalCount + 1 })`
    // — read-modify-write where the optimistic delta depends on the
    // latest cached value (e.g. atomic-ish increments).

    func test_patch_closureForm_readModifyWriteOnCanonicalScalar() throws {
        let client = makeClient()
        seed(client)
        XCTAssertEqual(client.graph.getField(canonicalKey, "totalCount")?.int, 42)

        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        client.modifyOptimistic { b, _ in
            b.connection(selector).patch { prev in
                let current = prev["totalCount"]?.int ?? 0
                return ["totalCount": .int(current + 1)]
            }
        }.commit(nil)

        XCTAssertEqual(client.graph.getField(canonicalKey, "totalCount")?.int, 43,
                       "closure form must read prev.totalCount and increment by 1")
    }

    /// Box holding the closure's `prev` snapshot for assertion across
    /// the @Sendable boundary. Local to this test.
    private final class PrevBox: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: [String: JSONValue]?
        func capture(_ v: [String: JSONValue]) { lock.lock(); snapshot = v; lock.unlock() }
        var value: [String: JSONValue]? { lock.lock(); defer { lock.unlock() }; return snapshot }
    }

    func test_patch_closureForm_seesEmptyDictWhenCanonicalAbsent() throws {
        let client = makeClient()
        // Don't seed — canonical doesn't exist yet.
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        let box = PrevBox()
        client.modifyOptimistic { b, _ in
            b.connection(selector).patch { prev in
                box.capture(prev)
                return [:] // no-op patch
            }
        }.commit(nil)

        let captured = try XCTUnwrap(box.value, "closure must run at least once")
        XCTAssertTrue(captured.isEmpty, "closure must receive empty dict for absent canonical, got \(captured)")
    }

    func test_patch_closureForm_emptyReturn_isNoOp() throws {
        let client = makeClient()
        seed(client)
        let edgesBefore = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []

        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")
        client.modifyOptimistic { b, _ in
            b.connection(selector).patch { _ in [:] }
        }.commit(nil)

        let edgesAfter = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edgesAfter, edgesBefore, "empty closure return must be a no-op")
    }
}
