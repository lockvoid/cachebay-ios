import XCTest
@testable import Cachebay

/// In v0.7.0, `linkNode` is purely structural — it does NOT write
/// entity-record scalar fields, and `replay()` does NOT reassert
/// optimistic entity scalars on top of a fresh server normalize. Entity
/// records are owned exclusively by `documents.normalize` (auto from
/// queries / mutations / subscriptions) or by explicit
/// `b.writeFragment(...)`. The connection-link primitive only inserts
/// an edge into the canonical's `edges` refList.
///
/// This test pins the post-replay invariant: after a server-cycle
/// normalize that writes new scalars for the same node, the entity
/// holds the SERVER scalars, not optimistic ones — there's no
/// optimistic-entity write to replay because linkNode never made one.
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

    /// linkNode followed by a server-cycle write of the same entity:
    /// the server scalars win because linkNode never touched the entity.
    func test_addNode_doesNotWriteEntityScalars_serverNormalizeIsAuthoritative() throws {
        let client = makeClient()

        // Seed canonical via writeQuery.
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

        // Optimistic linkNode — pure structural, leaves the entity untouched.
        let canonicalKey: CacheKey = "@connection.posts({})"
        let _tx = client.modifyOptimistic { b in
            b.connection(key: canonicalKey).linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p1"),
                ]),
                options: LinkNodeOptions(position: .start)
            )
        }
        // No scalar `title` was written by linkNode.
        XCTAssertNil(client.graph.getField("Post:p1", "title"))

        // Server response writes the same node with `title: ServerTitle`.
        // `writeQuery` triggers `Canonical.updateConnection → optimistic.replay(...)`,
        // but replay only reapplies the connection op (edge insert) — there
        // was no optimistic entity write to reassert.
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

        // The server-normalized scalar is authoritative. linkNode never
        // wrote an optimistic scalar over `title`, so there's nothing to
        // clobber it with on replay.
        XCTAssertEqual(
            client.graph.getField("Post:p1", "title")?.string,
            "ServerTitle",
            "linkNode is structural — entity scalars are owned by documents.normalize, and replay must not reassert anything linkNode never wrote."
        )
        withExtendedLifetime(_tx) {}
    }
}
