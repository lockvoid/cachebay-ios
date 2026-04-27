import XCTest
@testable import Cachebay

/// Port of `cachebay-web/test/unit/compiler/compile-connections.test.ts`.
final class CompileConnectionsTests: XCTestCase {

    func test_marks_connection_when_directive_present_attaches_mode_and_args() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsQuery)
        XCTAssertEqual(plan.operation, .query)
        XCTAssertEqual(plan.rootTypename, "Query")

        let posts = try XCTUnwrap(plan.rootSelectionMap["posts"])
        XCTAssertTrue(posts.isConnection)
        XCTAssertEqual(posts.connectionMode, .infinite)
        XCTAssertEqual(posts.connectionFilters, ["category", "sort"])

        let edges = try XCTUnwrap(posts.selectionMap?["edges"])
        let node = try XCTUnwrap(edges.selectionMap?["node"])
        XCTAssertEqual(node.fieldName, "node")

        let postsArgs = posts.stringifyArgs([
            "category": .string("tech"),
            "first": .int(10),
            "after": .null,
        ])
        XCTAssertEqual(postsArgs, #"{"category":"tech","first":10,"after":null}"#)

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_defaults_mode_to_undefined_and_args_to_non_pagination() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsWithDefaultsQuery)
        let posts = try XCTUnwrap(plan.rootSelectionMap["posts"])
        XCTAssertTrue(posts.isConnection)
        XCTAssertNil(posts.connectionMode)
        XCTAssertEqual(posts.connectionFilters?.sorted(), ["category", "sort"])

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_does_not_mark_as_connection_when_directive_absent() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsWithoutConnectionQuery)
        let posts = try XCTUnwrap(plan.rootSelectionMap["posts"])
        XCTAssertFalse(posts.isConnection)
        XCTAssertNil(posts.connectionMode)
        XCTAssertNil(posts.connectionFilters)

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_uses_explicit_key_when_provided() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsWithKeyQuery)
        let posts = try XCTUnwrap(plan.rootSelectionMap["posts"])
        XCTAssertTrue(posts.isConnection)
        XCTAssertEqual(posts.connectionKey, "KeyedPosts")
        XCTAssertEqual(posts.connectionFilters, ["category", "sort"])

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_falls_back_to_field_name_as_key_when_key_omitted() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsQuery)
        let posts = try XCTUnwrap(plan.rootSelectionMap["posts"])
        XCTAssertTrue(posts.isConnection)
        XCTAssertEqual(posts.connectionKey, "posts")
        XCTAssertEqual(posts.connectionFilters, ["category", "sort"])

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_key_and_args_work_inside_a_fragment() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postCommentsFragment, fragmentName: "PostComments")
        XCTAssertEqual(plan.operation, .fragment)
        XCTAssertEqual(plan.rootTypename, "Post")

        let comments = try XCTUnwrap(plan.rootSelectionMap["comments"])
        XCTAssertTrue(comments.isConnection)
        XCTAssertEqual(comments.connectionKey, "PostComments")
        // No filters declared and no non-pagination args → empty inferred filters.
        XCTAssertEqual(comments.connectionFilters, [])
        XCTAssertNil(comments.connectionMode)

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_builds_selection_maps_for_pageInfo_and_edges() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsQuery)
        let posts = try XCTUnwrap(plan.rootSelectionMap["posts"])
        XCTAssertTrue(posts.isConnection)

        let pageInfo = try XCTUnwrap(posts.selectionMap?["pageInfo"])
        XCTAssertEqual(pageInfo.responseKey, "pageInfo")
        XCTAssertNotNil(pageInfo.selectionSet)

        let edges = try XCTUnwrap(posts.selectionMap?["edges"])
        XCTAssertEqual(edges.responseKey, "edges")
        let node = try XCTUnwrap(edges.selectionMap?["node"])
        XCTAssertNotNil(node.selectionSet)

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }
}
