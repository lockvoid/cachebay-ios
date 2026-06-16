import XCTest
@testable import Cachebay

final class ConnectionEdgeCasesTests: XCTestCase {
    private func makeStack() -> (Graph, Planner, Canonical, Documents) {
        let graph = Graph()
        let planner = Planner()
        let canonical = Canonical(graph: graph)
        let documents = Documents(graph: graph, planner: planner, canonical: canonical)
        return (graph, planner, canonical, documents)
    }

    private let querySource = """
        query Posts($first: Int, $last: Int, $after: String, $before: String) {
            posts(first: $first, last: $last, after: $after, before: $before) @connection(mode: "infinite") {
                pageInfo { startCursor endCursor hasPreviousPage hasNextPage }
                edges { cursor node { id title } }
            }
        }
        """

    private func page(cursors: [(String, String)], startCursor: String?, endCursor: String?, hasPrev: Bool, hasNext: Bool) -> JSONValue {
        let edges: [JSONValue] = cursors.map { (cursor, id) in
            .object([
                "__typename": "PostEdge", "cursor": .string(cursor),
                "node": .object(["__typename": "Post", "id": .string(id), "title": .string(id)]),
            ])
        }
        return .object([
            "posts": .object([
                "__typename": "PostConnection",
                "pageInfo": .object([
                    "__typename": "PageInfo",
                    "startCursor": startCursor.map(JSONValue.string) ?? .null,
                    "endCursor": endCursor.map(JSONValue.string) ?? .null,
                    "hasPreviousPage": .bool(hasPrev),
                    "hasNextPage": .bool(hasNext),
                ]),
                "edges": .array(edges),
            ])
        ])
    }

    func test_prepend_reverse_pagination() throws {
        let (_, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(querySource))

        // Leader page (no cursors).
        docs.normalize(plan: plan, variables: [:], data: page(cursors: [("c3", "p3"), ("c4", "p4")], startCursor: "c3", endCursor: "c4", hasPrev: true, hasNext: false))

        // Prepend via before=c3.
        docs.normalize(plan: plan, variables: ["last": 2, "before": "c3"], data: page(cursors: [("c1", "p1"), ("c2", "p2")], startCursor: "c1", endCursor: "c2", hasPrev: false, hasNext: true))

        let result = docs.materialize(plan: plan, variables: [:])
        let ids = (result.data["posts"]?["edges"]?.array ?? []).compactMap { $0["node"]?["id"]?.string }
        XCTAssertEqual(ids, ["p1", "p2", "p3", "p4"])
        // Boundaries: prefix==0, so hasPreviousPage + startCursor should come from the prepended page.
        XCTAssertEqual(result.data["posts"]?["pageInfo"]?["startCursor"]?.string, "c1")
        XCTAssertEqual(result.data["posts"]?["pageInfo"]?["hasPreviousPage"]?.bool, false)
        // Suffix==0 from leader page, so endCursor+hasNextPage stays with leader's values.
        XCTAssertEqual(result.data["posts"]?["pageInfo"]?["endCursor"]?.string, "c4")
        XCTAssertEqual(result.data["posts"]?["pageInfo"]?["hasNextPage"]?.bool, false)
    }

    /// Relay semantics: `after=cursor` means "everything after this cursor is
    /// exactly what the server returned". An existing item past the cursor is
    /// dropped because the server's ordering is authoritative.
    func test_after_splice_truncates_existing_suffix() throws {
        let (_, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(querySource))
        docs.normalize(plan: plan, variables: [:], data: page(cursors: [("c1", "p1"), ("c2", "p2")], startCursor: "c1", endCursor: "c2", hasPrev: false, hasNext: true))
        // Stale tail-appended out-of-order entry.
        docs.normalize(plan: plan, variables: ["first": 1, "after": "c4"], data: page(cursors: [("c5", "p5")], startCursor: "c5", endCursor: "c5", hasPrev: true, hasNext: false))
        // Authoritative page after c2.
        docs.normalize(plan: plan, variables: ["first": 2, "after": "c2"], data: page(cursors: [("c3", "p3"), ("c4", "p4")], startCursor: "c3", endCursor: "c4", hasPrev: true, hasNext: true))

        let result = docs.materialize(plan: plan, variables: [:])
        let ids = (result.data["posts"]?["edges"]?.array ?? []).compactMap { $0["node"]?["id"]?.string }
        XCTAssertEqual(ids, ["p1", "p2", "p3", "p4"], "Server-authoritative suffix replaces stale p5.")
    }

    func test_pageInfo_shallow_merge_preserves_extras() throws {
        let (_, planner, _, docs) = makeStack()
        let extraSource = """
            query Posts($first: Int, $after: String) {
                posts(first: $first, after: $after) @connection(mode: "infinite") {
                    totalCount
                    pageInfo { endCursor hasNextPage }
                    edges { cursor node { id } }
                }
            }
            """
        let plan = try planner.getPlan(.source(extraSource))
        let data1: JSONValue = .object([
            "posts": .object([
                "__typename": "PostConnection",
                "totalCount": 10,
                "pageInfo": .object(["__typename": "PageInfo", "endCursor": "c2", "hasNextPage": true]),
                "edges": .array([
                    .object(["__typename": "PostEdge", "cursor": "c1", "node": .object(["__typename": "Post", "id": "p1"])]),
                    .object(["__typename": "PostEdge", "cursor": "c2", "node": .object(["__typename": "Post", "id": "p2"])]),
                ]),
            ])
        ])
        docs.normalize(plan: plan, variables: ["first": 2], data: data1)

        // Fetch second page — new totalCount and extended endCursor.
        let data2: JSONValue = .object([
            "posts": .object([
                "__typename": "PostConnection",
                "totalCount": 12,
                "pageInfo": .object(["__typename": "PageInfo", "endCursor": "c4", "hasNextPage": false]),
                "edges": .array([
                    .object(["__typename": "PostEdge", "cursor": "c3", "node": .object(["__typename": "Post", "id": "p3"])]),
                    .object(["__typename": "PostEdge", "cursor": "c4", "node": .object(["__typename": "Post", "id": "p4"])]),
                ]),
            ])
        ])
        docs.normalize(plan: plan, variables: ["first": 2, "after": "c2"], data: data2)

        let result = docs.materialize(plan: plan, variables: ["first": 2, "after": "c2"])
        let posts = result.data["posts"]?.object ?? [:]
        XCTAssertEqual(posts["totalCount"]?.int, 12)
        XCTAssertEqual(posts["pageInfo"]?["endCursor"]?.string, "c4")
        XCTAssertEqual(posts["pageInfo"]?["hasNextPage"]?.bool, false)
    }
}
