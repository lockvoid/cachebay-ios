import XCTest

@testable import Cachebay

/// Confirm-first (follow-up to `OptimisticAtomicityTests`): is `tx.commit { … }`
/// ATOMIC for watchers?
///
/// `commit` (Optimistic.swift) restores the layer's touched records to their
/// committed baseline (rolling back the optimistic edit), replays survivors,
/// then runs the caller's commit closure to write the authoritative server
/// data — and only flushes once at the end. But the commit closure is host
/// code: if it reads the cache mid-closure (`materialize`/`readQuery` →
/// `graph.flush()`, Documents.swift:619), that flush delivers the
/// rolled-back-but-server-data-not-yet-written state to watchers. The watcher
/// then sees the optimistic value flicker away for a frame before the server
/// value lands — the same class of bug as the `modifyOptimistic` leak.
///
/// This test reproduces it with a real mid-closure flush. It should FAIL until
/// `commit` wraps its commit closure in `beginNotificationBatch()` /
/// `endNotificationBatch()` (the trailing flush already exists).
final class OptimisticCommitAtomicityTests: XCTestCase {

    private let query = """
        query GetProject($id: ID!) {
            project(id: $id) { id updatedAt tracks { id contentMuted } }
        }
        """

    private final class Emits: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [JSONValue] = []
        func append(_ v: JSONValue) { lock.lock(); items.append(v); lock.unlock() }
        var all: [JSONValue] { lock.lock(); defer { lock.unlock() }; return items }
    }

    func test_commit_is_atomic_for_watchers_even_with_midclosure_read() throws {
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst, suspensionTimeout: 0))

        // Baseline: track is NOT muted, updatedAt = t0.
        try client.writeQuery(
            query: query, variables: ["id": "p2"],
            data: .object([
                "project": .object([
                    "__typename": "Project", "id": "p2", "updatedAt": .string("t0"),
                    "tracks": .array([
                        .object(["__typename": "Track", "id": "music", "contentMuted": .bool(false)])
                    ]),
                ])
            ]))

        let emits = Emits()
        let handle = try client.watchQuery(
            query: query,
            options: WatchQueryOptions(
                variables: ["id": "p2"], immediate: true, onData: { emits.append($0) }))
        XCTAssertEqual(emits.all.count, 1, "immediate emit")

        // Optimistic layer: bump updatedAt + mute the track (atomic, already fixed).
        let tx = client.modifyOptimistic { b in
            b.patch(.key("Project:p2"), ["updatedAt": .string("opt")], mode: .merge)
            b.patch(.key("Track:music"), ["contentMuted": .bool(true)], mode: .merge)
        }
        XCTAssertEqual(
            emits.all.last?["project"]?["tracks"]?.array?.first?["contentMuted"]?.bool, true,
            "optimistic layer should have muted the track")
        let countAfterOptimistic = emits.all.count

        // Commit the server response. `commit` first rolls the track back to the
        // baseline (contentMuted = false), THEN the closure re-applies the
        // server-confirmed mute. A cache read between the two writes flushes the
        // rolled-back state — the track un-mutes for a frame. `graph.flush()`
        // here stands in for that internal read-flush.
        tx.commit { b in
            b.patch(.key("Project:p2"), ["updatedAt": .string("server")], mode: .merge)
            client.graph.flush()
            b.patch(.key("Track:music"), ["contentMuted": .bool(true)], mode: .merge)
        }

        // No emit after the optimistic layer may show the track un-muted again —
        // that transient (optimistic rolled back, server data not yet applied) is
        // the bug. The commit must be atomic for observers.
        let post = Array(emits.all.dropFirst(countAfterOptimistic))
        XCTAssertFalse(
            post.contains(where: {
                $0["project"]?["tracks"]?.array?.first?["contentMuted"]?.bool == false
            }),
            "watcher observed the track un-mute mid-commit (optimistic rolled back before server data applied) — commit is not atomic for observers")

        // Final state is fully applied.
        XCTAssertEqual(emits.all.last?["project"]?["updatedAt"]?.string, "server")
        XCTAssertEqual(
            emits.all.last?["project"]?["tracks"]?.array?.first?["contentMuted"]?.bool, true)

        handle.unsubscribe()
    }
}
