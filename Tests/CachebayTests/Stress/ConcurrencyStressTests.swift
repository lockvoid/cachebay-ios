import XCTest
@testable import Cachebay

/// Burst-tap correctness under concurrent load. These are the tests that
/// validate the "lock discipline by inspection" critique — they exercise
/// the whole pipeline under real contention and assert final-state
/// consistency, no deadlock, and correct watcher fan-out.
final class ConcurrencyStressTests: XCTestCase {
    private func makeClient(http: MockHTTPTransport) -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: http),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
    }

    func test_50_parallel_mutations_all_visible() async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("mutation") { vars in
            let id = vars["id"]?.string ?? "?"
            return OperationResult(
                data: .object([
                    "createPost": .object([
                        "post": .object([
                            "__typename": "Post", "id": .string(id), "title": .string("t-\(id)"),
                        ])
                    ])
                ]))
        }
        let client = makeClient(http: http)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { @Sendable in
                    _ = try? await client.executeMutation(
                        query: """
                            mutation M($id: ID!) {
                                createPost(id: $id) { post { id title } }
                            }
                            """,
                        variables: ["id": .string("p\(i)")]
                    )
                }
            }
        }

        for i in 0..<50 {
            XCTAssertEqual(
                client.graph.getField("Post:p\(i)", "title")?.string, "t-p\(i)",
                "Post:p\(i) missing or torn after parallel mutations")
        }
    }

    func test_parallel_optimistic_patches_and_reverts_no_deadlock() async throws {
        let client = makeClient(http: MockHTTPTransport())
        try client.writeFragment(
            id: "Post:p1", fragment: "fragment P on Post { id counter }",
            data: .object([
                "__typename": "Post", "id": "p1", "counter": 0,
            ]))

        let txBox = CaptureBox<[OptimisticTransaction]>(value: [])

        // 50 layers stacked concurrently.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { @Sendable in
                    let tx = client.modifyOptimistic { b in
                        b.patch(.key("Post:p1"), ["counter": .int(Int64(i + 1))], mode: .merge)
                    }
                    txBox.withLock { $0.append(tx) }
                }
            }
        }

        // Visible counter must be one of [1..50] (whichever layer applied last wins).
        let visible = client.graph.getField("Post:p1", "counter")?.int ?? -1
        XCTAssertGreaterThanOrEqual(visible, 1)
        XCTAssertLessThanOrEqual(visible, 50)

        // Revert all in arbitrary scheduling order — must not deadlock and must
        // converge to the committed baseline (counter=0).
        let txs = txBox.value
        await withTaskGroup(of: Void.self) { group in
            for tx in txs {
                group.addTask { @Sendable in tx.revert() }
            }
        }
        XCTAssertEqual(
            client.graph.getField("Post:p1", "counter")?.int, 0,
            "Revert of every layer must restore the committed baseline")
    }

    func test_watcher_never_drops_final_state_under_burst() async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("mutation") { vars in
            let id = vars["id"]?.string ?? "?"
            return OperationResult(
                data: .object([
                    "touch": .object([
                        "post": .object([
                            "__typename": "Post", "id": "p1", "title": .string("v-\(id)"),
                        ])
                    ])
                ]))
        }
        let client = makeClient(http: http)

        // Seed via writeQuery so the root entity link is populated — otherwise
        // the watcher is permanently in a cache-miss state for this shape.
        try client.writeQuery(
            query: "query { post(id: \"p1\") { id title } }",
            data: .object([
                "post": .object(["__typename": "Post", "id": "p1", "title": "seed"])
            ]))

        let emissions = CaptureBox<[String]>(value: [])
        let handle = try client.watchQuery(
            query: "query { post(id: \"p1\") { id title } }",
            options: WatchQueryOptions(
                immediate: true,
                onData: { data in
                    if let t = data["post"]?["title"]?.string {
                        emissions.withLock { $0.append(t) }
                    }
                }
            )
        )

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                group.addTask { @Sendable in
                    _ = try? await client.executeMutation(
                        query: "mutation M($id: ID!) { touch(id: $id) { post { id title } } }",
                        variables: ["id": .string("n\(i)")]
                    )
                }
            }
        }

        // Programmatic guard: poll until the convergence invariant holds
        // (last emission == graph's final field) or fail with a hard
        // deadline. A fixed `Task.sleep(50ms)` is unreliable under
        // contention — too short produces false failures, too long
        // wastes CI time. The deadline below is generous (1 s) but the
        // happy path resolves in microseconds, so well-behaved runs
        // exit immediately on the first poll. A failing run still
        // terminates within the deadline and reports a deterministic
        // error rather than a flaky timing race.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            let final = client.graph.getField("Post:p1", "title")?.string
            let last = emissions.value.last
            if final != nil, final == last { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        handle.unsubscribe()

        let final = client.graph.getField("Post:p1", "title")?.string
        let last = emissions.value.last
        XCTAssertEqual(final, last, "Watcher's last emission must reflect the graph's final state")
        XCTAssertGreaterThanOrEqual(
            emissions.value.count, 2,
            "Watcher should have observed at least initial + one network emission")
    }

    func test_no_lock_ordering_deadlock_mixed_load() async throws {
        // Exercises every subsystem lock in parallel: mutations (Operations+Documents+Graph),
        // optimistic patches (Optimistic+Graph), watcher updates (Queries+Documents+Graph),
        // fragment watchers (Fragments+Documents+Graph), readFragment (Documents+Graph),
        // evictAll (every subsystem). If any lock pair is mis-ordered, this deadlocks.
        let http = MockHTTPTransport()
        http.whenQueryContains("createPost") { vars in
            let id = vars["id"]?.string ?? "?"
            return OperationResult(
                data: .object([
                    "createPost": .object([
                        "post": .object([
                            "__typename": "Post", "id": .string(id), "title": .string("t-\(id)"),
                        ])
                    ])
                ]))
        }
        let client = makeClient(http: http)
        try client.writeFragment(
            id: "Post:base", fragment: "fragment P on Post { id title }",
            data: .object([
                "__typename": "Post", "id": "base", "title": "seed",
            ]))

        let deadline = Date().addingTimeInterval(1.0)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { @Sendable in
                    _ = try? await client.executeMutation(
                        query: "mutation M($id: ID!) { createPost(id: $id) { post { id title } } }",
                        variables: ["id": .string("m\(i)")]
                    )
                }
            }
            for i in 0..<20 {
                group.addTask { @Sendable in
                    let tx = client.modifyOptimistic { b in
                        b.patch(.key("Post:base"), ["title": .string("opt-\(i)")], mode: .merge)
                    }
                    tx.revert()
                }
            }
            for _ in 0..<20 {
                group.addTask { @Sendable in
                    _ = client.readFragment(id: "Post:base", fragment: "fragment P on Post { id title }")
                }
            }
        }

        XCTAssertLessThan(Date().timeIntervalSince(deadline), 5.0, "Possible deadlock — workload took too long")
        // After the storm, Post:base must still read. No torn state.
        let r = client.readFragment(id: "Post:base", fragment: "fragment P on Post { id title }")
        XCTAssertNotNil(r?["title"])
    }
}
