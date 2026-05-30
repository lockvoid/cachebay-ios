import XCTest
@testable import Cachebay

/// Spec-conformant runtime evaluation of `@include(if: ...)` and
/// `@skip(if: ...)` (GraphQL spec §3.13.1–2). These directives are
/// universally supported — Apollo, Relay, urql all evaluate them at
/// read AND write time so a field marked as conditionally absent is
/// treated as not-in-selection, not as a cache miss.
///
/// Conflict rule from spec: when both are present on the same field,
/// `@skip` wins — the field is excluded if EITHER `@skip` evaluates
/// true OR `@include` evaluates false.
final class IncludeSkipDirectiveTests: XCTestCase {

    private func makeStack() -> (Graph, Documents) {
        let graph = Graph(options: GraphOptions(keys: [:], interfaces: [:]))
        let planner = Planner()
        let canonical = Canonical(graph: graph)
        let documents = Documents(graph: graph, planner: planner, canonical: canonical)
        return (graph, documents)
    }

    private func planFor(_ source: String) throws -> CachePlan {
        try Compiler.compilePlan(source: source)
    }

    // MARK: - Include directive at materialize

    func test_include_true_field_present_reads_normally() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("""
            query Q($id: ID!, $withProject: Boolean!) {
                cook(id: $id) {
                    id
                    title
                    project @include(if: $withProject) { id name }
                }
            }
        """)
        // Seed both cook + project.
        graph.putRecord("Cook:c1", [
            "__typename": .string("Cook"),
            "id": .string("c1"),
            "title": .string("Pasta"),
            "project": .ref("Project:p1"),
        ])
        graph.putRecord("Project:p1", [
            "__typename": .string("Project"),
            "id": .string("p1"),
            "name": .string("Italian Week"),
        ])
        graph.putRecord(CachebayConstants.rootID, [
            "cook({\"id\":\"c1\"})": .ref("Cook:c1"),
        ])

