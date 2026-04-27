import XCTest
@testable import Cachebay

/// Port of `cachebay-web/test/unit/compiler/compile-fragments.test.ts`.
final class CompileFragmentsTests: XCTestCase {

    func test_compile_simple_user_fragment_no_args_with_selectionMap() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.userFragment)

        XCTAssertEqual(plan.operation, .fragment)
        XCTAssertEqual(plan.rootTypename, "User")
        XCTAssertFalse(plan.root.isEmpty)

        XCTAssertEqual(plan.rootSelectionMap["id"]?.fieldName, "id")
        XCTAssertEqual(plan.rootSelectionMap["email"]?.fieldName, "email")

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_includes_typename_in_fragment_root_selection() throws {
        let src = """
        fragment UserFields on User {
          id
          email
        }
        """
        let plan = try Compiler.compilePlan(source: src)

        // Compiler injects __typename into the fragment's root selection so
        // cache reads can resolve type identity.
        let typenameField = plan.root.first { $0.fieldName == CachebayConstants.typenameField }
        XCTAssertNotNil(typenameField)
        XCTAssertEqual(typenameField?.responseKey, CachebayConstants.typenameField)

        XCTAssertNotNil(plan.rootSelectionMap[CachebayConstants.typenameField])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_includes_typename_in_pageInfo_for_connections_via_fragment_spread() throws {
        let src = """
        fragment PageInfoFields on PageInfo {
          startCursor
          endCursor
          hasNextPage
          hasPreviousPage
        }

        fragment UserPosts on User {
          posts(first: $first) @connection {
            pageInfo { ...PageInfoFields }
            edges {
              cursor
              node { id }
            }
          }
        }
        """
        let plan = try Compiler.compilePlan(source: src, fragmentName: "UserPosts")

        let posts = try XCTUnwrap(plan.rootSelectionMap["posts"])
        XCTAssertTrue(posts.isConnection)

        let pageInfo = try XCTUnwrap(posts.selectionMap?["pageInfo"])
        XCTAssertNotNil(pageInfo.selectionMap?[CachebayConstants.typenameField])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_includes_typename_in_pageInfo_and_edges_for_connection_fields() throws {
        let src = """
        fragment UserPostsWithFilters on User {
          posts(category: $postsCategory, first: $postsFirst, after: $postsAfter) @connection(filters: ["category"]) {
            totalCount
            pageInfo {
              startCursor
              endCursor
              hasNextPage
              hasPreviousPage
            }
            edges {
              cursor
              node { id title }
            }
          }
        }
        """
        let plan = try Compiler.compilePlan(source: src, fragmentName: "UserPostsWithFilters")

        XCTAssertNotNil(plan.root.first { $0.fieldName == CachebayConstants.typenameField })

        let posts = try XCTUnwrap(plan.rootSelectionMap["posts"])
        XCTAssertTrue(posts.isConnection)

        let pageInfo = try XCTUnwrap(posts.selectionMap?["pageInfo"])
        let pageInfoTypename = pageInfo.selectionSet?.first { $0.fieldName == CachebayConstants.typenameField }
        XCTAssertNotNil(pageInfoTypename)
        XCTAssertEqual(pageInfoTypename?.responseKey, CachebayConstants.typenameField)

        let edges = try XCTUnwrap(posts.selectionMap?["edges"])
        let edgesTypename = edges.selectionSet?.first { $0.fieldName == CachebayConstants.typenameField }
        XCTAssertNotNil(edgesTypename)

        let node = try XCTUnwrap(edges.selectionMap?["node"])
        let nodeTypename = node.selectionSet?.first { $0.fieldName == CachebayConstants.typenameField }
        XCTAssertNotNil(nodeTypename)

        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_compiles_fragment_with_connection_using_directive_builds_nested_selectionMaps() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.userPostsFragment, fragmentName: "UserPosts")

        XCTAssertEqual(plan.operation, .fragment)
        XCTAssertEqual(plan.rootTypename, "User")

        let posts = try XCTUnwrap(plan.rootSelectionMap["posts"])
        XCTAssertTrue(posts.isConnection)
        XCTAssertEqual(posts.connectionKey, "posts")
        XCTAssertEqual(posts.connectionFilters, ["category"])
        XCTAssertEqual(posts.connectionMode, .infinite)

        let edges = try XCTUnwrap(posts.selectionMap?["edges"])
        let node = try XCTUnwrap(edges.selectionMap?["node"])
        XCTAssertEqual(node.fieldName, "node")

        let argsDict: [String: JSONValue] = [
            "postsCategory": .string("tech"),
            "postsFirst": .int(2),
            "postsAfter": .null,
        ]
        let postsKey = "\(posts.fieldName)(\(posts.stringifyArgs(argsDict)))"
        XCTAssertEqual(postsKey, #"posts({"category":"tech","first":2,"after":null})"#)

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_throws_when_doc_has_neither_op_nor_exactly_one_fragment() {
        let src = """
        fragment A on User { id }
        fragment B on User { email }
        """
        // Two fragments, no fragmentName → ambiguous selection.
        XCTAssertThrowsError(try Compiler.compilePlan(source: src))
    }

    func test_fragment_with_explicit_connection_key_captures_the_key() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.userPostsWithKeyFragment, fragmentName: "UserPosts")

        let feed = try XCTUnwrap(plan.rootSelectionMap["posts"])
        XCTAssertTrue(feed.isConnection)
        XCTAssertEqual(feed.connectionKey, "UserPosts")
        XCTAssertEqual(feed.connectionFilters, ["category"])
        XCTAssertNil(feed.connectionMode)

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }
}
