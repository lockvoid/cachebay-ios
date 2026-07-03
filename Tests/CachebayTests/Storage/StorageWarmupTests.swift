import XCTest
@testable import Cachebay

/// Contract + performance tests for explicit `client.warmup()` —
/// the v0.9.0 replacement for the previous fire-and-forget
/// auto-async-warmup that ran inside `CachebayClient.init`.
///
/// **Contract**: a client constructed with a `StorageAdapterFactory`
/// reads the SQLite database **only when the caller calls
/// `client.warmup()`**. Construction is cheap; hydration is explicit
/// and synchronous on the calling thread. Callers wrap in `Task` if
/// they want async semantics — that's the consumer's choice, not
/// Cachebay's.
///
/// **Performance**: bulk SQLite hydration measured across three
/// realistic cache-size tiers (`500`, `5_000`, `50_000` records) so
/// you can see how warmup time scales and where the per-record cost
/// plateaus. Numbers reported under `[perf] sqlite warmup …`.
final class StorageWarmupTests: XCTestCase {

    private func tmpPath() -> String {
        let base = FileManager.default.temporaryDirectory
        return base.appendingPathComponent("cachebay-warmup-\(UUID().uuidString).sqlite").path
    }

    private func makeClient(path: String) -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0,
                storage: SQLiteStorage.factory(options: .init(path: path))
            ))
    }

    // MARK: - Contract: construction does NOT auto-hydrate

    /// v0.9.0 breaking change: storage-backed clients no longer
    /// fire off a background hydration task on init. The graph is
    /// empty until `warmup()` is called explicitly.
    func test_construction_doesNotAutoHydrate() async throws {
        let path = tmpPath()
        let seed = makeClient(path: path)
        try seed.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p1", "title": "Persisted"])
        )
        try await seed.storage?.flush()
        await seed.shutdown()

        // Fresh client over the same file — no warmup() yet.
        let fresh = makeClient(path: path)
        // Give any (incorrectly-spawned) background task a chance to fire.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(
            fresh.graph.getRecord("Post:p1"),
            "Construction must NOT trigger background hydration; the graph must be empty until warmup() is called explicitly")
        await fresh.shutdown()
    }

    // MARK: - Contract: warmup() is synchronous and populates the graph

    func test_warmup_isSynchronous_andPopulatesGraph() async throws {
        let path = tmpPath()
        let seed = makeClient(path: path)
        try seed.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p1", "title": "From disk"])
        )
        try seed.writeFragment(
            id: "Post:p2",
            fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p2", "title": "Also from disk"])
        )
        try await seed.storage?.flush()
        await seed.shutdown()

        let client = makeClient(path: path)
        client.warmup()  // ← sync; returns when the graph is fully populated

        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "From disk")
        XCTAssertEqual(client.graph.getField("Post:p2", "title")?.string, "Also from disk")
        await client.shutdown()
    }

    // MARK: - Contract: warmup() is a no-op when no storage is configured

    func test_warmup_noOp_whenStorageMissing() {
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
        // Must not throw, must not crash.
        client.warmup()
        XCTAssertNil(client.graph.getRecord("Post:p1"))
    }

    // MARK: - Contract: warmup() is idempotent

    func test_warmup_idempotent_multipleCallsAreSafe() async throws {
        let path = tmpPath()
        let seed = makeClient(path: path)
        try seed.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p1", "title": "Original"])
        )
        try await seed.storage?.flush()
        await seed.shutdown()

        let client = makeClient(path: path)
        client.warmup()
        client.warmup()
        client.warmup()
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Original")
        await client.shutdown()
    }

    // MARK: - Contract: warmup() is gap-fill — never overwrites live writes

    func test_warmup_gapFill_doesNotOverwriteFresherInMemoryWrites() async throws {
        let path = tmpPath()
        let seed = makeClient(path: path)
        try seed.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p1", "title": "On disk"])
        )
        try await seed.storage?.flush()
        await seed.shutdown()

        let client = makeClient(path: path)
        // Simulate a fresh network response landing BEFORE warmup is
        // called (the typical race in apps that fire queries during
        // bootstrap). Live data must beat disk data on conflict.
        client.graph.replaceRecord(
            "Post:p1",
            [
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("From network — newer"),
            ])
        client.warmup()

        XCTAssertEqual(
            client.graph.getField("Post:p1", "title")?.string, "From network — newer",
            "warmup() must NOT overwrite a record that's already in the in-memory graph (gap-fill semantics)")
        await client.shutdown()
    }

    // MARK: - Contract: warmup() can be wrapped by caller in a Task for async usage

    func test_warmup_canBeWrappedInTask_byCaller() async throws {
        let path = tmpPath()
        let seed = makeClient(path: path)
        try seed.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p1", "title": "Async-loaded"])
        )
        try await seed.storage?.flush()
        await seed.shutdown()

        let client = makeClient(path: path)
        // Caller's choice: run on a detached background Task.
        await Task.detached(priority: .userInitiated) {
            client.warmup()
        }.value

        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Async-loaded")
        await client.shutdown()
    }

    // MARK: - Performance: warmup latency across realistic cache sizes

    /// Three tiers spanning two orders of magnitude:
    ///   • Small  (~500   records) — fresh install, a couple of cached queries.
    ///   • Medium (~5 000 records) — typical user with a handful of projects + chat.
    ///   • Large  (~50 000 records) — heavy / power user, agent-spawned entities at scale.
    ///
    /// Each tier seeds an SQLite file with realistic record-shape mix
    /// (entity records + connection canonicals + edge records + aux),
    /// runs `client.warmup()` 3x on a fresh client over that file, and
    /// reports `min / median / max` wall-clock timing.
    ///
    /// These print measured numbers; they don't fail-on-slow. CI scrapes
    /// the `[perf] sqlite warmup …` lines for regression tracking.
    func test_perf_sqlite_warmup_acrossTiers() async throws {
        for (label, size) in [("small", 500), ("medium", 5_000), ("large", 50_000)] {
            let path = tmpPath()
            try seedRealisticGraph(path: path, recordCount: size)

            // Run warmup 3x on fresh clients over the same file.
            // Each iteration uses a NEW client because warmup() is
            // a one-shot hydration; we want to measure cold launches.
            var samples: [Double] = []
            for _ in 0..<3 {
                let client = makeClient(path: path)
                let start = CFAbsoluteTimeGetCurrent()
                client.warmup()
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                samples.append(elapsed * 1000)  // ms
                await client.shutdown()
            }
            samples.sort()
            let mn = samples.first!
            let med = samples[samples.count / 2]
            let mx = samples.last!
            let perRecord = (med * 1_000) / Double(size)  // µs/record
            print("[perf] sqlite warmup \(label.padding(toLength: 6, withPad: " ", startingAt: 0))(n=\(size)) ms=[min=\(String(format: "%.1f", mn)) median=\(String(format: "%.1f", med)) max=\(String(format: "%.1f", mx))] per-record=\(String(format: "%.1f", perRecord)) µs")

            // Sanity asserts so a 10× regression breaks CI even if no
            // human reads the [perf] lines.
            switch label {
            case "small": XCTAssertLessThan(med, 200, "small (n=500) median warmup must stay under 200ms")
            case "medium": XCTAssertLessThan(med, 1500, "medium (n=5_000) median warmup must stay under 1500ms")
            case "large": XCTAssertLessThan(med, 10_000, "large (n=50_000) median warmup must stay under 10s")
            default: break
            }
        }
    }

    // MARK: - Realistic-shape seeder

    /// Build a mix of record types that approximates a real app's
    /// cache shape after a session:
    ///   • 60% entity records (typename + id + 5-10 scalars, 2-3 refs)
    ///   • 25% connection canonicals + their pageInfo
    ///   • 10% edge records
    ///   •  5% aux records (::nodeIndex / ::cursorIndex)
    ///
    /// The mix matters because each record type has different
    /// serialized-size + deserialization-cost characteristics. A
    /// pure-entity benchmark would understate per-record cost vs.
    /// real usage.
    private func seedRealisticGraph(path: String, recordCount: Int) throws {
        let noop: @Sendable ([(CacheKey, [String: JSONValue])]) -> Void = { _ in }
        let noopRemove: @Sendable ([CacheKey]) -> Void = { _ in }
        let ctx = StorageContext(instanceID: "perf-seed", onUpdate: noop, onRemove: noopRemove)
        let storage = SQLiteStorage(context: ctx, options: .init(path: path))

        var records: [(CacheKey, [String: JSONValue])] = []
        records.reserveCapacity(recordCount)

        let entityCount = Int(Double(recordCount) * 0.60)
        let canonicalCount = Int(Double(recordCount) * 0.25)
        let edgeCount = Int(Double(recordCount) * 0.10)
        let auxCount = recordCount - entityCount - canonicalCount - edgeCount

        // Entities — typed scalars + a couple of refs.
        for i in 0..<entityCount {
            records.append(
                (
                    "Post:p\(i)",
                    [
                        "__typename": .string("Post"),
                        "id": .string("p\(i)"),
                        "title": .string("Post title number \(i) — realistic length string for serialization weight"),
                        "body": .string(String(repeating: "lorem ", count: 20)),
                        "createdAt": .string("2026-05-04T06:53:00Z"),
                        "updatedAt": .string("2026-05-04T06:54:00Z"),
                        "likes": .int(Int64(i % 1000)),
                        "published": .bool(i % 3 == 0),
                        "author": .ref("User:u\(i % 50)"),
                        "tags": .refList(["Tag:t\(i % 10)", "Tag:t\((i + 1) % 10)"]),
                    ]
                ))
        }

        // Connection canonicals + pageInfo records.
        for i in 0..<canonicalCount {
            let canonicalKey: CacheKey = "@connection.posts({\"category\":\"c\(i)\"})"
            // Each canonical points at ~10-30 edges (synthetic, just refs).
            let edges = (0..<min(20, edgeCount)).map { "\(canonicalKey).edges.\($0)" }
            records.append(
                (
                    canonicalKey,
                    [
                        "__typename": .string("PostConnection"),
                        "edges": .refList(edges),
                        "pageInfo": .ref("\(canonicalKey).pageInfo"),
                    ]
                ))
            records.append(
                (
                    "\(canonicalKey).pageInfo",
                    [
                        "__typename": .string("PageInfo"),
                        "hasNextPage": .bool(true),
                        "hasPreviousPage": .bool(false),
                        "startCursor": .string("cur-\(i)-start"),
                        "endCursor": .string("cur-\(i)-end"),
                    ]
                ))
        }

        // Edge records — synthetic refs + cursor.
        for i in 0..<edgeCount {
            records.append(
                (
                    "@connection.posts({}).edges.\(i)",
                    [
                        "__typename": .string("PostEdge"),
                        "node": .ref("Post:p\(i % max(entityCount, 1))"),
                        "cursor": .string("cursor-\(i)"),
                    ]
                ))
        }

        // Aux records — nodeIndex + cursorIndex per canonical (rough).
        for i in 0..<auxCount {
            records.append(
                (
                    "@connection.posts({\"category\":\"a\(i)\"})::nodeIndex",
                    [
                        "Post:p\(i)": .string("@connection.posts({}).edges.\(i)")
                    ]
                ))
        }

        storage.put(records)
        // Wait for write-behind to drain. Bounded: an unbounded wait()
        // here is sync-over-async — if the flush Task can't be scheduled
        // it deadlocks the whole suite run instead of failing this test.
        let waitGroup = DispatchSemaphore(value: 0)
        Task {
            try? await storage.flush()
            waitGroup.signal()
        }
        XCTAssertEqual(
            waitGroup.wait(timeout: .now() + 30), .success,
            "storage.flush() did not complete within 30s — write-behind stalled")
        storage.dispose()
    }
}
