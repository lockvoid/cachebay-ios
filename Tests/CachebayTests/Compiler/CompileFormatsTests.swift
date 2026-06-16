import XCTest
import CachebayGraphQL
@testable import Cachebay

/// Port of `cachebay-web/test/unit/compiler/compile-formats.test.ts`.
///
/// Notes vs the JS version:
/// - "accepts a DocumentNode" — JS accepts `gql` documents; iOS exposes
///   `Compiler.compilePlan(document:)` which takes a parsed
///   `CachebayGraphQL.Document`. We test that path.
/// - "accepts a precompiled plan (pass-through identity)" — the iOS planner's
///   `.plan(_)` route is the equivalent and is already covered by
///   `PlannerTests.test_plan_passthrough_returnsSameInstance`. We add a
///   second test here so the file remains self-contained as a port.
final class CompileFormatsTests: XCTestCase {

    func test_accepts_a_raw_graphql_string() throws {
        let src = """
            query User($id: ID!) {
              user(id: $id) {
                id
                email
              }
            }
            """
        let plan = try Compiler.compilePlan(source: src)
        XCTAssertEqual(plan.operation, .query)
        XCTAssertEqual(plan.rootTypename, "Query")

        let user = plan.rootSelectionMap["user"]
        XCTAssertEqual(user?.fieldName, "user")

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_accepts_a_pre_parsed_document() throws {
        let src = """
            query User($id: ID!) {
              user(id: $id) {
                id
                email
              }
            }
            """
        // Equivalent to `gql` in cachebay-web — feed the parsed AST directly
        // into the compiler.
        let parsed = try CachebayGraphQL.Parser.parse(src)
        let plan = try Compiler.compilePlan(document: parsed)
        XCTAssertEqual(plan.operation, .query)
        XCTAssertEqual(plan.rootTypename, "Query")

        let user = plan.rootSelectionMap["user"]
        XCTAssertEqual(user?.fieldName, "user")

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_accepts_a_precompiled_plan_passthrough_via_planner() throws {
        let planner = Planner()
        let src = """
            query User($id: ID!) {
              user(id: $id) {
                id
                email
              }
            }
            """
        let plan1 = try Compiler.compilePlan(source: src)
        let plan2 = try planner.getPlan(.plan(plan1))

        XCTAssertEqual(plan2, plan1)
        XCTAssertEqual(plan2.operation, .query)
        XCTAssertEqual(plan2.rootTypename, "Query")

        XCTAssertEqual(collectConnectionDirectives(plan2.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan2.networkQuery))
    }
}
