import XCTest
@testable import Cachebay

final class NormalizeMaterializeTests: XCTestCase {
    private func makeStack() -> (Graph, Planner, Canonical, Documents) {
        let graph = Graph()
        let planner = Planner()
        let canonical = Canonical(graph: graph)
        let documents = Documents(graph: graph, planner: planner, canonical: canonical)
        return (graph, planner, canonical, documents)
    }

    func test_simple_entity_roundtrip() throws {
        let (_, planner, _, documents) = makeStack()
        let plan = try planner.getPlan(
            .source(
                """
                query Q($id: ID!) {
                    post(id: $id) {
                        id
                        title
                    }
                }
                """))
        let data: JSONValue = .object([
            "post": .object([
                "__typename": "Post",
                "id": "p1",
                "title": "Hello",
            ])
        ])
        documents.normalize(plan: plan, variables: ["id": "p1"], data: data)

        let result = documents.materialize(plan: plan, variables: ["id": "p1"])
        XCTAssertEqual(result.source, .canonical)
        XCTAssertTrue(result.canonicalOK)
        let obj = result.data.object ?? [:]
        let post = obj["post"]?.object ?? [:]
        XCTAssertEqual(post["id"]?.string, "p1")
        XCTAssertEqual(post["title"]?.string, "Hello")
        XCTAssertEqual(post["__typename"]?.string, "Post")
    }

