import XCTest
@testable import Cachebay

final class ClientIntegrationTests: XCTestCase {
    private func makeClient(http: MockHTTPTransport? = nil, ws: MockWSTransport? = nil) -> (CachebayClient, MockHTTPTransport) {
        let transport = http ?? MockHTTPTransport()
        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: transport, ws: ws),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
        return (client, transport)
    }

    func test_executeQuery_cacheFirst_misses_then_hits() async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("post", respondWith: .object([
            "post": .object([
                "__typename": "Post", "id": "p1", "title": "Hello"
            ])
        ]))
        let (client, _) = makeClient(http: http)
        let q = """
        query Post($id: ID!) { post(id: $id) { id title } }
        """

        let first = try await client.executeQuery(query: q, variables: ["id": "p1"])
        XCTAssertEqual(first.meta?.source, .network)
        XCTAssertEqual(first.data?["post"]?["title"]?.string, "Hello")
        XCTAssertEqual(http.calls.count, 1)

        let second = try await client.executeQuery(query: q, variables: ["id": "p1"])
        XCTAssertEqual(second.meta?.source, .cache)
        XCTAssertEqual(http.calls.count, 1, "cache-first should skip the network on a hit")
    }

    func test_executeQuery_cacheOnly_misses() async throws {
        let (client, _) = makeClient()
        let result = try await client.executeQuery(query: "{ me { id } }", cachePolicy: .cacheOnly)
        XCTAssertNil(result.data)
        XCTAssertNotNil(result.error)
    }

    func test_readQuery_writeQuery_roundtrip() throws {
        let (client, _) = makeClient()
        try client.writeQuery(query: "query { me { id name } }", data: .object([
            "me": .object(["__typename": "User", "id": "u1", "name": "Alice"])
        ]))
        let read = client.readQuery(query: "query { me { id name } }")
        XCTAssertEqual(read?["me"]?["name"]?.string, "Alice")
    }

    func test_watchQuery_emits_initial_and_updates() async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("post", respondWith: .object([
            "post": .object(["__typename": "Post", "id": "p1", "title": "Hello"])
        ]))
        let (client, _) = makeClient(http: http)
        let q = "query Post($id: ID!) { post(id: $id) { id title } }"

        let captured = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(query: q, options: WatchQueryOptions(
            variables: ["id": "p1"],
            immediate: true,
            onData: { data in captured.append(data) }
        ))

        let first = try await client.executeQuery(query: q, variables: ["id": "p1"])
        XCTAssertEqual(first.data?["post"]?["title"]?.string, "Hello")

        // Wait a tick for watcher emission.
        try await Task.sleep(nanoseconds: 20_000_000)

        // writeFragment should trigger the watcher via dep tracking.
        try client.writeFragment(id: "Post:p1", fragment: "fragment P on Post { title }", data: .object([
            "__typename": "Post", "id": "p1", "title": "Updated"
        ]))
        try await Task.sleep(nanoseconds: 30_000_000)
        handle.unsubscribe()

        let all = captured.value
        XCTAssertGreaterThanOrEqual(all.count, 2)
        XCTAssertEqual(all.last?["post"]?["title"]?.string, "Updated")
    }

    func test_writeFragment_then_readFragment() throws {
        let (client, _) = makeClient()
        try client.writeFragment(id: "Post:p1", fragment: """
        fragment PostFields on Post { id title }
        """, data: .object([
            "__typename": "Post", "id": "p1", "title": "Hello"
        ]))
        let read = client.readFragment(id: "Post:p1", fragment: "fragment PostFields on Post { id title }")
        XCTAssertEqual(read?["title"]?.string, "Hello")
    }

    func test_optimistic_patch_and_revert() throws {
        let (client, _) = makeClient()
        try client.writeFragment(id: "Post:p1", fragment: "fragment P on Post { id title }", data: .object([
            "__typename": "Post", "id": "p1", "title": "Original"
        ]))

        let tx = client.modifyOptimistic { builder in
            builder.patch(.key("Post:p1"), ["title": "Optimistic"], mode: .merge)
        }
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Optimistic")
        tx.revert()
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Original")
    }

    func test_optimistic_addNode_then_removeNode() throws {
        let (client, _) = makeClient()
        // Build empty canonical
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts", filters: [:])
        // Add a post via optimistic add.
        let tx = client.modifyOptimistic { b in
            let c = b.connection(selector)
            c.linkNode(.object(["__typename": "Post", "id": "p1"]), options: LinkNodeOptions(position: .start))
        }
        let canonicalKey = "@connection.posts({})"
        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edges.count, 1)
        tx.revert()
        let after = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(after.count, 0)
    }

}

/// Thread-safe collector used in tests to capture sync callback emissions.
/// `append(_:)` / `setValue(_:)` are async-safe (no raw `NSLock` usage across
/// suspension points).
final class CaptureBox<T>: @unchecked Sendable {
    let lock = NSLock()
    var unsafeValue: T
    init(value: T) { self.unsafeValue = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return unsafeValue }
        set { lock.lock(); unsafeValue = newValue; lock.unlock() }
    }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&unsafeValue)
    }
}

extension CaptureBox where T == [JSONValue] {
    func append(_ item: JSONValue) { withLock { $0.append(item) } }
}
