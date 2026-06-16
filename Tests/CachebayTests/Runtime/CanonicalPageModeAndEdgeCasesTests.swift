import XCTest
@testable import Cachebay

/// Web parity for the remaining `core/canonical.test.ts` blocks:
///   - Page mode (`@connection(mode: "page")`) — replaces canonical
///     wholesale on each fetch.
///   - Edge cases — empty page, missing pageInfo, null edges, missing
///     node refs in edges, complete refetch with different data.
final class CanonicalPageModeAndEdgeCasesTests: XCTestCase {

    private func makeStack() -> (Graph, Planner, Canonical, Documents) {
        let graph = Graph()
        let planner = Planner()
        let canonical = Canonical(graph: graph)
        let documents = Documents(graph: graph, planner: planner, canonical: canonical)
        return (graph, planner, canonical, documents)
    }

    private let tagsQueryPage = """
        query Tags($first: Int, $after: String) {
            tags(first: $first, after: $after) @connection(mode: "page") {
                __typename
                totalCount
                pageInfo { __typename startCursor endCursor hasPreviousPage hasNextPage }
                edges { __typename cursor node { __typename id name } }
            }
        }
        """

    private let postsQuery = """
        query Posts($first: Int, $after: String) {
            posts(first: $first, after: $after) @connection(mode: "infinite") {
                __typename
                pageInfo { __typename startCursor endCursor hasPreviousPage hasNextPage }
                edges { __typename cursor node { __typename id title } }
            }
        }
        """

    private func buildTags(
        ids: [String],
        startCursor: String? = nil,
        endCursor: String? = nil,
        hasNext: Bool = false,
        totalCount: Int? = nil
    ) -> JSONValue {
        let edges: [JSONValue] = ids.map { id in
            .object([
                "__typename": "TagEdge",
                "cursor": .string(id),
                "node": .object(["__typename": "Tag", "id": .string(id), "name": .string(id)]),
            ])
        }
        var conn: [String: JSONValue] = [
            "__typename": "TagConnection",
            "pageInfo": .object([
                "__typename": "PageInfo",
                "startCursor": startCursor.map(JSONValue.string) ?? (ids.first.map(JSONValue.string) ?? .null),
                "endCursor": endCursor.map(JSONValue.string) ?? (ids.last.map(JSONValue.string) ?? .null),
                "hasPreviousPage": .bool(false),
                "hasNextPage": .bool(hasNext),
            ]),
            "edges": .array(edges),
        ]
        if let totalCount {
            conn["totalCount"] = .int(Int64(totalCount))
        }
        return .object(["tags": .object(conn)])
    }

    private func canonicalNodeIds(_ graph: Graph, _ canonicalKey: CacheKey) -> [String] {
        let edges = graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        return edges.compactMap { ek in
            guard let nodeRef = graph.getField(ek, "node")?.ref else { return nil }
            return graph.getField(nodeRef, "id")?.string
        }
    }

    // MARK: - Page mode

