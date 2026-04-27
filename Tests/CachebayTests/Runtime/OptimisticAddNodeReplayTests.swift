import XCTest
@testable import Cachebay

/// **Web parity.** `cachebay-web`'s `addNode` records an `ENTITY_WRITE`
/// op on the optimistic layer in addition to the connection op (see
/// `core/optimistic.ts`: `ensureEntity` → entityOps push). The
/// connection op alone wires the new edge into the canonical's edge
/// list; the entity op is what reasserts the optimistic node fields
/// after `replay()` runs (e.g. when a canonical merger fires after a
/// pagination response).
///
/// The iOS port's `addNode` writes the entity directly via
/// `optimistic.graph.putRecord(entityKey, node)` and does NOT push an
/// `EntityOp` — so `replay(connectionKeys:)` reapplies the connection
/// op but the entity record is whatever the latest writer (e.g. a
/// network response that returned a different shape for the same id)
/// left in the graph. Optimistic-only fields on the inserted node get
/// clobbered after any pagination merge.
final class OptimisticAddNodeReplayTests: XCTestCase {

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

    /// Optimistic node fields must survive a subsequent normalize that
    /// targets the same canonical (which triggers `replay()` via
    /// `canonical.updateConnection`).
    func test_addNode_entityFields_survive_canonicalMergerReplay() throws {
        let client = makeClient()

        // First: seed via writeQuery so the canonical exists.
        try client.writeQuery(query: connectionQuery, variables: [:], data: .object([
            "posts": .object([
                "__typename": .string("PostConnection"),
                "edges": .array([]),
                "pageInfo": .object([
                    "__typename": .string("PageInfo"),
                    "hasNextPage": .bool(false),
                ]),
            ])
        ]))

        // Optimistic addNode with a node that has a unique optimistic-
        // only title. The transaction stays open (no commit/revert) so
        // its layer remains pending.
        let canonicalKey: CacheKey = "@connection.posts({})"
        _ = client.modifyOptimistic { b, _ in
            b.connection(key: canonicalKey).addNode(
                [
                    "__typename": .string("Post"),
                    "id": .string("p1"),
                    "title": .string("OptimisticTitle"),
                ],
                options: AddNodeOptions(position: .start)
            )
        }
        // Optimistic write landed.
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "OptimisticTitle")

        // Now: a server response writes the same node with a DIFFERENT
        // title via the same connection. `writeQuery` triggers
        // `Canonical.updateConnection → optimistic.replay(...)`. The
        // optimistic layer is still pending, so its ops should reapply
        // and restore the optimistic fields.
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
                            "title": .string("ServerTitle"),
                        ]),
                    ]),
                ]),
            ])
        ]))

        // Web parity: replay reasserts the optimistic entity write, so
        // `Post:p1.title` is `OptimisticTitle` again. iOS port (before
        // the fix) keeps `ServerTitle` because the entity write was
        // never recorded as a layer op.
        XCTAssertEqual(
            client.graph.getField("Post:p1", "title")?.string,
            "OptimisticTitle",
            "After a canonical merger triggers `replay()`, the optimistic entity write must be reasserted. iOS port previously did `graph.putRecord` directly without recording an `EntityOp` on the layer, so `replay(connectionKeys:)` only re-applied the edge insertion — the entity record was left at whatever the latest writer left in graph (here: `ServerTitle`)."
        )
    }
}
