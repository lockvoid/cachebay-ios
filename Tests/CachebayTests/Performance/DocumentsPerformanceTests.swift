import XCTest
@testable import Cachebay

/// Port of `cachebay-web/test/unit/core/documents-performance.test.ts`.
///
/// These tests cover the materialize cache: hot/cold tracking, separation by
/// variables / canonical mode / rootId / fingerprint flag, cache miss caching,
/// and cache invalidation when the underlying graph changes.
///
/// Several behaviours overlap with `DocumentsMaterializeTests` but the focus
/// here is the `hot` field plus structural identity invariants that the web
/// suite relies on.
final class DocumentsPerformanceTests: XCTestCase {
    private func makeStack() -> (Graph, Documents) {
        let graph = Graph(options: GraphOptions(keys: [:], interfaces: [:]))
        let planner = Planner()
        let canonical = Canonical(graph: graph)
        let documents = Documents(graph: graph, planner: planner, canonical: canonical)
        return (graph, documents)
    }

    private func plan(_ source: String) throws -> CachePlan {
        return try Compiler.compilePlan(source: source)
    }

    // MARK: - cache behaviour

    /// Mirrors web `should return cached result on second call (same reference)`.
    /// First call must be COLD, second must be HOT and structurally equal.
    func test_secondCall_isHot_andEqualToFirst() throws {
        let (_, documents) = makeStack()
        let p = try plan("query GetUser($id: ID!) { user(id: $id) { id name } }")
        documents.normalize(
            plan: p, variables: ["id": "1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "1", "name": "Alice"])
            ]))

        let opts = MaterializeOptions(canonical: true, fingerprint: true, preferCache: true, updateCache: true)
        let r1 = documents.materialize(plan: p, variables: ["id": "1"], options: opts)
        XCTAssertFalse(r1.hot, "first call must be COLD")

        let r2 = documents.materialize(plan: p, variables: ["id": "1"], options: opts)
        XCTAssertTrue(r2.hot, "second call must be HOT")