    func test_pageMode_replacesCanonicalWithSnapshot() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(tagsQueryPage))

        docs.normalize(
            plan: plan, variables: ["first": 10],
            data: buildTags(
                ids: ["t1", "t2", "t3"], startCursor: "t1", endCursor: "t3", hasNext: false, totalCount: 3
            ))

        let canonicalKey: CacheKey = "@connection.tags({})"
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["t1", "t2", "t3"])
        XCTAssertEqual(graph.getField(canonicalKey, "totalCount")?.int, 3)
        XCTAssertEqual(graph.getField(canonicalKey, CachebayConstants.connectionPageInfoField)?.ref, "\(canonicalKey).pageInfo")

        let pageInfoKey = "\(canonicalKey).pageInfo"
        XCTAssertEqual(graph.getField(pageInfoKey, "startCursor")?.string, "t1")
        XCTAssertEqual(graph.getField(pageInfoKey, "endCursor")?.string, "t3")
        XCTAssertEqual(graph.getField(pageInfoKey, "hasNextPage")?.bool, false)
    }

    func test_pageMode_replacesCanonical_onEachUpdate() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(tagsQueryPage))
        let canonicalKey: CacheKey = "@connection.tags({})"

        docs.normalize(
            plan: plan, variables: ["first": 10],
            data: buildTags(
                ids: ["t1", "t2"], hasNext: true
            ))
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["t1", "t2"])

        // Page-mode second fetch must REPLACE — not append.
        docs.normalize(
            plan: plan, variables: ["first": 10, "after": "t2"],
            data: buildTags(
                ids: ["t3", "t4", "t5"], hasNext: false
            ))
        XCTAssertEqual(
            canonicalNodeIds(graph, canonicalKey), ["t3", "t4", "t5"],
            "page mode replaces canonical with the latest page snapshot, no merging")
    }

    func test_pageMode_preservesExtras() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(tagsQueryPage))
        let canonicalKey: CacheKey = "@connection.tags({})"

        docs.normalize(
            plan: plan, variables: ["first": 10],
            data: buildTags(
                ids: ["t1"], hasNext: false, totalCount: 1
            ))
        XCTAssertEqual(graph.getField(canonicalKey, "totalCount")?.int, 1)

        docs.normalize(
            plan: plan, variables: ["first": 10],
            data: buildTags(
                ids: ["t1", "t2"], hasNext: false, totalCount: 2
            ))
        XCTAssertEqual(graph.getField(canonicalKey, "totalCount")?.int, 2)
    }

    // MARK: - Edge cases

    func test_emptyPage_handledGracefully() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        let payload: JSONValue = .object([
            "posts": .object([
                "__typename": "PostConnection",
                "pageInfo": .object([
                    "__typename": "PageInfo",
                    "startCursor": .null,
                    "endCursor": .null,
                    "hasPreviousPage": .bool(false),
                    "hasNextPage": .bool(false),
                ]),
                "edges": .array([]),
            ])
        ])
        docs.normalize(plan: plan, variables: ["first": 3], data: payload)

        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), [])
        XCTAssertNotNil(graph.getRecord(canonicalKey))
        XCTAssertEqual(graph.getField(canonicalKey, CachebayConstants.connectionPageInfoField)?.ref, "\(canonicalKey).pageInfo")
    }

    func test_canonicalRecord_createdOnFirstUpdate() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        XCTAssertNil(graph.getRecord(canonicalKey), "canonical must not exist before first update")

        let edges: [JSONValue] = [
            .object([
                "__typename": "PostEdge",
                "cursor": .string("p1"),
                "node": .object(["__typename": "Post", "id": .string("p1"), "title": .string("p1")]),
            ])
        ]
        let payload: JSONValue = .object([
            "posts": .object([
                "__typename": "PostConnection",
                "pageInfo": .object([
                    "__typename": "PageInfo",
                    "startCursor": .null,
                    "endCursor": .null,
                    "hasPreviousPage": .bool(false),
                    "hasNextPage": .bool(false),
                ]),
                "edges": .array(edges),
            ])
        ])
        docs.normalize(plan: plan, variables: ["first": 3], data: payload)

        XCTAssertNotNil(graph.getRecord(canonicalKey))
        XCTAssertEqual(graph.getField(canonicalKey, CachebayConstants.typenameField)?.string, "PostConnection")
        XCTAssertNotNil(graph.getRecord("\(canonicalKey).pageInfo"))
    }

    func test_refetchWithCompletelyDifferentData_replacesLeader() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        let firstEdges: [JSONValue] = ["p1", "p2", "p3"].map { id in
            .object([
                "__typename": "PostEdge",
                "cursor": .string(id),
                "node": .object(["__typename": "Post", "id": .string(id), "title": .string(id)]),
            ])
        }
        docs.normalize(
            plan: plan, variables: ["first": 3],
            data: .object([
                "posts": .object([
                    "__typename": "PostConnection",
                    "pageInfo": .object([
                        "__typename": "PageInfo",
                        "startCursor": .null, "endCursor": .null,
                        "hasPreviousPage": .bool(false), "hasNextPage": .bool(false),
                    ]),
                    "edges": .array(firstEdges),
                ])
            ]))
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["p1", "p2", "p3"])

        // Refetch leader (no after) — completely different IDs replace canonical.
        let secondEdges: [JSONValue] = ["p100", "p101"].map { id in
            .object([
                "__typename": "PostEdge",
                "cursor": .string(id),
                "node": .object(["__typename": "Post", "id": .string(id), "title": .string(id)]),
            ])
        }
        docs.normalize(
            plan: plan, variables: ["first": 3],
            data: .object([
                "posts": .object([
                    "__typename": "PostConnection",
                    "pageInfo": .object([
                        "__typename": "PageInfo",
                        "startCursor": .null, "endCursor": .null,
                        "hasPreviousPage": .bool(false), "hasNextPage": .bool(true),
                    ]),
                    "edges": .array(secondEdges),
                ])
            ]))
        XCTAssertEqual(
            canonicalNodeIds(graph, canonicalKey), ["p100", "p101"],
            "leader refetch with new ids must replace canonical")
    }

    // MARK: - null edges array
    //
    // Web parity: a normalized page can come in with `edges: null` —
    // canonical must treat it like an empty edges list and not crash.

    func test_nullEdgesArray_treatedAsEmpty() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        // edges: null → defaults to empty refList.
        let payload: JSONValue = .object([
            "posts": .object([
                "__typename": "PostConnection",
                "pageInfo": .object([
                    "__typename": "PageInfo",
                    "startCursor": .null,
                    "endCursor": .null,
                    "hasPreviousPage": .bool(false),
                    "hasNextPage": .bool(false),
                ]),
                "edges": .null,
            ])
        ])
        docs.normalize(plan: plan, variables: ["first": 3], data: payload)

        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), [])
        XCTAssertNotNil(graph.getRecord(canonicalKey))
    }

    // MARK: - missing node ref in edge
    //
    // Web parity: an edge that lacks `node` is silently skipped — canonical
    // includes only edges whose node ref resolves.

    func test_missingNodeRefInEdge_skipsThatEdge() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        // Edge 0 has a node, edge 1 has no node ref.
        let payload: JSONValue = .object([
            "posts": .object([
                "__typename": "PostConnection",
                "pageInfo": .object([
                    "__typename": "PageInfo",
                    "startCursor": .string("c1"),
                    "endCursor": .string("c2"),
                    "hasPreviousPage": .bool(false),
                    "hasNextPage": .bool(false),
                ]),
                "edges": .array([
                    .object([
                        "__typename": "PostEdge",
                        "cursor": .string("c1"),
                        "node": .object(["__typename": "Post", "id": .string("p1"), "title": .string("p1")]),
                    ]),
                    // No `node` field at all on this edge.
                    .object([
                        "__typename": "PostEdge",
                        "cursor": .string("c2"),
                    ]),
                ]),
            ])
        ])
        docs.normalize(plan: plan, variables: ["first": 2], data: payload)

        // Only the edge with a node ref shows up.
        XCTAssertEqual(
            canonicalNodeIds(graph, canonicalKey), ["p1"],
            "edges without a node ref must be skipped silently")
    }

    func test_pageInfo_hasPreviousPage_nullCoercedToFalse() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        // Server sends `hasPreviousPage: null` — must coerce to false on canonical
        // (web parity: `!!hasPreviousPage`).
        let edges: [JSONValue] = ["p1"].map { id in
            .object([
                "__typename": "PostEdge",
                "cursor": .string(id),
                "node": .object(["__typename": "Post", "id": .string(id), "title": .string(id)]),
            ])
        }
        docs.normalize(
            plan: plan, variables: ["first": 1],
            data: .object([
                "posts": .object([
                    "__typename": "PostConnection",
                    "pageInfo": .object([
                        "__typename": "PageInfo",
                        "startCursor": .string("p1"),
                        "endCursor": .string("p1"),
                        "hasPreviousPage": .null,
                        "hasNextPage": .null,
                    ]),
                    "edges": .array(edges),
                ])
            ]))

        let pageInfoKey = "\(canonicalKey).pageInfo"
        XCTAssertEqual(
            graph.getField(pageInfoKey, "hasPreviousPage")?.bool, false,
            "web coerces hasPreviousPage:null → false")
        XCTAssertEqual(
            graph.getField(pageInfoKey, "hasNextPage")?.bool, false,
            "web coerces hasNextPage:null → false")
    }
}
