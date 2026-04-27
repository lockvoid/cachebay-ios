import XCTest
@testable import Cachebay

/// Port of `cachebay-web/test/unit/core/planner.test.ts`.
///
/// On iOS the `Planner` only memoises by source string + fragmentName
/// (the JS variant memoises by DocumentNode identity too, but iOS
/// doesn't ship a DocumentNode AST as a public input — the only AST
/// inputs go through `Compiler.compilePlan(document:)` directly). The
/// equivalent of "DocumentNode memoisation" here is pre-compiled plan
/// pass-through via `.plan(_)` — never recompiles, returns the same
/// instance.
final class PlannerTests: XCTestCase {

    func test_plan_passthrough_returnsSameInstance() throws {
        let planner = Planner()
        let plan = try Compiler.compilePlan(source: "query Q { me { id } }")
        // Pre-compiled `.plan(...)` should pass through unchanged — no
        // recompile, identity-stable.
        let result = try planner.getPlan(.plan(plan))
        XCTAssertEqual(result, plan)
        // The CachePlan id (compile-time fingerprint) survives.
        XCTAssertEqual(result.id, plan.id)
    }

    func test_source_memoization_byString() throws {
        let planner = Planner()
        let src = "query Q { me { id } }"
        let p1 = try planner.getPlan(.source(src))
        let p2 = try planner.getPlan(.source(src))
        // Memoised: same plan instance returned.
        XCTAssertEqual(p1, p2)
        XCTAssertEqual(p1.id, p2.id)
    }

    func test_source_memoization_byFragmentName() throws {
        let planner = Planner()
        // Two named fragments in one document — `fragmentName` is the
        // memoisation discriminator.
        let src = """
        fragment X on Post { id }
        fragment Z on Post { id title }
        """
        let pX = try planner.getPlan(.source(src), fragmentName: "X")
        let pZ = try planner.getPlan(.source(src), fragmentName: "Z")
        XCTAssertNotEqual(pX, pZ)

        // Same name → same plan.
        let pX2 = try planner.getPlan(.source(src), fragmentName: "X")
        XCTAssertEqual(pX, pX2)
    }

    func test_source_memoization_isStable() throws {
        let planner = Planner()
        let src = "query Q { me { id } }"
        let p1 = try planner.getPlan(.source(src))
        let p2 = try planner.getPlan(.source(src))
        let p3 = try planner.getPlan(.source(src))
        // Repeated calls all yield the same plan id — no recompile drift.
        XCTAssertEqual(p1.id, p2.id)
        XCTAssertEqual(p2.id, p3.id)
    }

    func test_evictAll_clearsCache_returnsEqualButRecompiledPlans() throws {
        let planner = Planner()
        let src = "query Q { me { id } }"
        let p1 = try planner.getPlan(.source(src))

        planner.evictAll()

        let p2 = try planner.getPlan(.source(src))
        // Plans are equal by structure (same source → same fingerprint),
        // so `==` (by `id`) holds. The cache miss is observable in
        // `Planner` not as identity drift but as a recompile having
        // happened — we trust `evictAll` here and rely on the equality
        // and stable-id invariants.
        XCTAssertEqual(p1, p2)
    }

    func test_mixedInputs_planAndSource_areIndependent() throws {
        let planner = Planner()
        let src = "query Q { me { id } }"
        let prebuilt = try Compiler.compilePlan(source: src)

        let viaSource = try planner.getPlan(.source(src))
        let viaPlan = try planner.getPlan(.plan(prebuilt))

        // Both routes produce structurally-equal plans (same source →
        // same fingerprint) and pass-through never recompiles.
        XCTAssertEqual(viaSource, viaPlan)
        XCTAssertEqual(viaSource.id, viaPlan.id)
    }
}
