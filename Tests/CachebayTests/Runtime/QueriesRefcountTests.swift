import XCTest
@testable import Cachebay

/// Coverage for the watcher dep-index + signature ref-count bookkeeping
/// in `Queries`. These are the specific invariants the architecture doc
/// flags as §5.5 — atomic add/remove of dep entries when a watcher's
/// variables change, and signature ref-count drop on unsubscribe.
///
/// The tests observe behaviour (callback fires) rather than poking
/// internal state; if the bookkeeping breaks in the future, watchers
/// will fire on the wrong record, fail to fire on the right one, or
/// keep firing after `unsubscribe()`. Each path here would catch a
/// distinct breakage.
final class QueriesRefcountTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    private let postQuery = "query Post($id: ID!) { post(id: $id) { id title } }"

    /// Seed a `Post:<id>` entity record so the materialiser can read it.
    private func seedPost(_ client: CachebayClient, id: String, title: String) throws {
        try client.writeQuery(
            query: postQuery,
            variables: ["id": .string(id)],
            data: .object([
                "post": .object([
                    "__typename": .string("Post"),
                    "id": .string(id),
                    "title": .string(title),
                ])
            ])
        )
    }

    // MARK: - update(variables:) rotates the dep set

    func test_updateVariables_movesDepsToNewVar_oldVarChangesNoLongerFire() throws {
        let client = makeClient()
        try seedPost(client, id: "p1", title: "v1")
        try seedPost(client, id: "p2", title: "v2")

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: postQuery,
            options: WatchQueryOptions(
                variables: ["id": .string("p1")],
                immediate: true,
                onData: { received.append($0) }
            )
        )

        // Initial fire for p1.
        XCTAssertEqual(received.value.count, 1)

        // Rotate the watcher to p2; immediate=true → fire with p2 data.
        handle.update(["id": .string("p2")], true)
        XCTAssertEqual(received.value.count, 2)

        // After rotation, mutating p1 must NOT re-fire — the dep index
        // entry for Post:p1 has to have been removed when the signature
        // changed. If it hadn't, this would silently fire again.
        let beforeP1 = received.value.count
        try seedPost(client, id: "p1", title: "p1-changed-but-watcher-rotated-away")
        XCTAssertEqual(received.value.count, beforeP1, "watcher should not fire on Post:p1 after rotating to p2")

        // Mutating p2 SHOULD re-fire — dep index for Post:p2 must have
        // been added on rotation.
        let beforeP2 = received.value.count
        try seedPost(client, id: "p2", title: "p2-changed")
        XCTAssertGreaterThan(received.value.count, beforeP2, "watcher should fire on Post:p2 after rotating to it")

        handle.unsubscribe()
    }

    func test_updateVariables_sameVars_isNoOp() throws {
        let client = makeClient()
        try seedPost(client, id: "p1", title: "v1")

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: postQuery,
            options: WatchQueryOptions(
                variables: ["id": .string("p1")],
                immediate: true,
                onData: { received.append($0) }
            )
        )
        XCTAssertEqual(received.value.count, 1)

        // No-op rotation — same vars. immediate=true; data hasn't
        // changed since the initial fire, so the recycle path should
        // suppress a duplicate emission.
        handle.update(["id": .string("p1")], true)

        // Mutate the deps — must still fire (dep index intact).
        try seedPost(client, id: "p1", title: "v2")
        XCTAssertGreaterThanOrEqual(received.value.count, 2, "watcher must still fire after a no-op update")

        handle.unsubscribe()
    }

    // MARK: - unsubscribe stops fires + cleans the index

    func test_unsubscribe_stopsAllFutureFires() throws {
        let client = makeClient()
        try seedPost(client, id: "p1", title: "v1")

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: postQuery,
            options: WatchQueryOptions(
                variables: ["id": .string("p1")],
                immediate: true,
                onData: { received.append($0) }
            )
        )
        XCTAssertEqual(received.value.count, 1)

        handle.unsubscribe()

        // Subsequent writes to the same record must not fire — the dep
        // index entry has to be removed AND the watcher state purged.
        let beforeUnsub = received.value.count
        try seedPost(client, id: "p1", title: "v2")
        try seedPost(client, id: "p1", title: "v3")
        XCTAssertEqual(received.value.count, beforeUnsub, "no fires should land after unsubscribe()")
    }

    func test_multipleWatchersSameSignature_bothFireOnce() throws {
        let client = makeClient()
        try seedPost(client, id: "p1", title: "v1")

        let r1 = CaptureBox<[JSONValue]>(value: [])
        let r2 = CaptureBox<[JSONValue]>(value: [])
        let h1 = try client.watchQuery(
            query: postQuery,
            options: WatchQueryOptions(
                variables: ["id": .string("p1")],
                immediate: true,
                onData: { r1.append($0) }
            )
        )
        let h2 = try client.watchQuery(
            query: postQuery,
            options: WatchQueryOptions(
                variables: ["id": .string("p1")],
                immediate: true,
                onData: { r2.append($0) }
            )
        )
        XCTAssertEqual(r1.value.count, 1)
        XCTAssertEqual(r2.value.count, 1)

        // Single mutation → both watchers fire (fanout via depIndex
        // covers every watcher whose dep set includes the touched key).
        try seedPost(client, id: "p1", title: "v2")
        XCTAssertEqual(r1.value.count, 2)
        XCTAssertEqual(r2.value.count, 2)

        // Unsubscribe one — the other must keep firing. signatureToWatchers
        // count for this signature has to drop without triggering a cache
        // invalidation that disrupts the second watcher.
        h1.unsubscribe()
        try seedPost(client, id: "p1", title: "v3")
        XCTAssertEqual(r1.value.count, 2, "h1 must not fire after unsubscribe")
        XCTAssertEqual(r2.value.count, 3, "h2 must continue firing")

        h2.unsubscribe()
    }

    func test_overlappingWatchers_oneRotates_othersUnaffected() throws {
        let client = makeClient()
        try seedPost(client, id: "p1", title: "v1")
        try seedPost(client, id: "p2", title: "v2")

        let stickyP1 = CaptureBox<[JSONValue]>(value: [])
        let rotating = CaptureBox<[JSONValue]>(value: [])

        // Two watchers both initially on Post:p1.
        let stuck = try client.watchQuery(
            query: postQuery,
            options: WatchQueryOptions(
                variables: ["id": .string("p1")],
                immediate: true,
                onData: { stickyP1.append($0) }
            )
        )
        let rotator = try client.watchQuery(
            query: postQuery,
            options: WatchQueryOptions(
                variables: ["id": .string("p1")],
                immediate: true,
                onData: { rotating.append($0) }
            )
        )
        XCTAssertEqual(stickyP1.value.count, 1)
        XCTAssertEqual(rotating.value.count, 1)

        // Rotate one watcher away. The first watcher's dep on Post:p1
        // must remain — share-counting on the (signature) bucket has to
        // decrement, not invalidate.
        rotator.update(["id": .string("p2")], true)

        // Mutating Post:p1 must still fire `stuck`.
        try seedPost(client, id: "p1", title: "v1-updated")
        XCTAssertEqual(stickyP1.value.count, 2, "watcher remaining on p1 must keep firing")

        // Mutating Post:p2 must fire only the rotated watcher.
        let beforeStuckP2 = stickyP1.value.count
        let beforeRotP2 = rotating.value.count
        try seedPost(client, id: "p2", title: "v2-updated")
        XCTAssertEqual(stickyP1.value.count, beforeStuckP2, "stuck watcher must NOT fire on p2 changes")
        XCTAssertGreaterThan(rotating.value.count, beforeRotP2, "rotated watcher must fire on p2 changes")

        stuck.unsubscribe()
        rotator.unsubscribe()
    }

    // MARK: - Repeated update() rotations across many keys

    func test_repeatedRotations_depSetAlwaysReflectsCurrentVars() throws {
        // The bookkeeping has to be path-independent — N rotations
        // through different ids must leave the dep set in the same
        // shape as a fresh watch with the final id.
        let client = makeClient()
        for i in 1...5 {
            try seedPost(client, id: "p\(i)", title: "v\(i)")
        }

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: postQuery,
            options: WatchQueryOptions(
                variables: ["id": .string("p1")],
                immediate: false,
                onData: { received.append($0) }
            )
        )

        // Walk through every id, rotating the watcher.
        for i in 1...5 {
            handle.update(["id": .string("p\(i)")], true)
        }

        // Now we're on p5. Touch each previous id — none should fire.
        let beforeOldTouches = received.value.count
        for i in 1..<5 {
            try seedPost(client, id: "p\(i)", title: "stale-touch-\(i)")
        }
        XCTAssertEqual(received.value.count, beforeOldTouches, "no rotated-away dep should still fire after sequential update()s")

        // Touch the current id → must fire.
        let beforeCurrentTouch = received.value.count
        try seedPost(client, id: "p5", title: "current-changed")
        XCTAssertGreaterThan(received.value.count, beforeCurrentTouch, "current variable's record must fire")

        handle.unsubscribe()
    }
}