    func test_array_of_entities() throws {
        let (_, planner, _, documents) = makeStack()
        let plan = try planner.getPlan(
            .source(
                """
                query Q {
                    posts {
                        id
                        title
                    }
                }
                """))
        let data: JSONValue = .object([
            "posts": .array([
                .object(["__typename": "Post", "id": "p1", "title": "A"]),
                .object(["__typename": "Post", "id": "p2", "title": "B"]),
            ])
        ])
        documents.normalize(plan: plan, variables: [:], data: data)

        let result = documents.materialize(plan: plan, variables: [:])
        XCTAssertEqual(result.source, .canonical)
        let posts = result.data["posts"]?.array ?? []
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0]["id"]?.string, "p1")
        XCTAssertEqual(posts[1]["id"]?.string, "p2")
    }

    func test_connection_infinite_first_page() throws {
        let (_, planner, _, documents) = makeStack()
        let plan = try planner.getPlan(
            .source(
                """
                query Posts($first: Int, $after: String) {
                    posts(first: $first, after: $after) @connection(mode: "infinite") {
                        pageInfo { endCursor hasNextPage }
                        edges { cursor node { id title } }
                    }
                }
                """))
        let vars: [String: JSONValue] = ["first": 2, "after": .null]
        let data: JSONValue = .object([
            "posts": .object([
                "__typename": "PostConnection",
                "pageInfo": .object([
                    "__typename": "PageInfo",
                    "endCursor": "c2",
                    "hasNextPage": true,
                ]),
                "edges": .array([
                    .object([
                        "__typename": "PostEdge",
                        "cursor": "c1",
                        "node": .object(["__typename": "Post", "id": "p1", "title": "A"]),
                    ]),
                    .object([
                        "__typename": "PostEdge",
                        "cursor": "c2",
                        "node": .object(["__typename": "Post", "id": "p2", "title": "B"]),
                    ]),
                ]),
            ])
        ])
        documents.normalize(plan: plan, variables: vars, data: data)

        let result = documents.materialize(plan: plan, variables: vars)
        XCTAssertEqual(result.source, .canonical)
        let posts = result.data["posts"]?.object ?? [:]
        let edges = posts["edges"]?.array ?? []
        XCTAssertEqual(edges.count, 2)
        XCTAssertEqual(edges[0]["cursor"]?.string, "c1")
        XCTAssertEqual(edges[0]["node"]?["title"]?.string, "A")
        XCTAssertEqual(edges[1]["node"]?["id"]?.string, "p2")

        let pi = posts["pageInfo"]?.object ?? [:]
        XCTAssertEqual(pi["endCursor"]?.string, "c2")
        XCTAssertEqual(pi["hasNextPage"]?.bool, true)
    }

    func test_connection_infinite_append_next_page_dedup() throws {
        let (_, planner, _, documents) = makeStack()
        let plan = try planner.getPlan(
            .source(
                """
                query Posts($first: Int, $after: String) {
                    posts(first: $first, after: $after) @connection(mode: "infinite") {
                        pageInfo { endCursor hasNextPage }
                        edges { cursor node { id title } }
                    }
                }
                """))
        let firstVars: [String: JSONValue] = ["first": 2, "after": .null]
        let firstData: JSONValue = .object([
            "posts": .object([
                "__typename": "PostConnection",
                "pageInfo": .object(["__typename": "PageInfo", "endCursor": "c2", "hasNextPage": true]),
                "edges": .array([
                    .object(["__typename": "PostEdge", "cursor": "c1", "node": .object(["__typename": "Post", "id": "p1", "title": "A"])]),
                    .object(["__typename": "PostEdge", "cursor": "c2", "node": .object(["__typename": "Post", "id": "p2", "title": "B"])]),
                ]),
            ])
        ])
        documents.normalize(plan: plan, variables: firstVars, data: firstData)

        let secondVars: [String: JSONValue] = ["first": 2, "after": "c2"]
        let secondData: JSONValue = .object([
            "posts": .object([
                "__typename": "PostConnection",
                "pageInfo": .object(["__typename": "PageInfo", "endCursor": "c4", "hasNextPage": false]),
                "edges": .array([
                    // c2 duplicate should be de-duped, edge meta refreshed in place.
                    .object(["__typename": "PostEdge", "cursor": "c2", "node": .object(["__typename": "Post", "id": "p2", "title": "B-updated"])]),
                    .object(["__typename": "PostEdge", "cursor": "c3", "node": .object(["__typename": "Post", "id": "p3", "title": "C"])]),
                    .object(["__typename": "PostEdge", "cursor": "c4", "node": .object(["__typename": "Post", "id": "p4", "title": "D"])]),
                ]),
            ])
        ])
        documents.normalize(plan: plan, variables: secondVars, data: secondData)

        let result = documents.materialize(plan: plan, variables: secondVars)
        let posts = result.data["posts"]?.object ?? [:]
        let edges = posts["edges"]?.array ?? []
        XCTAssertEqual(edges.count, 4, "Expected p1,p2,p3,p4 after dedup (no duplicate p2).")
        XCTAssertEqual(edges[0]["node"]?["id"]?.string, "p1")
        XCTAssertEqual(edges[1]["node"]?["id"]?.string, "p2")
        XCTAssertEqual(edges[2]["node"]?["id"]?.string, "p3")
        XCTAssertEqual(edges[3]["node"]?["id"]?.string, "p4")
        // p2 title should be updated (merged into entity).
        XCTAssertEqual(edges[1]["node"]?["title"]?.string, "B-updated")

        let pi = posts["pageInfo"]?.object ?? [:]
        XCTAssertEqual(pi["endCursor"]?.string, "c4")
        XCTAssertEqual(pi["hasNextPage"]?.bool, false)
    }

    func test_connection_page_mode_replace() throws {
        let (_, planner, _, documents) = makeStack()
        let plan = try planner.getPlan(
            .source(
                """
                query Posts($first: Int, $after: String) {
                    posts(first: $first, after: $after) @connection(mode: "page") {
                        pageInfo { endCursor hasNextPage }
                        edges { cursor node { id title } }
                    }
                }
                """))
        let vars1: [String: JSONValue] = ["first": 2, "after": .null]
        documents.normalize(
            plan: plan, variables: vars1,
            data: .object([
                "posts": .object([
                    "__typename": "PostConnection",
                    "pageInfo": .object(["__typename": "PageInfo", "endCursor": "c2", "hasNextPage": true]),
                    "edges": .array([
                        .object(["__typename": "PostEdge", "cursor": "c1", "node": .object(["__typename": "Post", "id": "p1", "title": "A"])]),
                        .object(["__typename": "PostEdge", "cursor": "c2", "node": .object(["__typename": "Post", "id": "p2", "title": "B"])]),
                    ]),
                ])
            ]))

        let vars2: [String: JSONValue] = ["first": 2, "after": "c2"]
        documents.normalize(
            plan: plan, variables: vars2,
            data: .object([
                "posts": .object([
                    "__typename": "PostConnection",
                    "pageInfo": .object(["__typename": "PageInfo", "endCursor": "c4", "hasNextPage": false]),
                    "edges": .array([
                        .object(["__typename": "PostEdge", "cursor": "c3", "node": .object(["__typename": "Post", "id": "p3", "title": "C"])]),
                        .object(["__typename": "PostEdge", "cursor": "c4", "node": .object(["__typename": "Post", "id": "p4", "title": "D"])]),
                    ]),
                ])
            ]))

        let result = documents.materialize(plan: plan, variables: vars2)
        let edges = result.data["posts"]?["edges"]?.array ?? []
        XCTAssertEqual(edges.count, 2, "Page mode replaces the canonical window")
        XCTAssertEqual(edges[0]["node"]?["id"]?.string, "p3")
        XCTAssertEqual(edges[1]["node"]?["id"]?.string, "p4")
    }

    func test_cache_miss_returns_none() throws {
        let (_, planner, _, documents) = makeStack()
        let plan = try planner.getPlan(.source("query Q { me { id name } }"))
        let result = documents.materialize(plan: plan, variables: [:])
        XCTAssertEqual(result.source, .none)
    }
}
