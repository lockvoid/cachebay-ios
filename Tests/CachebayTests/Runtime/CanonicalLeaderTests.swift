import XCTest
@testable import Cachebay

/// Web parity for `core/canonical.test.ts` Leader-page tests:
/// creates canonical, resets on leader refetch, copies extras, handles
/// missing pageInfo cursors. Existing iOS suite only had a partial extras
/// test.
final class CanonicalLeaderTests: XCTestCase {

    private func makeStack() -> (Graph, Planner, Canonical, Documents) {
        let graph = Graph()
        let planner = Planner()
        let canonical = Canonical(graph: graph)
        let documents = Documents(graph: graph, planner: planner, canonical: canonical)
        return (graph, planner, canonical, documents)
    }

    private let postsQuery = """
        query Posts($first: Int, $after: String) {
            posts(first: $first, after: $after) @connection(mode: "infinite") {
                __typename
                totalCount
                pageInfo { __typename startCursor endCursor hasPreviousPage hasNextPage }
                edges { __typename cursor node { __typename id title } }
            }
        }
        """

    private func buildConnection(
        ids: [String],
        startCursor: String? = nil,
        endCursor: String? = nil,
        hasPrev: Bool = false,
        hasNext: Bool = false,
        totalCount: Int? = nil
    ) -> JSONValue {
        let edges: [JSONValue] = ids.map { id in
            .object([
                "__typename": "PostEdge",
                "cursor": .string(id),
                "node": .object(["__typename": "Post", "id": .string(id), "title": .string(id)]),
            ])
        }
        var pageInfo: [String: JSONValue] = [
            "__typename": "PageInfo",
            "startCursor": startCursor.map(JSONValue.string) ?? (ids.first.map(JSONValue.string) ?? .null),
            "endCursor": endCursor.map(JSONValue.string) ?? (ids.last.map(JSONValue.string) ?? .null),
            "hasPreviousPage": .bool(hasPrev),
            "hasNextPage": .bool(hasNext),
        ]
        _ = pageInfo  // silence unused warning for some compilers
        var conn: [String: JSONValue] = [
            "__typename": "PostConnection",
            "pageInfo": .object(pageInfo),
            "edges": .array(edges),
        ]
        if let totalCount {
            conn["totalCount"] = .int(Int64(totalCount))
        }
        return .object(["posts": .object(conn)])
    }

    private func canonicalNodeIds(_ graph: Graph, _ canonicalKey: CacheKey) -> [String] {
        let edges = graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        return edges.compactMap { ek in
            guard let nodeRef = graph.getField(ek, "node")?.ref else { return nil }
            return graph.getField(nodeRef, "id")?.string
        }
    }

    // MARK: - leader page creates canonical

    func test_leader_createsCanonicalWithEdgesAndPageInfo() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))

        docs.normalize(
            plan: plan, variables: ["first": 3],
            data: buildConnection(
                ids: ["p1", "p2", "p3"],
                startCursor: "p1", endCursor: "p3", hasPrev: false, hasNext: true
            ))

        let canonicalKey: CacheKey = "@connection.posts({})"
        XCTAssertNotNil(graph.getRecord(canonicalKey))
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["p1", "p2", "p3"])

        let pageInfoKey = "\(canonicalKey).pageInfo"
        XCTAssertEqual(graph.getField(pageInfoKey, "startCursor")?.string, "p1")
        XCTAssertEqual(graph.getField(pageInfoKey, "endCursor")?.string, "p3")
        XCTAssertEqual(graph.getField(pageInfoKey, "hasPreviousPage")?.bool, false)
        XCTAssertEqual(graph.getField(pageInfoKey, "hasNextPage")?.bool, true)
        XCTAssertEqual(graph.getField(canonicalKey, CachebayConstants.connectionPageInfoField)?.ref, pageInfoKey)
    }

    // MARK: - leader refetch resets canonical

    func test_leaderRefetch_resetsCanonical() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        // First leader page + a forward page extends the canonical.
        docs.normalize(
            plan: plan, variables: ["first": 3],
            data: buildConnection(
                ids: ["p1", "p2", "p3"], startCursor: "p1", endCursor: "p3", hasNext: true
            ))
        docs.normalize(
            plan: plan, variables: ["first": 3, "after": "p3"],
            data: buildConnection(
                ids: ["p4", "p5", "p6"], startCursor: "p4", endCursor: "p6", hasPrev: true, hasNext: false
            ))
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["p1", "p2", "p3", "p4", "p5", "p6"])

        // Leader refetch with the same page must reset the canonical to just leader.
        docs.normalize(
            plan: plan, variables: ["first": 3],
            data: buildConnection(
                ids: ["p1", "p2", "p3"], startCursor: "p1", endCursor: "p3", hasNext: true
            ))
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["p1", "p2", "p3"])

        let pageInfoKey = "\(canonicalKey).pageInfo"
        XCTAssertEqual(graph.getField(pageInfoKey, "startCursor")?.string, "p1")
        XCTAssertEqual(graph.getField(pageInfoKey, "endCursor")?.string, "p3")
        XCTAssertEqual(graph.getField(pageInfoKey, "hasNextPage")?.bool, true)
    }

    // MARK: - leader copies extras (connection-level)

    func test_leader_copiesExtraFieldsOntoCanonical() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))

        docs.normalize(
            plan: plan, variables: ["first": 3],
            data: buildConnection(
                ids: ["p1", "p2", "p3"],
                startCursor: "p1", endCursor: "p3", hasNext: true,
                totalCount: 100
            ))

        let canonicalKey: CacheKey = "@connection.posts({})"
        XCTAssertEqual(graph.getField(canonicalKey, "totalCount")?.int, 100)
    }

    // MARK: - leader page with no cursors (only ids) — canonical infers

    func test_leader_pageInfo_missingCursors_inferredFromEdges() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))

        // pageInfo intentionally has only hasNextPage set, no cursors.
        let edges: [JSONValue] = ["p1", "p2", "p3"].map { id in
            .object([
                "__typename": "PostEdge",
                "cursor": .string(id),
                "node": .object(["__typename": "Post", "id": .string(id), "title": .string(id)]),
            ])
        }
        let payload: JSONValue = .object([
            "posts": .object([
                "__typename": "PostConnection",
                "pageInfo": .object([
                    "__typename": "PageInfo",
                    "startCursor": .null,
                    "endCursor": .null,
                    "hasPreviousPage": .bool(false),
                    "hasNextPage": .bool(true),
                ]),
                "edges": .array(edges),
            ])
        ])
        docs.normalize(plan: plan, variables: ["first": 3], data: payload)

        let canonicalKey: CacheKey = "@connection.posts({})"
        let pageInfoKey = "\(canonicalKey).pageInfo"

        // Canonical should fall back to first/last edge cursor.
        XCTAssertEqual(graph.getField(pageInfoKey, "startCursor")?.string, "p1")
        XCTAssertEqual(graph.getField(pageInfoKey, "endCursor")?.string, "p3")
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["p1", "p2", "p3"])
    }
}
