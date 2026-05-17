import XCTest
@testable import Cachebay

/// **Web parity.** `cachebay-web`'s optimistic `insertEdge` and
/// `removeEdge` maintain `::cursorIndex` (cursor → position) alongside
/// `::nodeIndex` (node → edge). After an optimistic add/remove, the
/// cursor index reflects the new layout — `addCursorToIndex` +
/// `shiftCursorIndicesAfter` for inserts, `removeCursorFromIndex` +
/// `shiftCursorIndicesAfter(_, -1)` for removes.
///
/// The iOS port previously updated only `::nodeIndex` (via
/// `ConnectionIndex.insert`/`.remove`) and left `::cursorIndex` stale.
/// The next paginate-after-cursor call uses `findCursorIndex` to splice
/// at a specific position; with stale indices, it splices at the wrong
/// slot — pages get appended in the middle of the list, dedup misses,
/// and the canonical edges array decays.
final class OptimisticCursorIndexTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    private let connectionQuery = """
    query Posts {
        posts @connection(mode: "infinite") {
            __typename
            pageInfo { __typename hasNextPage }
            edges {
                __typename
                cursor
                node { __typename id title }
            }
        }
    }
    """

    private let canonicalKey: CacheKey = "@connection.posts({})"

    /// Reads the `::cursorIndex` aux record as a `[cursor: position]`
    /// dict for assertion.
    private func cursorIndex(_ client: CachebayClient) -> [String: Int] {
        let key: CacheKey = "\(canonicalKey)::cursorIndex"
        guard let rec = client.graph.getRecord(key) else { return [:] }
        var out: [String: Int] = [:]
        for (k, v) in rec {
            if case .int(let i) = v { out[k] = Int(i) }
        }
        return out
    }

    /// Seed the canonical with two edges (c1, c2) so the cursor index
    /// has known starting values: `{c1: 0, c2: 1}`.
    private func seedTwoEdges(_ client: CachebayClient) throws {
        try client.writeQuery(query: connectionQuery, variables: [:], data: .object([
            "posts": .object([
                "__typename": .string("PostConnection"),
                "pageInfo": .object([
                    "__typename": .string("PageInfo"),
                    "hasNextPage": .bool(false),
                ]),
                "edges": .array([
                    .object([
                        "__typename": .string("PostEdge"),
                        "cursor": .string("c1"),
                        "node": .object([
                            "__typename": .string("Post"),
                            "id": .string("p1"),
                            "title": .string("First"),
                        ]),
                    ]),
                    .object([
                        "__typename": .string("PostEdge"),
                        "cursor": .string("c2"),
                        "node": .object([
                            "__typename": .string("Post"),
                            "id": .string("p2"),
                            "title": .string("Second"),
                        ]),
                    ]),
                ]),
            ])
        ]))
    }

    func test_insertEdge_at_start_shifts_existing_cursor_indices_and_inserts_new() throws {
        let client = makeClient()
        try seedTwoEdges(client)

        XCTAssertEqual(cursorIndex(client), ["c1": 0, "c2": 1])

        // Capture local copies so the @Sendable closure doesn't capture
        // `self`.
        let key = canonicalKey
        client.modifyOptimistic { b in
            b.connection(key: key).linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p0"),
                ]),
                options: LinkNodeOptions(position: .start, edge: ["cursor": .string("c0")])
            )
        }.dispose()

        // After prepend at index 0:
        // - new entry: c0 → 0
        // - existing entries shifted by +1: c1 → 1, c2 → 2
        XCTAssertEqual(
            cursorIndex(client), ["c0": 0, "c1": 1, "c2": 2],
            "optimistic prepend must shift existing cursor positions and insert the new cursor — matches cachebay-web's `shiftCursorIndicesAfter` + `addCursorToIndex`"
        )
    }

    func test_removeEdge_decrements_subsequent_cursor_indices() throws {
        let client = makeClient()
        try seedTwoEdges(client)

        XCTAssertEqual(cursorIndex(client), ["c1": 0, "c2": 1])

        // Optimistic remove of p1 (at position 0).
        let key = canonicalKey
        client.modifyOptimistic { b in
            b.connection(key: key).unlinkNode(.key("Post:p1"))
        }.dispose()

        // After remove at index 0:
        // - c1 dropped from index
        // - c2 shifts from 1 to 0
        XCTAssertEqual(
            cursorIndex(client), ["c2": 0],
            "optimistic remove must drop the removed cursor and shift subsequent positions — matches cachebay-web's `removeCursorFromIndex` + `shiftCursorIndicesAfter(_, -1)`"
        )
    }
}
