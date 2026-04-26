import XCTest
@testable import Cachebay

final class CompilerTests: XCTestCase {
    func test_compile_simple_query() throws {
        let plan = try Compiler.compilePlan(source: """
        query Foo($id: ID!) {
            post(id: $id) {
                id
                title
            }
        }
        """)
        XCTAssertEqual(plan.operation, .query)
        XCTAssertEqual(plan.rootTypename, "Query")
        XCTAssertEqual(plan.root.count, 1)
        let postField = plan.root[0]
        XCTAssertEqual(postField.fieldName, "post")
        XCTAssertEqual(postField.expectedArgNames, ["id"])
        let children = postField.selectionSet ?? []
        // __typename injected, plus id + title
        XCTAssertEqual(children.count, 3)
        XCTAssertTrue(children.contains { $0.fieldName == CachebayConstants.typenameField })
        XCTAssertTrue(children.contains { $0.fieldName == "id" })
        XCTAssertTrue(children.contains { $0.fieldName == "title" })
    }

    func test_compile_with_connection_directive() throws {
        let plan = try Compiler.compilePlan(source: """
        query Posts($category: String, $first: Int, $after: String) {
            posts(category: $category, first: $first, after: $after)
                @connection(mode: "infinite", filters: ["category"]) {
                pageInfo { endCursor hasNextPage }
                edges { cursor node { id title } }
            }
        }
        """)
        XCTAssertEqual(plan.root.count, 1)
        let posts = plan.root[0]
        XCTAssertTrue(posts.isConnection)
        XCTAssertEqual(posts.connectionMode, .infinite)
        XCTAssertEqual(posts.connectionFilters, ["category"])
        XCTAssertEqual(Set(posts.pageArgs ?? []), Set(["first", "after"]))

        // Network query should strip @connection
        XCTAssertFalse(plan.networkQuery.contains("@connection"))
        // And inject __typename recursively
        XCTAssertTrue(plan.networkQuery.contains("__typename"))
    }

    func test_var_masks() throws {
        let plan = try Compiler.compilePlan(source: """
        query Posts($category: String, $first: Int, $after: String) {
            posts(category: $category, first: $first, after: $after)
                @connection(filters: ["category"]) {
                edges { node { id } }
            }
        }
        """)
        XCTAssertEqual(Set(plan.varMask.strict), Set(["category", "first", "after"]))
        XCTAssertEqual(Set(plan.varMask.canonical), Set(["category"]))
        XCTAssertEqual(plan.windowArgs, Set(["first", "after"]))
    }

    func test_stable_id() throws {
        let a = try Compiler.compilePlan(source: "query X { a { id } b { id } }")
        let b = try Compiler.compilePlan(source: "query X { b { id } a { id } }")
        // Order-insensitive fingerprint
        XCTAssertEqual(a.id, b.id)
    }

    func test_connection_canonical_key() throws {
        let plan = try Compiler.compilePlan(source: """
        query Posts($category: String, $first: Int, $after: String) {
            posts(category: $category, first: $first, after: $after)
                @connection(filters: ["category"]) {
                edges { node { id } }
            }
        }
        """)
        let field = plan.root[0]
        let vars: [String: JSONValue] = ["category": "tech", "first": 10, "after": "c2"]
        let canonical = Keys.buildConnectionCanonicalKey(field: field, parentId: CachebayConstants.rootID, variables: vars)
        XCTAssertEqual(canonical, "@connection.posts({\"category\":\"tech\"})")

        let page = Keys.buildConnectionKey(field: field, parentId: CachebayConstants.rootID, variables: vars)
        XCTAssertTrue(page.hasPrefix("@.posts("))
        XCTAssertTrue(page.contains("\"category\":\"tech\""))
        XCTAssertTrue(page.contains("\"first\":10"))
    }

    func test_fragment_compile() throws {
        let plan = try Compiler.compilePlan(source: """
        fragment PostFields on Post {
            id
            title
            author { id name }
        }
        """)
        XCTAssertEqual(plan.operation, .fragment)
        XCTAssertEqual(plan.rootTypename, "Post")
        // __typename is injected at the fragment root
        XCTAssertTrue(plan.root.contains { $0.fieldName == CachebayConstants.typenameField })
    }
}
