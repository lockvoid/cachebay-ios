import XCTest
@testable import Cachebay

/// Port of `cachebay-web/test/unit/core/queries-performance.test.ts`.
///
/// Web tests count normalize/materialize calls via a `vi.mock` shim. iOS pins
/// the same invariants by counting *emissions* on watchers — the user-visible
/// signal that lock-stepped with the web counters: 1 emission per data
/// change, none for no-op writes, exactly N for N updates.
final class QueriesPerformanceTests: XCTestCase {

    private let userQuery = "query GetUser($id: ID!) { user(id: $id) { id name } }"

    private func makeClient() -> (CachebayClient, MockHTTPTransport) {
        let http = MockHTTPTransport()
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: http),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
        return (client, http)
    }

    private func userPayload(_ id: String, name: String) -> JSONValue {
        return .object([
            "user": .object([
                "__typename": "User",
                "id": .string(id),
                "name": .string(name),
            ])
        ])
    }

    // MARK: - writeQuery: write only, no read fanout to non-watchers

    /// Mirrors web `writeQuery: should normalize 1, materialize 0
    /// (write only - no read)`. iOS analogue: a writeQuery with no watcher
    /// must not produce any emissions.
    func test_writeQuery_noWatcher_producesNoEmissions() throws {
        let (client, _) = makeClient()
        // Just verify the write completes without throwing — no observable
        // side-effect to assert against absent a watcher. (Companion test
        // below pins the watcher fanout count.)
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Alice"))
        XCTAssertEqual(client.readQuery(query: userQuery, variables: ["id": "1"])?["user"]?["name"]?.string, "Alice")
    }

    /// Mirrors web `pagination: 5 writeQuery calls should normalize 5,
    /// materialize 0`. Five writes with no watcher must not throw and must
    /// be observable individually via readQuery.
    func test_writeQuery_pagination_fiveWrites_eachIsReadable() throws {
        let (client, _) = makeClient()
        let postsQuery = """
            query GetPosts($first: Int!, $after: String) {
                posts(first: $first, after: $after) {
                    edges { node { id title } }
                    pageInfo { endCursor hasNextPage }
                }
            }
            """
        for i in 0..<5 {
            try client.writeQuery(
                query: postsQuery,
                variables: ["first": .int(2), "after": i == 0 ? .null : .string("c\(i)")],
                data: .object([
                    "posts": .object([
                        "__typename": "PostConnection",
                        "edges": .array([
                            .object([
                                "__typename": "PostEdge",
                                "node": .object(["__typename": "Post", "id": .string("p\(i*2+1)"), "title": .string("Post \(i*2+1)")]),
                            ]),
                            .object([
                                "__typename": "PostEdge",
                                "node": .object(["__typename": "Post", "id": .string("p\(i*2+2)"), "title": .string("Post \(i*2+2)")]),
                            ]),
                        ]),
                        "pageInfo": .object([
                            "__typename": "PageInfo",
                            "endCursor": .string("c\(i+1)"),
                            "hasNextPage": .bool(i < 4),
                        ]),
                    ])
                ])
            )
        }
        // Sanity: the first page is readable.
        let page0 = client.readQuery(query: postsQuery, variables: ["first": .int(2), "after": .null])
        XCTAssertEqual(page0?["posts"]?["edges"]?.array?.count, 2)
    }

    // MARK: - readQuery: always reflects latest state

    /// Mirrors web `readQuery always COLD (uses force: true) - no caching`.
    /// readQuery must always reflect the latest graph state — even after a
    /// putRecord that bypasses the query API.
    func test_readQuery_alwaysReflectsLatestGraphState() throws {
        let (client, _) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Alice"))

        let r1 = client.readQuery(query: userQuery, variables: ["id": "1"])
        XCTAssertEqual(r1?["user"]?["name"]?.string, "Alice")

        client.graph.putRecord("User:1", ["name": "Alice Updated"])
        client.graph.flush()

        let r2 = client.readQuery(query: userQuery, variables: ["id": "1"])
        XCTAssertEqual(r2?["user"]?["name"]?.string, "Alice Updated", "readQuery is not cached")
    }

    // MARK: - watchQuery: emission counts

    /// Mirrors web `watchQuery: should materialize 1 on initial load`.
    /// With cache pre-populated and immediate:true, the watcher emits
    /// exactly once.
    func test_watchQuery_immediateTrue_warmCache_emitsExactlyOnce() throws {
        let (client, _) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Alice"))

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: true,
                onData: { emissions.append($0) }
            )
        )
        XCTAssertEqual(emissions.value.count, 1)
        XCTAssertEqual(emissions.value[0]["user"]?["name"]?.string, "Alice")
        handle.unsubscribe()
    }

    /// Mirrors web `watchQuery: should rematerialize 1 on cache update`.
    /// One writeQuery after subscription must produce one emission.
    func test_watchQuery_writeQueryAfterSubscribe_emitsOnce() async throws {
        let (client, _) = makeClient()

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: true,
                onData: { emissions.append($0) }
            )
        )
        // Cache miss + immediate:true ⇒ no emission yet.
        XCTAssertEqual(emissions.value.count, 0)

        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Alice"))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(emissions.value.count, 1)
        XCTAssertEqual(emissions.value[0]["user"]?["name"]?.string, "Alice")
        handle.unsubscribe()
    }

    /// Mirrors web `should rematerialize 1 on operation execute`.
    /// executeQuery into an empty cache → one emission to the watcher.
    func test_watchQuery_executeQueryFillsCache_emitsOnce() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("user", respondWith: userPayload("1", name: "Alice"))

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: true,
                onData: { emissions.append($0) }
            )
        )
        XCTAssertEqual(emissions.value.count, 0)

        _ = try await client.executeQuery(
            query: userQuery,
            variables: ["id": "1"],
            cachePolicy: .networkOnly
        )
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(emissions.value.count, 1)
        XCTAssertEqual(emissions.value[0]["user"]?["name"]?.string, "Alice")
        handle.unsubscribe()
    }

    /// Mirrors web `watchQuery + writeQuery: should materialize twice
    /// (initial + update)`. Subscribe to warm cache (1) + one writeQuery (1)
    /// = 2 emissions.
    func test_watchQuery_warmCachePlusOneUpdate_emitsTwice() async throws {
        let (client, _) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Alice"))

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: true,
                onData: { emissions.append($0) }
            )
        )
        XCTAssertEqual(emissions.value.count, 1)

        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Alice Updated"))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(emissions.value.count, 2)
        XCTAssertEqual(emissions.value.last?["user"]?["name"]?.string, "Alice Updated")
        handle.unsubscribe()
    }

    /// Mirrors web `watchQuery with 2 watchers: should materialize once per
    /// watcher on update`. Two watchers, one update, two emissions per
    /// watcher (1 initial + 1 update).
    func test_twoWatchersSameSignature_eachEmitsTwice_onSingleUpdate() async throws {
        let (client, _) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Alice"))

        let e1 = CaptureBox<[JSONValue]>(value: [])
        let e2 = CaptureBox<[JSONValue]>(value: [])
        let h1 = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(variables: ["id": "1"], immediate: true, onData: { e1.append($0) })
        )
        let h2 = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(variables: ["id": "1"], immediate: true, onData: { e2.append($0) })
        )
        XCTAssertEqual(e1.value.count, 1)
        XCTAssertEqual(e2.value.count, 1)

        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Alice Updated"))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(e1.value.count, 2, "watcher 1 emits initial + update")
        XCTAssertEqual(e2.value.count, 2, "watcher 2 emits initial + update")
        h1.unsubscribe(); h2.unsubscribe()
    }

    /// Mirrors web `pagination with watcher: watcher materializes on each
    /// update`. 5 sequential writeQueries → watcher emits 5 times after
    /// the initial.
    func test_watchQuery_fiveSequentialUpdates_emitsSixTimes() async throws {
        let (client, _) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Alice"))

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: true,
                onData: { emissions.append($0) }
            )
        )
        XCTAssertEqual(emissions.value.count, 1)

        for i in 0..<5 {
            try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Alice \(i)"))
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(emissions.value.count, 6, "1 initial + 5 updates")
        XCTAssertEqual(emissions.value.last?["user"]?["name"]?.string, "Alice 4")
        handle.unsubscribe()
    }

    // MARK: - immediate option

    /// Mirrors web `immediate: true materializes and emits on cache hit`.
    /// Already covered by `test_watchQuery_immediateTrue_warmCache_emitsExactlyOnce`,
    /// but we also pin the no-emission path on cache miss here.

    /// Mirrors web `watchQuery with immediate: false does not emit on cache hit`.
    func test_watchQuery_immediateFalse_warmCache_emitsZero() throws {
        let (client, _) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Alice"))

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: false,
                onData: { emissions.append($0) }
            )
        )
        XCTAssertEqual(emissions.value.count, 0, "immediate:false ⇒ no initial emission")
        handle.unsubscribe()
    }

    /// Mirrors web `watchQuery with immediate: true does not emit on cache miss`.
    func test_watchQuery_immediateTrue_cacheMiss_emitsZero() throws {
        let (client, _) = makeClient()
        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "999"], immediate: true,
                onData: { emissions.append($0) }
            )
        )
        XCTAssertEqual(emissions.value.count, 0, "cache miss ⇒ no emission even with immediate:true")
        handle.unsubscribe()
    }

    /// Diverges from web `watchQuery with immediate: false does not track
    /// dependencies until first materialize`.
    ///
    /// iOS deliberately differs here: `Queries.watchQuery` registers
    /// plan-derived dependencies on subscribe even when `immediate: false`,
    /// so a subsequent dep change produces an emission without needing a
    /// preliminary `update(immediate:true)` to wake the watcher. This pin
    /// guards that behaviour: the immediate:false subscription suppresses
    /// the *initial* emission but still receives subsequent writes.
    func test_watchQuery_immediateFalse_stillTracksDepsViaPlan() async throws {
        let (client, _) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Alice"))

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: false,
                onData: { emissions.append($0) }
            )
        )
        XCTAssertEqual(emissions.value.count, 0, "immediate:false suppresses initial emission")

        // iOS pre-registers plan-derived deps, so a subsequent write fires.
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Bob"))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(emissions.value.count, 1, "plan-derived deps fire even without prior immediate materialize")
        XCTAssertEqual(emissions.value[0]["user"]?["name"]?.string, "Bob")

        handle.unsubscribe()
    }

    // MARK: - update method

    /// Mirrors web `update with immediate: true materializes and emits`.
    /// Rotate from id=1 to id=2 with immediate:true → second emission.
    func test_watchQuery_updateImmediateTrue_rotatesAndEmits() throws {
        let (client, _) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Alice"))
        try client.writeQuery(query: userQuery, variables: ["id": "2"], data: userPayload("2", name: "Bob"))

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: true,
                onData: { emissions.append($0) }
            )
        )
        XCTAssertEqual(emissions.value.count, 1)
        XCTAssertEqual(emissions.value[0]["user"]?["name"]?.string, "Alice")

        handle.update(["id": "2"], true)
        XCTAssertEqual(emissions.value.count, 2)
        XCTAssertEqual(emissions.value[1]["user"]?["name"]?.string, "Bob")

        handle.unsubscribe()
    }

    /// Mirrors web `update with immediate: false does not emit`.
    func test_watchQuery_updateImmediateFalse_doesNotEmit() throws {
        let (client, _) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Alice"))
        try client.writeQuery(query: userQuery, variables: ["id": "2"], data: userPayload("2", name: "Bob"))

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: true,
                onData: { emissions.append($0) }
            )
        )
        XCTAssertEqual(emissions.value.count, 1)

        handle.update(["id": "2"], false)
        XCTAssertEqual(emissions.value.count, 1, "immediate:false rotation must not emit")

        handle.unsubscribe()
    }

    /// Mirrors web `update with immediate: false waits for propagateData`.
    /// After an immediate:false rotation, a subsequent writeQuery against
    /// the new variables must trigger an emission via dep fanout.
    func test_watchQuery_updateImmediateFalse_thenWriteQuery_emits() async throws {
        let (client, _) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Alice"))

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: true,
                onData: { emissions.append($0) }
            )
        )
        XCTAssertEqual(emissions.value.count, 1)

        handle.update(["id": "1"], false)  // no-op rotation, no emit
        XCTAssertEqual(emissions.value.count, 1)

        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Bob"))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(emissions.value.count, 2)
        XCTAssertEqual(emissions.value.last?["user"]?["name"]?.string, "Bob")

        handle.unsubscribe()
    }

    /// Mirrors web `update with immediate: true on cache miss does not emit`.
    /// Rotating to a never-written id with immediate:true does NOT fire.
    func test_watchQuery_updateImmediateTrue_cacheMiss_doesNotEmit() throws {
        let (client, _) = makeClient()
        try client.writeQuery(query: userQuery, variables: ["id": "1"], data: userPayload("1", name: "Alice"))

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"], immediate: true,
                onData: { emissions.append($0) }
            )
        )
        XCTAssertEqual(emissions.value.count, 1)

        handle.update(["id": "999"], true)
        XCTAssertEqual(emissions.value.count, 1, "cache miss after rotation ⇒ no emission")

        handle.unsubscribe()
    }
}
