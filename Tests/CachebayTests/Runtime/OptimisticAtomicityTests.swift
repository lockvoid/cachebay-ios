import XCTest

@testable import Cachebay

/// Confirm-first: is a single `modifyOptimistic` layer ATOMIC for watchers?
///
/// Reported from ferment-cuts: inside ONE `modifyOptimistic` closure that issues
/// multiple patches, a query watcher re-fired BETWEEN patches and materialized a
/// half-applied layer (a track mute flipped back for a frame). The trigger is a
/// cache READ inside the closure — `materialize`/`readQuery` call `graph.flush()`
/// (Documents.swift:619), which delivers the patches applied so far to watchers.
///
/// This test reproduces that with a real mid-closure `readQuery`. It should FAIL
/// until `modifyOptimistic` coalesces watcher notifications to the closure
/// boundary (atomic-for-observers).
final class OptimisticAtomicityTests: XCTestCase {

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

    func test_modifyOptimistic_is_atomic_for_watchers_even_with_midclosure_read() throws {
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst, suspensionTimeout: 0))

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

        // ONE optimistic layer: bump Project.updatedAt, then (realistically) read
        // the cache to compute the next patch, then mute the track. The read
        // mid-closure currently flushes the first patch to watchers.
        let opt = client.modifyOptimistic { b in
            b.patch(.key("Project:p2"), ["updatedAt": .string("t1")], mode: .merge)
            // A cache read inside the closure flushes internally (Documents.swift:619);
            // `graph.flush()` here stands in for that. It must NOT deliver a partial
            // layer to watchers — the layer is atomic for observers.
            client.graph.flush()
            b.patch(.key("Track:music"), ["contentMuted": .bool(true)], mode: .merge)
        }

        // No emit may show the HALF-APPLIED layer: updatedAt bumped but the track
        // mute not yet applied. That transient is the reported bug.
        func halfApplied(_ d: JSONValue) -> Bool {
            let bumped = d["project"]?["updatedAt"]?.string == "t1"
            let muted = d["project"]?["tracks"]?.array?.first?["contentMuted"]?.bool ?? false
            return bumped && !muted
        }
        let post = Array(emits.all.dropFirst())
        XCTAssertFalse(
            post.contains(where: halfApplied),
            "watcher observed a half-applied optimistic layer (updatedAt bumped, track mute reverted) — the layer is not atomic for observers")

        // Final state is fully applied.
        XCTAssertEqual(emits.all.last?["project"]?["updatedAt"]?.string, "t1")
        XCTAssertEqual(emits.all.last?["project"]?["tracks"]?.array?.first?["contentMuted"]?.bool, true)

        opt.dispose()
        handle.unsubscribe()
    }
}
