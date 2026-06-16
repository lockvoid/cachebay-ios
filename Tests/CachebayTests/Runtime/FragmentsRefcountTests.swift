import XCTest
@testable import Cachebay

/// Mirror of `QueriesRefcountTests` for the fragment surface
/// (`watchFragment` + `update(...)`). Same §5.5 invariant: when a
/// fragment watcher's variables or root id change, the dep set has to
/// rotate atomically. When the last fragment watcher for a record
/// unsubscribes, no callback should land for subsequent writes.
final class FragmentsRefcountTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
    }

    private let postFragment = "fragment PostFields on Post { id title }"

    private func seedPost(_ client: CachebayClient, id: String, title: String) throws {
        try client.writeFragment(
            id: "Post:\(id)",
            fragment: postFragment,
            data: .object([
                "__typename": .string("Post"),
                "id": .string(id),
                "title": .string(title),
            ])
        )
    }

    // MARK: - update(rootId:) rotates the dep set

    func test_updateRootId_rotatesDepFromOldEntityToNew() throws {
        let client = makeClient()
        try seedPost(client, id: "p1", title: "v1")
        try seedPost(client, id: "p2", title: "v2")

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchFragment(
            id: "Post:p1",
            fragment: postFragment,
            options: WatchFragmentOptions(
                immediate: true,
                onData: { received.append($0) }
            )
        )
        XCTAssertEqual(received.value.count, 1)

        // Rotate to a different entity.
        handle.update("Post:p2", nil, true)

        // After rotation, mutating the OLD entity must NOT fire the
        // watcher — its dep entry for Post:p1 has to be removed.
        let afterRotate = received.value.count
        try seedPost(client, id: "p1", title: "p1-stale")
        XCTAssertEqual(received.value.count, afterRotate, "watcher should not fire on the rotated-away entity")

        // Mutating the NEW entity must fire — dep for Post:p2 has to be added.
        let beforeP2 = received.value.count
        try seedPost(client, id: "p2", title: "p2-changed")
        XCTAssertGreaterThan(received.value.count, beforeP2, "watcher should fire on the rotated-into entity")

        handle.unsubscribe()
    }

    // MARK: - unsubscribe stops fires

    func test_unsubscribe_stopsAllFutureFires() throws {
        let client = makeClient()
        try seedPost(client, id: "p1", title: "v1")

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchFragment(
            id: "Post:p1",
            fragment: postFragment,
            options: WatchFragmentOptions(
                immediate: true,
                onData: { received.append($0) }
            )
        )
        XCTAssertEqual(received.value.count, 1)

        handle.unsubscribe()

        let before = received.value.count
        try seedPost(client, id: "p1", title: "v2")
        try seedPost(client, id: "p1", title: "v3")
        XCTAssertEqual(received.value.count, before, "no fragment fires should land after unsubscribe()")
    }

    // MARK: - Multiple watchers, shared signature

    func test_multipleFragmentWatchers_sameId_bothFire_independent_unsubscribes() throws {
        let client = makeClient()
        try seedPost(client, id: "p1", title: "v1")

        let r1 = CaptureBox<[JSONValue]>(value: [])
        let r2 = CaptureBox<[JSONValue]>(value: [])
        let h1 = try client.watchFragment(
            id: "Post:p1",
            fragment: postFragment,
            options: WatchFragmentOptions(immediate: true, onData: { r1.append($0) })
        )
        let h2 = try client.watchFragment(
            id: "Post:p1",
            fragment: postFragment,
            options: WatchFragmentOptions(immediate: true, onData: { r2.append($0) })
        )
        XCTAssertEqual(r1.value.count, 1)
        XCTAssertEqual(r2.value.count, 1)

        try seedPost(client, id: "p1", title: "v2")
        XCTAssertEqual(r1.value.count, 2)
        XCTAssertEqual(r2.value.count, 2)

        // Drop one — the other must keep firing.
        h1.unsubscribe()
        try seedPost(client, id: "p1", title: "v3")
        XCTAssertEqual(r1.value.count, 2, "h1 must not fire after unsubscribe")
        XCTAssertEqual(r2.value.count, 3, "h2 must continue firing")

        h2.unsubscribe()
    }
}
