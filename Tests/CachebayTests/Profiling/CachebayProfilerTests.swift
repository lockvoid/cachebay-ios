import XCTest
@testable import Cachebay

/// Contract tests for `CachebayProfiler`:
/// - Each instrumented hot path emits the expected span.
/// - Host callbacks (`builder`, `onData`, network round-trip) are
///   **not** observed as active spans — they execute either outside
///   every span or inside a paused region (Pattern A or B from the
///   profiler doc).
/// - Disabled profiler (nil) is the default and produces no overhead
///   path (covered indirectly: the existing 500+ tests pass with
///   `profiler == nil`).
final class CachebayProfilerTests: XCTestCase {
    private func makeClient(profiler: RecordingProfiler? = nil) -> CachebayClient {
        let http = MockHTTPTransport()
        return CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: http),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0,
                profiler: profiler
            ))
    }

    // MARK: - Protocol shape

    func test_disabledProfiler_isDefault_and_zeroOverhead_shape() throws {
        // With no profiler set, normal operations succeed and don't
        // crash. (Zero-cost is verified end-to-end by the rest of the
        // suite running unchanged.)
        let client = makeClient(profiler: nil)
        XCTAssertNil(client.profiler)
        let tx = client.modifyOptimistic { b in
            b.patch(.key("Post:p1"), ["title": .string("v")], mode: .merge)
        }
        tx.dispose()
    }

    func test_recordingProfiler_capturesSpan_lifecycle() {
        let profiler = RecordingProfiler()
        let span = profiler.begin("test.span")
        span?.attribute("k", "v")
        span?.end()
        let recorded = profiler.spans
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].name, "test.span")
        XCTAssertTrue(recorded[0].isEnded)
        XCTAssertEqual(recorded[0].attributes["k"], "v")
    }

    func test_span_endIsIdempotent() {
        let profiler = RecordingProfiler()
        let span = profiler.begin("test.span")
        span?.end()
        let beforeSecond = profiler.spans[0].endedAt
        span?.end()
        let afterSecond = profiler.spans[0].endedAt
        XCTAssertEqual(
            beforeSecond, afterSecond,
            "Second end() must not overwrite the first end timestamp")
    }

    func test_pauseResume_recordsExclusionWindow() {
        let profiler = RecordingProfiler()
        let span = profiler.begin("test.span")
        span?.pause()
        // Tiny stall so the pause segment has measurable duration.
        Thread.sleep(forTimeInterval: 0.005)
        span?.resume()
        span?.end()
        let rec = profiler.spans[0]
        XCTAssertEqual(rec.pauseSegments.count, 1)
        XCTAssertGreaterThan(rec.pausedDuration, 0)
        XCTAssertLessThan(
            rec.pausedDuration, 0.5,
            "Paused duration should be roughly the stall, not the whole span")
    }

    func test_excludingHost_pausesAndResumes() {
        let profiler = RecordingProfiler()
        let span = profiler.begin("test.span")
        var ran = false
        span.excludingHost {
            ran = true
            XCTAssertEqual(profiler.spans[0].pauseSegments.count, 1)
            XCTAssertEqual(
                profiler.spans[0].pauseSegments[0].1, .infinity,
                "Pause should be open while inside excludingHost body")
        }
        XCTAssertTrue(ran)
        // After body returns, span is resumed (pause segment is closed).
        XCTAssertLessThan(profiler.spans[0].pauseSegments[0].1, .infinity)
        span?.end()
    }

    func test_excludingHost_onNilSpan_runsBody() {
        let optSpan: CachebayProfileSpan? = nil
        var ran = false
        optSpan.excludingHost { ran = true }
        XCTAssertTrue(ran)
    }

    // MARK: - Call-site coverage (the inventory)

    func test_modifyOptimistic_emitsSpan_and_excludesHostBuilder() throws {
        let profiler = RecordingProfiler()
        let client = makeClient(profiler: profiler)

        let builderRan = CaptureBox<Bool>(value: false)
        let tx = client.modifyOptimistic { b in
            // While the builder runs, the modifyOptimistic span must
            // be in a paused region — the user's closure is host code.
            XCTAssertTrue(
                profiler.activeNames.contains("cachebay.modifyOptimistic"),
                "Span is open but paused — still active in the sense of begun-not-ended")
            let span = profiler.spans.first { $0.name == "cachebay.modifyOptimistic" }
            XCTAssertNotNil(span)
            XCTAssertEqual(
                span?.pauseSegments.count, 1,
                "Builder closure must be inside a pause segment (excludingHost)")
            XCTAssertEqual(
                span?.pauseSegments.last?.1, .infinity,
                "Pause segment must be open while body runs")
            builderRan.value = true
            b.patch(.key("Post:p1"), ["title": .string("v")], mode: .merge)
        }
        XCTAssertTrue(builderRan.value)
        tx.dispose()

        XCTAssertTrue(profiler.didEmit("cachebay.modifyOptimistic"))
        let span = profiler.spans(named: "cachebay.modifyOptimistic")[0]
        XCTAssertTrue(span.isEnded)
        XCTAssertEqual(span.pauseSegments.count, 1)
        // Closed segment after body returned.
        XCTAssertLessThan(span.pauseSegments[0].1, .infinity)
    }

    func test_applyAutoCommit_emitsSpan_and_excludesHostBuilder() {
        let profiler = RecordingProfiler()
        let client = makeClient(profiler: profiler)
        client.modifyOptimistic(autoCommit: true) { b in
            XCTAssertEqual(profiler.spans.first { $0.name == "cachebay.applyAutoCommit" }?.pauseSegments.last?.1, .infinity)
            b.patch(.key("Post:p1"), ["title": .string("v")], mode: .merge)
        }
        XCTAssertTrue(profiler.didEmit("cachebay.applyAutoCommit"))
    }

    func test_writeFragment_and_readFragment_emitSpans() throws {
        let profiler = RecordingProfiler()
        let client = makeClient(profiler: profiler)
        try client.writeFragment(
            id: "Post:p1", fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p1", "title": "x"]))
        _ = client.readFragment(id: "Post:p1", fragment: "fragment P on Post { id title }")

        XCTAssertTrue(profiler.didEmit("cachebay.writeFragment"))
        XCTAssertTrue(profiler.didEmit("cachebay.readFragment"))
    }

    func test_normalize_and_materialize_emitSpans() throws {
        let profiler = RecordingProfiler()
        let client = makeClient(profiler: profiler)
        try client.writeFragment(
            id: "Post:p1", fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p1", "title": "x"]))
        XCTAssertTrue(
            profiler.didEmit("cachebay.documents.normalize"),
            "writeFragment funnels through documents.normalize")
        _ = client.readFragment(id: "Post:p1", fragment: "fragment P on Post { id title }")
        XCTAssertTrue(
            profiler.didEmit("cachebay.documents.materialize"),
            "readFragment funnels through materialize")
    }

    func test_graphFlush_emitsSpan() throws {
        let profiler = RecordingProfiler()
        let client = makeClient(profiler: profiler)
        try client.writeFragment(
            id: "Post:p1", fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p1", "title": "x"]))
        XCTAssertTrue(
            profiler.didEmit("cachebay.graph.flush"),
            "writeFragment triggers a graph.flush")
    }

    func test_watchersFanout_emitsSpan_andHostCallback_isOutsideSpan() throws {
        let profiler = RecordingProfiler()
        let client = makeClient(profiler: profiler)

        let emissions = CaptureBox<[String]>(value: [])
        try client.writeFragment(
            id: "Post:p1", fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p1", "title": "seed"]))
        let handle = try client.watchFragment(
            id: "Post:p1", fragment: "fragment P on Post { id title }",
            options: WatchFragmentOptions(
                immediate: false,
                onData: { data in
                    emissions.withLock { $0.append(data["title"]?.string ?? "?") }
                    // While this host callback runs, the fanout span MUST
                    // have already ended (pattern B).
                    if let s = profiler.spans(named: "cachebay.watchers.fanout").last {
                        XCTAssertTrue(
                            s.isEnded,
                            "Fanout span must be closed before host onData callback runs")
                    }
                })
        )

        profiler.reset()
        try client.writeFragment(
            id: "Post:p1", fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p1", "title": "v2"]))
        handle.unsubscribe()

        XCTAssertTrue(profiler.didEmit("cachebay.watchers.fanout"))
        XCTAssertEqual(emissions.value, ["v2"])
    }

    func test_executeMutation_emitsSpan_andExcludesNetwork() async throws {
        let profiler = RecordingProfiler()
        let http = MockHTTPTransport()
        http.whenQueryContains("mutation") { _ in
            // Stall the "network" enough that we'd notice if it was
            // inside the parent span instead of excluded.
            Thread.sleep(forTimeInterval: 0.05)
            return OperationResult(
                data: .object([
                    "touch": .object([
                        "post": .object([
                            "__typename": "Post", "id": "p1", "title": "v",
                        ])
                    ])
                ]))
        }
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: http), cachePolicy: .cacheFirst,
                suspensionTimeout: 0, profiler: profiler
            ))

        _ = try await client.executeMutation(
            query: "mutation { touch { post { id title } } }",
            variables: [:]
        )

        let mut = profiler.spans(named: "cachebay.executeMutation")
        XCTAssertEqual(mut.count, 1)
        XCTAssertTrue(mut[0].isEnded)
        // Network was inside an excludingHost region → at least one
        // pause segment with non-trivial duration (~50 ms stall).
        XCTAssertGreaterThanOrEqual(
            mut[0].pauseSegments.count, 1,
            "Network round-trip must be in an excludingHost (paused) region")
        XCTAssertGreaterThan(
            mut[0].pausedDuration, 0.02,
            "Paused duration should include the 50 ms network stall")
    }

    func test_executeQuery_emitsSpan_andExcludesNetwork() async throws {
        let profiler = RecordingProfiler()
        let http = MockHTTPTransport()
        // Use a high-cardinality matcher that's guaranteed to be in
        // the planner's normalized networkQuery (the literal field).
        http.whenQueryContains("post") { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return OperationResult(
                data: .object([
                    "post": .object(["__typename": "Post", "id": "p1", "title": "v"])
                ]))
        }
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: http), cachePolicy: .networkOnly,
                suspensionTimeout: 0, profiler: profiler
            ))

        _ = try await client.executeQuery(
            query: "query { post(id: \"p1\") { id title } }",
            cachePolicy: .networkOnly
        )

        let q = profiler.spans(named: "cachebay.executeQuery")
        XCTAssertEqual(q.count, 1)
        XCTAssertTrue(q[0].isEnded)
        XCTAssertGreaterThan(
            q[0].pausedDuration, 0.02,
            "Network call inside performRequest must pause the parent span")
    }

    // MARK: - Replay (entity + connection)

    func test_replayEntityOps_emitsSpan_whenLayersPending() throws {
        let profiler = RecordingProfiler()
        let client = makeClient(profiler: profiler)

        try client.writeFragment(
            id: "Post:p1", fragment: "fragment P on Post { id title likes }",
            data: .object(["__typename": "Post", "id": "p1", "title": "x", "likes": 0]))
        // Open a pending layer so the next normalize triggers replay.
        let tx = client.modifyOptimistic { b in
            b.patch(.key("Post:p1"), ["likes": .int(99)], mode: .merge)
        }
        profiler.reset()
        try client.writeFragment(
            id: "Post:p1", fragment: "fragment P on Post { id title likes }",
            data: .object(["__typename": "Post", "id": "p1", "title": "y", "likes": 0]))
        tx.dispose()

        XCTAssertTrue(
            profiler.didEmit("cachebay.optimistic.replay.entity"),
            "Server normalize with a pending layer must trigger replayEntityOps span")
        let span = profiler.spans(named: "cachebay.optimistic.replay.entity")[0]
        XCTAssertNotNil(span.attributes["scopeSize"])
    }

    func test_replayEntityOps_noSpan_whenNoLayersPending() throws {
        let profiler = RecordingProfiler()
        let client = makeClient(profiler: profiler)
        try client.writeFragment(
            id: "Post:p1", fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p1", "title": "x"]))
        XCTAssertFalse(
            profiler.didEmit("cachebay.optimistic.replay.entity"),
            "Pre-lock fast path must short-circuit before entering the profiler span")
    }

    // MARK: - Storage warmup

    func test_storageWarmup_emitsSpan_andExcludesDiskLoad() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("cachebay-profiler-\(UUID().uuidString).sqlite").path
        let factory = SQLiteStorage.factory(options: .init(path: path))
        // Seed the database from a first client.
        let seed = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst, suspensionTimeout: 0, storage: factory
            ))
        try seed.writeFragment(
            id: "Post:p1", fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p1", "title": "persisted"]))
        try await seed.storage?.flush()
        await seed.shutdown()

        let profiler = RecordingProfiler()
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst, suspensionTimeout: 0,
                storage: SQLiteStorage.factory(options: .init(path: path)),
                profiler: profiler
            ))
        client.warmup()
        await client.shutdown()

        let w = profiler.spans(named: "cachebay.storage.warmup")
        XCTAssertEqual(w.count, 1, "warmup must emit exactly one span")
        XCTAssertTrue(w[0].isEnded)
        XCTAssertEqual(w[0].attributes["recordCount"], "1")
        // loadSync() is wrapped in excludingHost → at least one pause segment.
        XCTAssertGreaterThanOrEqual(
            w[0].pauseSegments.count, 1,
            "Disk load must be in an excludingHost region")
    }
}