        let result = documents.materialize(
            plan: plan,
            variables: ["id": .string("c1"), "withProject": .bool(true)],
            options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: false)
        )
        XCTAssertTrue(result.canonicalOK)
        XCTAssertEqual(result.data["cook"]?["project"]?["name"]?.string, "Italian Week")
    }

    func test_include_false_field_skipped_cacheHit_withFieldAbsent() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("""
            query Q($id: ID!, $withProject: Boolean!) {
                cook(id: $id) {
                    id
                    title
                    project @include(if: $withProject) { id name }
                }
            }
        """)
        // Cook present; project NOT in cache.
        graph.putRecord("Cook:c1", [
            "__typename": .string("Cook"),
            "id": .string("c1"),
            "title": .string("Pasta"),
        ])
        graph.putRecord(CachebayConstants.rootID, [
            "cook({\"id\":\"c1\"})": .ref("Cook:c1"),
        ])

        let result = documents.materialize(
            plan: plan,
            variables: ["id": .string("c1"), "withProject": .bool(false)],
            options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: false)
        )
        XCTAssertTrue(result.canonicalOK,
            "include(if:false) → field excluded → no strictOK=false; cache must hit")
        // Field absent from output.
        XCTAssertNil(result.data["cook"]?["project"],
            "skipped field must not appear in materialized output")
        XCTAssertEqual(result.data["cook"]?["title"]?.string, "Pasta")
    }

    // MARK: - Skip directive at materialize

    func test_skip_true_field_skipped_cacheHit_withFieldAbsent() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("""
            query Q($id: ID!, $hideProject: Boolean!) {
                cook(id: $id) {
                    id
                    title
                    project @skip(if: $hideProject) { id name }
                }
            }
        """)
        graph.putRecord("Cook:c1", [
            "__typename": .string("Cook"),
            "id": .string("c1"),
            "title": .string("Pasta"),
        ])
        graph.putRecord(CachebayConstants.rootID, [
            "cook({\"id\":\"c1\"})": .ref("Cook:c1"),
        ])

        let result = documents.materialize(
            plan: plan,
            variables: ["id": .string("c1"), "hideProject": .bool(true)],
            options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: false)
        )
        XCTAssertTrue(result.canonicalOK)
        XCTAssertNil(result.data["cook"]?["project"])
    }

    func test_skip_false_field_included_normally() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("""
            query Q($id: ID!, $hideProject: Boolean!) {
                cook(id: $id) {
                    id
                    title
                    project @skip(if: $hideProject) { id name }
                }
            }
        """)
        graph.putRecord("Cook:c1", [
            "__typename": .string("Cook"),
            "id": .string("c1"),
            "title": .string("Pasta"),
            "project": .ref("Project:p1"),
        ])
        graph.putRecord("Project:p1", [
            "__typename": .string("Project"),
            "id": .string("p1"),
            "name": .string("Italian Week"),
        ])
        graph.putRecord(CachebayConstants.rootID, [
            "cook({\"id\":\"c1\"})": .ref("Cook:c1"),
        ])

        let result = documents.materialize(
            plan: plan,
            variables: ["id": .string("c1"), "hideProject": .bool(false)],
            options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: false)
        )
        XCTAssertTrue(result.canonicalOK)
        XCTAssertEqual(result.data["cook"]?["project"]?["name"]?.string, "Italian Week")
    }

    // MARK: - Spec conflict rule: @skip wins

    func test_skip_true_AND_include_true_field_excluded_skipWins() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("""
            query Q($id: ID!, $hide: Boolean!, $show: Boolean!) {
                cook(id: $id) {
                    id title
                    project @skip(if: $hide) @include(if: $show) { id name }
                }
            }
        """)
        graph.putRecord("Cook:c1", [
            "__typename": .string("Cook"),
            "id": .string("c1"),
            "title": .string("Pasta"),
        ])
        graph.putRecord(CachebayConstants.rootID, [
            "cook({\"id\":\"c1\"})": .ref("Cook:c1"),
        ])

        let result = documents.materialize(
            plan: plan,
            variables: [
                "id": .string("c1"),
                "hide": .bool(true),   // @skip says exclude
                "show": .bool(true),   // @include says include
            ],
            options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: false)
        )
        XCTAssertTrue(result.canonicalOK,
            "spec: @skip(true) wins over @include(true) — field excluded, no miss")
        XCTAssertNil(result.data["cook"]?["project"])
    }

    func test_skip_false_AND_include_false_field_excluded_includeFalseWins() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("""
            query Q($id: ID!, $hide: Boolean!, $show: Boolean!) {
                cook(id: $id) {
                    id title
                    project @skip(if: $hide) @include(if: $show) { id name }
                }
            }
        """)
        graph.putRecord("Cook:c1", [
            "__typename": .string("Cook"),
            "id": .string("c1"),
            "title": .string("Pasta"),
        ])
        graph.putRecord(CachebayConstants.rootID, [
            "cook({\"id\":\"c1\"})": .ref("Cook:c1"),
        ])

        let result = documents.materialize(
            plan: plan,
            variables: [
                "id": .string("c1"),
                "hide": .bool(false),  // @skip says include
                "show": .bool(false),  // @include says exclude
            ],
            options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: false)
        )
        XCTAssertTrue(result.canonicalOK,
            "@include(false) excludes the field — no miss")
        XCTAssertNil(result.data["cook"]?["project"])
    }

    // MARK: - Normalize honours directives

    func test_normalize_skips_field_when_includeIf_false() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("""
            query Q($id: ID!, $withProject: Boolean!) {
                cook(id: $id) {
                    id
                    title
                    project @include(if: $withProject) { id name }
                }
            }
        """)
        // Server (or consumer via writeFragment with inconsistent data)
        // tries to write a project field that the variables say to skip.
        // Normalize must NOT persist it.
        documents.normalize(
            plan: plan,
            variables: ["id": .string("c1"), "withProject": .bool(false)],
            data: .object([
                "cook": .object([
                    "__typename": .string("Cook"),
                    "id": .string("c1"),
                    "title": .string("Pasta"),
                    "project": .object([
                        "__typename": .string("Project"),
                        "id": .string("p1"),
                        "name": .string("Should Not Land"),
                    ])
                ])
            ])
        )
        XCTAssertEqual(graph.getRecord("Cook:c1")?["title"]?.string, "Pasta")
        XCTAssertNil(graph.getRecord("Cook:c1")?["project"],
            "normalize must honour @include(if:false) — project ref must not be written")
        XCTAssertNil(graph.getRecord("Project:p1"),
            "normalize must not write the skipped entity record either")
    }

    func test_normalize_includes_field_when_includeIf_true() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("""
            query Q($id: ID!, $withProject: Boolean!) {
                cook(id: $id) {
                    id
                    title
                    project @include(if: $withProject) { id name }
                }
            }
        """)
        documents.normalize(
            plan: plan,
            variables: ["id": .string("c1"), "withProject": .bool(true)],
            data: .object([
                "cook": .object([
                    "__typename": .string("Cook"),
                    "id": .string("c1"),
                    "title": .string("Pasta"),
                    "project": .object([
                        "__typename": .string("Project"),
                        "id": .string("p1"),
                        "name": .string("Italian Week"),
                    ])
                ])
            ])
        )
        XCTAssertEqual(graph.getRecord("Project:p1")?["name"]?.string, "Italian Week")
        XCTAssertNotNil(graph.getRecord("Cook:c1")?["project"])
    }

    // MARK: - Cross-flow: write false, read true → miss; write false, read false → hit

    func test_write_with_includeFalse_then_read_with_includeTrue_isCacheMiss() throws {
        let (_, documents) = makeStack()
        let plan = try planFor("""
            query Q($id: ID!, $withProject: Boolean!) {
                cook(id: $id) {
                    id title
                    project @include(if: $withProject) { id name }
                }
            }
        """)
        // Write without project.
        documents.normalize(
            plan: plan,
            variables: ["id": .string("c1"), "withProject": .bool(false)],
            data: .object([
                "cook": .object([
                    "__typename": .string("Cook"),
                    "id": .string("c1"),
                    "title": .string("Pasta"),
                ])
            ])
        )
        // Read asking for project.
        let result = documents.materialize(
            plan: plan,
            variables: ["id": .string("c1"), "withProject": .bool(true)],
            options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: false)
        )
        XCTAssertFalse(result.canonicalOK,
            "read with includeProject:true against a cook that lacks project → miss → refetch")
    }

    func test_write_with_includeFalse_then_read_with_includeFalse_isCacheHit() throws {
        let (_, documents) = makeStack()
        let plan = try planFor("""
            query Q($id: ID!, $withProject: Boolean!) {
                cook(id: $id) {
                    id title
                    project @include(if: $withProject) { id name }
                }
            }
        """)
        documents.normalize(
            plan: plan,
            variables: ["id": .string("c1"), "withProject": .bool(false)],
            data: .object([
                "cook": .object([
                    "__typename": .string("Cook"),
                    "id": .string("c1"),
                    "title": .string("Pasta"),
                ])
            ])
        )
        let result = documents.materialize(
            plan: plan,
            variables: ["id": .string("c1"), "withProject": .bool(false)],
            options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: false)
        )
        XCTAssertTrue(result.canonicalOK,
            "symmetrical read — project skipped both times → cache hit")
        XCTAssertNil(result.data["cook"]?["project"])
    }

    // MARK: - Constant directive arguments

    func test_include_constant_false_field_always_excluded() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("""
            query Q($id: ID!) {
                cook(id: $id) {
                    id title
                    project @include(if: false) { id name }
                }
            }
        """)
        graph.putRecord("Cook:c1", [
            "__typename": .string("Cook"),
            "id": .string("c1"),
            "title": .string("Pasta"),
        ])
        graph.putRecord(CachebayConstants.rootID, [
            "cook({\"id\":\"c1\"})": .ref("Cook:c1"),
        ])
        let result = documents.materialize(
            plan: plan,
            variables: ["id": .string("c1")],
            options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: false)
        )
        XCTAssertTrue(result.canonicalOK)
        XCTAssertNil(result.data["cook"]?["project"])
    }

    // MARK: - Codegen-shaped (literal-built) plan honours directives
    //
    // The runtime evaluation tests above all go through
    // `Compiler.compilePlan(source:)` — the runtime-lowering path. Real
    // production iOS apps use codegen-emitted plans built via
    // `PlanField.make(...)` and `CachePlan.make(...)` from
    // `CachePlanLiteral.swift`. Those tests below pin that the
    // codegen-shaped API surface passes `skipIf` / `includeIf` through
    // to the runtime gate.

    private func literalPlanWithIncludeOnProject() -> CachePlan {
        let projectField = PlanField.make(
            responseKey: "project",
            fieldName: "project",
            includeIf: .variable("withProject"),
            children: [
                PlanField.make(responseKey: "__typename", fieldName: "__typename"),
                PlanField.make(responseKey: "id", fieldName: "id"),
                PlanField.make(responseKey: "name", fieldName: "name"),
            ]
        )
        let cookField = PlanField.make(
            responseKey: "cook",
            fieldName: "cook",
            args: [(name: "id", value: .variable("id"))],
            children: [
                PlanField.make(responseKey: "__typename", fieldName: "__typename"),
                PlanField.make(responseKey: "id", fieldName: "id"),
                PlanField.make(responseKey: "title", fieldName: "title"),
                projectField,
            ]
        )
        return CachePlan.make(
            operation: .query,
            rootTypename: "Query",
            root: [cookField],
            networkQuery: "query Q($id: ID!, $withProject: Boolean!) { cook(id: $id) { id title project @include(if: $withProject) { id name } } }",
            strictVars: ["id", "withProject"],
            canonicalVars: ["id", "withProject"],
            windowArgs: []
        )
    }

    func test_literal_plan_honours_include_false() throws {
        let (graph, documents) = makeStack()
        let plan = literalPlanWithIncludeOnProject()
        graph.putRecord("Cook:c1", [
            "__typename": .string("Cook"),
            "id": .string("c1"),
            "title": .string("Pasta"),
        ])
        graph.putRecord(CachebayConstants.rootID, [
            "cook({\"id\":\"c1\"})": .ref("Cook:c1"),
        ])
        let result = documents.materialize(
            plan: plan,
            variables: ["id": .string("c1"), "withProject": .bool(false)],
            options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: false)
        )
        XCTAssertTrue(result.canonicalOK,
            "codegen-shaped plan with @include(if:false) must skip the field — no materialize miss")
        XCTAssertNil(result.data["cook"]?["project"])
    }

    func test_literal_plan_honours_include_true() throws {
        let (graph, documents) = makeStack()
        let plan = literalPlanWithIncludeOnProject()
        graph.putRecord("Cook:c1", [
            "__typename": .string("Cook"),
            "id": .string("c1"),
            "title": .string("Pasta"),
            "project": .ref("Project:p1"),
        ])
        graph.putRecord("Project:p1", [
            "__typename": .string("Project"),
            "id": .string("p1"),
            "name": .string("Italian Week"),
        ])
        graph.putRecord(CachebayConstants.rootID, [
            "cook({\"id\":\"c1\"})": .ref("Cook:c1"),
        ])
        let result = documents.materialize(
            plan: plan,
            variables: ["id": .string("c1"), "withProject": .bool(true)],
            options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: false)
        )
        XCTAssertTrue(result.canonicalOK)
        XCTAssertEqual(result.data["cook"]?["project"]?["name"]?.string, "Italian Week")
    }

    func test_literal_plan_skipIf_constant_true_excludes() throws {
        let (graph, documents) = makeStack()
        let projectField = PlanField.make(
            responseKey: "project",
            fieldName: "project",
            skipIf: .constant(true),
            children: [
                PlanField.make(responseKey: "__typename", fieldName: "__typename"),
                PlanField.make(responseKey: "id", fieldName: "id"),
            ]
        )
        let cookField = PlanField.make(
            responseKey: "cook",
            fieldName: "cook",
            args: [(name: "id", value: .variable("id"))],
            children: [
                PlanField.make(responseKey: "__typename", fieldName: "__typename"),
                PlanField.make(responseKey: "id", fieldName: "id"),
                projectField,
            ]
        )
        let plan = CachePlan.make(
            operation: .query, rootTypename: "Query", root: [cookField],
            networkQuery: "",
            strictVars: ["id"], canonicalVars: ["id"], windowArgs: []
        )
        graph.putRecord("Cook:c1", ["__typename": .string("Cook"), "id": .string("c1")])
        graph.putRecord(CachebayConstants.rootID, ["cook({\"id\":\"c1\"})": .ref("Cook:c1")])
        let result = documents.materialize(
            plan: plan, variables: ["id": .string("c1")],
            options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: false)
        )
        XCTAssertTrue(result.canonicalOK)
        XCTAssertNil(result.data["cook"]?["project"])
    }

    // MARK: - back-compat: PlanField.make without skipIf/includeIf still works

    func test_literal_plan_without_directives_works_as_before() throws {
        // Already-shipped generated files don't pass skipIf/includeIf
        // arguments — both must default to nil so existing code continues
        // to compile and run.
        let (graph, documents) = makeStack()
        let cookField = PlanField.make(
            responseKey: "cook",
            fieldName: "cook",
            args: [(name: "id", value: .variable("id"))],
            children: [
                PlanField.make(responseKey: "__typename", fieldName: "__typename"),
                PlanField.make(responseKey: "id", fieldName: "id"),
                PlanField.make(responseKey: "title", fieldName: "title"),
            ]
        )
        let plan = CachePlan.make(
            operation: .query, rootTypename: "Query", root: [cookField],
            networkQuery: "", strictVars: ["id"], canonicalVars: ["id"], windowArgs: []
        )
        graph.putRecord("Cook:c1", [
            "__typename": .string("Cook"), "id": .string("c1"), "title": .string("Pasta"),
        ])
        graph.putRecord(CachebayConstants.rootID, ["cook({\"id\":\"c1\"})": .ref("Cook:c1")])
        let result = documents.materialize(
            plan: plan, variables: ["id": .string("c1")],
            options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: false)
        )
        XCTAssertTrue(result.canonicalOK)
        XCTAssertEqual(result.data["cook"]?["title"]?.string, "Pasta")
    }

    func test_skip_constant_true_field_always_excluded() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("""
            query Q($id: ID!) {
                cook(id: $id) {
                    id title
                    project @skip(if: true) { id name }
                }
            }
        """)
        graph.putRecord("Cook:c1", [
            "__typename": .string("Cook"),
            "id": .string("c1"),
            "title": .string("Pasta"),
        ])
        graph.putRecord(CachebayConstants.rootID, [
            "cook({\"id\":\"c1\"})": .ref("Cook:c1"),
        ])
        let result = documents.materialize(
            plan: plan,
            variables: ["id": .string("c1")],
            options: .init(canonical: true, fingerprint: true, preferCache: false, updateCache: false)
        )
        XCTAssertTrue(result.canonicalOK)
        XCTAssertNil(result.data["cook"]?["project"])
    }
}
