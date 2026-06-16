import XCTest
@testable import Cachebay

final class OperationsTests: XCTestCase {
    private func makeClient(ws: MockWSTransport? = nil) -> (CachebayClient, MockHTTPTransport) {
        let http = MockHTTPTransport()
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: http, ws: ws),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
        return (client, http)
    }

    func test_mutation_writes_result_and_updates_watchers() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("mutation") { _ in
            OperationResult(
                data: .object([
                    "createPost": .object([
                        "post": .object(["__typename": "Post", "id": "p1", "title": "Hello"])
                    ])
                ]))
        }

        // Watcher pre-registers deps for Post:p1 — the mutation should trigger it.
        let captured = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: "query { post(id: \"p1\") { id title } }",
            options: WatchQueryOptions(variables: ["id": "p1"], immediate: false, onData: { data in captured.append(data) })
        )
        // Pre-populate the dep index: normalize an empty response so watcher deps exist,
        // then let the mutation update the Post:p1 entity which feeds the watcher.
        try client.writeQuery(
            query: "query { post(id: \"p1\") { id title } }", variables: ["id": "p1"],
            data: .object([
                "post": .object(["__typename": "Post", "id": "p1", "title": "Old"])
            ]))
        try await Task.sleep(nanoseconds: 20_000_000)

        let result = try await client.executeMutation(
            query: """
                mutation CreatePost {
                    createPost {
                        post { id title }
                    }
                }
                """, variables: [:])
        XCTAssertNotNil(result.data?["createPost"]?["post"])
        XCTAssertEqual(result.data?["createPost"]?["post"]?["title"]?.string, "Hello")

        try await Task.sleep(nanoseconds: 30_000_000)
        handle.unsubscribe()

        let emissions = captured.value
        XCTAssertFalse(emissions.isEmpty)
        XCTAssertEqual(emissions.last?["post"]?["title"]?.string, "Hello")
    }

    func test_subscription_stream_yields_frames() async throws {
        let ws = MockWSTransport(frames: [
            .object(["postAdded": .object(["__typename": "Post", "id": "p1", "title": "First"])]),
            .object(["postAdded": .object(["__typename": "Post", "id": "p2", "title": "Second"])]),
        ])
        let (client, _) = makeClient(ws: ws)

        let stream = try client.executeSubscription(
            query: """
                subscription PostAdded { postAdded { id title } }
                """)

        var titles: [String] = []
        for try await event in stream {
            if let data = event.data, let t = data["postAdded"]?["title"]?.string {
                titles.append(t)
            }
            if titles.count == 2 { break }
        }
        XCTAssertEqual(titles, ["First", "Second"])
    }

    func test_networkOnly_always_fetches() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains(
            "me",
            respondWith: .object([
                "me": .object(["__typename": "User", "id": "u1", "name": "Alice"])
            ]))
        // Warm up cache.
        _ = try await client.executeQuery(query: "query { me { id name } }")
        XCTAssertEqual(http.calls.count, 1)
        // network-only should fetch again even with a warm cache.
        _ = try await client.executeQuery(query: "query { me { id name } }", cachePolicy: .networkOnly)
        XCTAssertEqual(http.calls.count, 2)
    }

    func test_error_propagates_to_watcher() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("posts") { _ in
            OperationResult(data: nil, error: CombinedError(networkMessage: "boom"))
        }
        let capturedErrors = CaptureBox<[CombinedError]>(value: [])
        _ = try client.watchQuery(
            query: "query { posts { id } }",
            options: WatchQueryOptions(
                immediate: false, onData: { _ in },
                onError: { err in
                    capturedErrors.lock.lock(); capturedErrors.unsafeValue.append(err); capturedErrors.lock.unlock()
                })
        )
        let r = try await client.executeQuery(query: "query { posts { id } }", cachePolicy: .networkOnly)
        XCTAssertNotNil(r.error)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertGreaterThanOrEqual(capturedErrors.value.count, 1)
    }

    func test_evictAll_clears_cache_and_refetches_watchers() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains(
            "me",
            respondWith: .object([
                "me": .object(["__typename": "User", "id": "u1", "name": "Alice"])
            ]))
        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: "query { me { id name } }",
            options: WatchQueryOptions(onData: { data in emissions.append(data) })
        )
        _ = try await client.executeQuery(query: "query { me { id name } }")
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(emissions.value.isEmpty)

        let callCountBefore = http.calls.count
        await client.evictAll()
        // After evictAll the watcher should have received nil, then a refetch should call network again.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThan(http.calls.count, callCountBefore)
        handle.unsubscribe()
    }
}