        // Cache hit ⇒ structurally identical data + dependencies.
        XCTAssertEqual(r1.data, r2.data)
        XCTAssertEqual(r1.dependencies, r2.dependencies)
    }

    /// Mirrors web `should bypass cache when force: true`.
    /// `preferCache: false` must always re-materialize (COLD).
    func test_preferCacheFalse_bypassesCache_alwaysCold() throws {
        let (_, documents) = makeStack()
        let p = try plan("query GetUser($id: ID!) { user(id: $id) { id name } }")
        documents.normalize(
            plan: p, variables: ["id": "1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "1", "name": "Alice"])
            ]))

        let force = MaterializeOptions(canonical: true, fingerprint: true, preferCache: false, updateCache: true)
        let r1 = documents.materialize(plan: p, variables: ["id": "1"], options: force)
        XCTAssertFalse(r1.hot)
        let r2 = documents.materialize(plan: p, variables: ["id": "1"], options: force)
        XCTAssertFalse(r2.hot, "preferCache:false must always be COLD")
        // But data is structurally equal.
        XCTAssertEqual(r1.data, r2.data)
    }

    /// Mirrors web `should create separate cache entries for different variables`.
    /// Each variable set has its own hot/cold lifecycle.
    func test_differentVariables_haveSeparateCacheEntries() throws {
        let (_, documents) = makeStack()
        let p = try plan("query GetUser($id: ID!) { user(id: $id) { id name } }")
        documents.normalize(
            plan: p, variables: ["id": "1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "1", "name": "Alice"])
            ]))
        documents.normalize(
            plan: p, variables: ["id": "2"],
            data: .object([
                "user": .object(["__typename": "User", "id": "2", "name": "Bob"])
            ]))

        let opts = MaterializeOptions(preferCache: true, updateCache: true)
        let r1a = documents.materialize(plan: p, variables: ["id": "1"], options: opts)
        let r2a = documents.materialize(plan: p, variables: ["id": "2"], options: opts)
        XCTAssertFalse(r1a.hot)
        XCTAssertFalse(r2a.hot)

        let r1b = documents.materialize(plan: p, variables: ["id": "1"], options: opts)
        let r2b = documents.materialize(plan: p, variables: ["id": "2"], options: opts)
        XCTAssertTrue(r1b.hot)
        XCTAssertTrue(r2b.hot)
        XCTAssertEqual(r1b.data["user"]?["name"]?.string, "Alice")
        XCTAssertEqual(r2b.data["user"]?["name"]?.string, "Bob")
    }

    /// Mirrors web `should create separate cache entries for canonical vs strict mode`.
    /// Canonical and strict reads cache independently.
    func test_canonicalAndStrict_haveSeparateCacheEntries() throws {
        let (_, documents) = makeStack()
        let p = try plan("query GetUser($id: ID!) { user(id: $id) { id name } }")
        documents.normalize(
            plan: p, variables: ["id": "1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "1", "name": "Alice"])
            ]))

        let canonOpts = MaterializeOptions(canonical: true, preferCache: true, updateCache: true)
        let strictOpts = MaterializeOptions(canonical: false, preferCache: true, updateCache: true)

        let c1 = documents.materialize(plan: p, variables: ["id": "1"], options: canonOpts)
        let s1 = documents.materialize(plan: p, variables: ["id": "1"], options: strictOpts)
        XCTAssertFalse(c1.hot)
        XCTAssertFalse(s1.hot)

        let c2 = documents.materialize(plan: p, variables: ["id": "1"], options: canonOpts)
        let s2 = documents.materialize(plan: p, variables: ["id": "1"], options: strictOpts)
        XCTAssertTrue(c2.hot, "canonical hot after first read")
        XCTAssertTrue(s2.hot, "strict hot after first read")
    }

    /// Mirrors web `should create separate cache entries for different rootId`.
    /// Fragment-style materialization keyed by rootId caches per entity.
    func test_differentRootIds_haveSeparateCacheEntries() throws {
        let (graph, documents) = makeStack()
        let f = try plan("fragment UserFields on User { id name }")
        graph.putRecord("User:1", ["__typename": "User", "id": "1", "name": "Alice"])
        graph.putRecord("User:2", ["__typename": "User", "id": "2", "name": "Bob"])
        graph.flush()

        let opts1 = MaterializeOptions(rootId: "User:1", preferCache: true, updateCache: true)
        let opts2 = MaterializeOptions(rootId: "User:2", preferCache: true, updateCache: true)

        let r1a = documents.materialize(plan: f, variables: [:], options: opts1)
        let r2a = documents.materialize(plan: f, variables: [:], options: opts2)
        XCTAssertFalse(r1a.hot)
        XCTAssertFalse(r2a.hot)

        let r1b = documents.materialize(plan: f, variables: [:], options: opts1)
        XCTAssertTrue(r1b.hot)
        XCTAssertEqual(r1b.data["name"]?.string, "Alice")
        XCTAssertEqual(r2a.data["name"]?.string, "Bob")
    }

    // MARK: - cache invalidation

    /// Mirrors web `should update cache when data changes and force: true is used`.
    /// preferCache returns stale; preferCache:false re-materializes and updates
    /// the cache so subsequent preferCache reads see the new data.
    func test_dataChangeWithForce_updatesCacheForFutureHits() throws {
        let (_, documents) = makeStack()
        let p = try plan("query GetUser($id: ID!) { user(id: $id) { id name } }")
        documents.normalize(
            plan: p, variables: ["id": "1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "1", "name": "Alice"])
            ]))

        let prefer = MaterializeOptions(preferCache: true, updateCache: true)
        let force = MaterializeOptions(preferCache: false, updateCache: true)

        // Seed cache.
        let r1 = documents.materialize(plan: p, variables: ["id": "1"], options: prefer)
        XCTAssertFalse(r1.hot)
        XCTAssertEqual(r1.data["user"]?["name"]?.string, "Alice")

        // Update underlying graph data.
        documents.normalize(
            plan: p, variables: ["id": "1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "1", "name": "Alice Updated"])
            ]))

        // preferCache returns OLD cached result.
        let r2 = documents.materialize(plan: p, variables: ["id": "1"], options: prefer)
        XCTAssertTrue(r2.hot)
        XCTAssertEqual(r2.data["user"]?["name"]?.string, "Alice", "preferCache returns stale entry")

        // Force re-materialize updates the cache.
        let r3 = documents.materialize(plan: p, variables: ["id": "1"], options: force)
        XCTAssertFalse(r3.hot)
        XCTAssertEqual(r3.data["user"]?["name"]?.string, "Alice Updated")

        // Subsequent preferCache call sees the freshly-updated entry.
        let r4 = documents.materialize(plan: p, variables: ["id": "1"], options: prefer)
        XCTAssertTrue(r4.hot)
        XCTAssertEqual(r4.data["user"]?["name"]?.string, "Alice Updated")
    }

    // MARK: - performance optimization

    /// Mirrors web `should handle multiple queries with different cache entries efficiently`.
    /// 10 distinct variable sets, each with its own hot/cold lifecycle.
    func test_tenDifferentEntries_eachCachedIndependently() throws {
        let (_, documents) = makeStack()
        let p = try plan("query GetUser($id: ID!) { user(id: $id) { id name } }")
        for i in 1...10 {
            documents.normalize(
                plan: p, variables: ["id": .string(String(i))],
                data: .object([
                    "user": .object([
                        "__typename": "User",
                        "id": .string(String(i)),
                        "name": .string("User \(i)"),
                    ])
                ]))
        }

        let opts = MaterializeOptions(preferCache: true, updateCache: true)

        // First pass: all COLD.
        for i in 1...10 {
            let r = documents.materialize(plan: p, variables: ["id": .string(String(i))], options: opts)
            XCTAssertFalse(r.hot, "first call for id=\(i) must be COLD")
        }

        // Second pass: all HOT.
        for i in 1...10 {
            let r = documents.materialize(plan: p, variables: ["id": .string(String(i))], options: opts)
            XCTAssertTrue(r.hot, "second call for id=\(i) must be HOT")
            XCTAssertEqual(r.data["user"]?["name"]?.string, "User \(i)")
        }
    }

    // MARK: - edge cases

    /// Mirrors web `should handle cache miss (no data) correctly`.
    /// Even a `.none` result is cached so the second read is HOT.
    func test_noneResult_isCached_andHotOnSecondRead() throws {
        let (_, documents) = makeStack()
        let p = try plan("query GetUser($id: ID!) { user(id: $id) { id name } }")

        let opts = MaterializeOptions(preferCache: true, updateCache: true)
        let r1 = documents.materialize(plan: p, variables: ["id": "999"], options: opts)
        XCTAssertEqual(r1.source, .none)
        XCTAssertFalse(r1.hot)

        let r2 = documents.materialize(plan: p, variables: ["id": "999"], options: opts)
        XCTAssertEqual(r2.source, .none)
        XCTAssertTrue(r2.hot, "even a .none result must be cached")
    }

    /// Mirrors web `should handle empty variables object correctly`.
    /// Empty-vars query caches once and the second call is HOT.
    func test_emptyVariables_areCachedOnce() throws {
        let (_, documents) = makeStack()
        let p = try plan("query GetAllUsers { users { id name } }")
        documents.normalize(
            plan: p, variables: [:],
            data: .object([
                "users": .array([
                    .object(["__typename": "User", "id": "1", "name": "Alice"])
                ])
            ]))

        let opts = MaterializeOptions(preferCache: true, updateCache: true)
        let r1 = documents.materialize(plan: p, variables: [:], options: opts)
        XCTAssertFalse(r1.hot)

        let r2 = documents.materialize(plan: p, variables: [:], options: opts)
        XCTAssertTrue(r2.hot)
    }

    /// Mirrors web `should create separate cache entries for different fingerprint option`.
    /// fingerprint:true and fingerprint:false cache independently — each pair
    /// (true,true) and (false,false) becomes HOT, but switching the flag is
    /// always COLD.
    func test_fingerprintTrue_andFalse_haveSeparateCacheEntries() throws {
        let (_, documents) = makeStack()
        let p = try plan("query GetUser($id: ID!) { user(id: $id) { id name } }")
        documents.normalize(
            plan: p, variables: ["id": "1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "1", "name": "Alice"])
            ]))

        let fpOn = MaterializeOptions(fingerprint: true, preferCache: true, updateCache: true)
        let fpOff = MaterializeOptions(fingerprint: false, preferCache: true, updateCache: true)

        let r1 = documents.materialize(plan: p, variables: ["id": "1"], options: fpOn)
        XCTAssertFalse(r1.hot)
        let r2 = documents.materialize(plan: p, variables: ["id": "1"], options: fpOff)
        XCTAssertFalse(r2.hot, "different fingerprint option ⇒ separate entry, COLD")

        let r3 = documents.materialize(plan: p, variables: ["id": "1"], options: fpOn)
        XCTAssertTrue(r3.hot, "fingerprint:true second call must be HOT")
        let r4 = documents.materialize(plan: p, variables: ["id": "1"], options: fpOff)
        XCTAssertTrue(r4.hot, "fingerprint:false second call must be HOT")

        // fingerprint:true emits __version on the fingerprints tree.
        if case .object(let o) = r1.fingerprints,
            case .int(let v) = o[CachebayConstants.fingerprintKey] ?? .undefined
        {
            XCTAssertGreaterThan(v, 0)
        } else {
            XCTFail("fingerprint:true must populate root __version")
        }
        // fingerprint:false does NOT emit __version.
        if case .object(let o) = r2.fingerprints {
            XCTAssertNil(o[CachebayConstants.fingerprintKey])
        }

        // Underlying data is identical regardless of fingerprint option.
        XCTAssertEqual(r1.data["user"]?["id"]?.string, r2.data["user"]?["id"]?.string)
        XCTAssertEqual(r1.data["user"]?["name"]?.string, r2.data["user"]?["name"]?.string)
    }
}
