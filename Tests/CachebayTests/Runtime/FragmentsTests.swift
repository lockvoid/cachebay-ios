import XCTest
@testable import Cachebay

/// Port of `cachebay-web/test/unit/core/fragments.test.ts`. Refcount /
/// dep-rotation invariants are covered separately in
/// `FragmentsRefcountTests`; this file covers the shape of the read /
/// write / watch surface itself, plus the `update(...)` flow.
final class FragmentsTests: XCTestCase {

    private func makeClient(interfaces: [String: [String]] = [:]) -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            interfaces: interfaces,
            suspensionTimeout: 0
        ))
    }

    private let userFragment = """
    fragment UserFields on User { id email }
    """

    // MARK: - readFragment

    func test_readFragment_returnsSnapshot_andReflectsUpdates() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "User:u1",
            fragment: userFragment,
            data: .object([
                "__typename": .string("User"),
                "id": .string("u1"),
                "email": .string("u1@example.com"),
            ])
        )

        let snap1 = client.readFragment(id: "User:u1", fragment: userFragment)
        XCTAssertEqual(snap1?["__typename"]?.string, "User")
        XCTAssertEqual(snap1?["id"]?.string, "u1")
        XCTAssertEqual(snap1?["email"]?.string, "u1@example.com")

        // Re-write — re-read must reflect the update.
        try client.writeFragment(
            id: "User:u1",
            fragment: userFragment,
            data: .object([
                "__typename": .string("User"),
                "id": .string("u1"),
                "email": .string("u1+updated@example.com"),
            ])
        )
        let snap2 = client.readFragment(id: "User:u1", fragment: userFragment)
        XCTAssertEqual(snap2?["email"]?.string, "u1+updated@example.com")
    }

    func test_readFragment_returnsNil_onCacheMiss() {
        let client = makeClient()
        XCTAssertNil(client.readFragment(id: "User:missing", fragment: userFragment))
    }

    // MARK: - writeFragment

    func test_writeFragment_writesEntityFieldsShallowly() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "User:u1",
            fragment: userFragment,
            data: .object([
                "__typename": .string("User"),
                "id": .string("u1"),
                "email": .string("seed@example.com"),
            ])
        )
        let rec = client.graph.getRecord("User:u1")
        XCTAssertEqual(rec?["__typename"], .string("User"))
        XCTAssertEqual(rec?["id"], .string("u1"))
        XCTAssertEqual(rec?["email"], .string("seed@example.com"))

        // Second write replaces fields shallowly.
        try client.writeFragment(
            id: "User:u1",
            fragment: userFragment,
            data: .object([
                "__typename": .string("User"),
                "id": .string("u1"),
                "email": .string("seed2@example.com"),
            ])
        )
        XCTAssertEqual(client.graph.getField("User:u1", "email"), .string("seed2@example.com"))
    }

    // MARK: - watchFragment

    func test_watchFragment_emitsImmediate_thenOnUpdate() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "User:u1",
            fragment: userFragment,
            data: .object([
                "__typename": .string("User"),
                "id": .string("u1"),
                "email": .string("u1@example.com"),
            ])
        )

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchFragment(
            id: "User:u1",
            fragment: userFragment,
            options: WatchFragmentOptions(immediate: true, onData: { received.append($0) })
        )
        XCTAssertEqual(received.value.count, 1)
        XCTAssertEqual(received.value.first?["email"]?.string, "u1@example.com")

        // Mutate via fragment write — watcher must re-fire.
        try client.writeFragment(
            id: "User:u1",
            fragment: userFragment,
            data: .object([
                "__typename": .string("User"),
                "id": .string("u1"),
                "email": .string("u1+updated@example.com"),
            ])
        )
        XCTAssertEqual(received.value.count, 2)
        XCTAssertEqual(received.value.last?["email"]?.string, "u1+updated@example.com")
        handle.unsubscribe()
    }

    func test_watchFragment_immediateFalse_doesNotEmit_synchronously() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "User:u1",
            fragment: userFragment,
            data: .object([
                "__typename": .string("User"),
                "id": .string("u1"),
                "email": .string("u1@example.com"),
            ])
        )
        try client.writeFragment(
            id: "User:u2",
            fragment: userFragment,
            data: .object([
                "__typename": .string("User"),
                "id": .string("u2"),
                "email": .string("u2@example.com"),
            ])
        )

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchFragment(
            id: "User:u1",
            fragment: userFragment,
            options: WatchFragmentOptions(immediate: true, onData: { received.append($0) })
        )
        XCTAssertEqual(received.value.count, 1)

        // Update with immediate=false — must NOT emit synchronously.
        // (iOS-specific divergence from web: deps stay on the old root
        // until the next `immediate: true` update — covered by
        // `FragmentsRefcountTests`.)
        handle.update("User:u2", nil, false)
        XCTAssertEqual(received.value.count, 1)

        handle.unsubscribe()
    }

    func test_watchFragment_update_sameEntity_doesNotReEmit() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "User:u1",
            fragment: userFragment,
            data: .object([
                "__typename": .string("User"),
                "id": .string("u1"),
                "email": .string("u1@example.com"),
            ])
        )

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchFragment(
            id: "User:u1",
            fragment: userFragment,
            options: WatchFragmentOptions(immediate: true, onData: { received.append($0) })
        )
        XCTAssertEqual(received.value.count, 1)

        // Update to same id with immediate=true — data unchanged → no re-emit.
        handle.update("User:u1", nil, true)
        XCTAssertEqual(received.value.count, 1)

        handle.unsubscribe()
    }

    func test_watchFragment_update_cacheMiss_thenLater_emitsWhenAppears() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "User:u1",
            fragment: userFragment,
            data: .object([
                "__typename": .string("User"),
                "id": .string("u1"),
                "email": .string("u1@example.com"),
            ])
        )

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchFragment(
            id: "User:u1",
            fragment: userFragment,
            options: WatchFragmentOptions(immediate: true, onData: { received.append($0) })
        )
        XCTAssertEqual(received.value.count, 1)

        // Rotate to a missing entity — must NOT emit (cache miss).
        handle.update("User:u999", nil, true)
        XCTAssertEqual(received.value.count, 1)

        // Later when the entity appears, the watcher fires.
        try client.writeFragment(
            id: "User:u999",
            fragment: userFragment,
            data: .object([
                "__typename": .string("User"),
                "id": .string("u999"),
                "email": .string("u999@example.com"),
            ])
        )
        XCTAssertEqual(received.value.count, 2)
        XCTAssertEqual(received.value.last?["id"]?.string, "u999")
        handle.unsubscribe()
    }

    // MARK: - evictAll fan-out

    func test_evictAll_emitsUndefinedToWatchers_andClearsRecords() async throws {
        let client = makeClient()
        try client.writeFragment(
            id: "User:u1",
            fragment: userFragment,
            data: .object([
                "__typename": .string("User"),
                "id": .string("u1"),
                "email": .string("u1@example.com"),
            ])
        )

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchFragment(
            id: "User:u1",
            fragment: userFragment,
            options: WatchFragmentOptions(immediate: true, onData: { received.append($0) })
        )
        XCTAssertEqual(received.value.count, 1)

        await client.evictAll()

        // After evictAll, the record is gone…
        XCTAssertNil(client.graph.getRecord("User:u1"))
        // …and the watcher has been notified with `.undefined`.
        XCTAssertGreaterThanOrEqual(received.value.count, 2)
        XCTAssertTrue(received.value.last?.isUndefined ?? false)
        handle.unsubscribe()
    }
}
