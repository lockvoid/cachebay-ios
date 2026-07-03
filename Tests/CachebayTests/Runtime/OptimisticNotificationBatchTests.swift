import XCTest

@testable import Cachebay

/// Edge guards for the notification-batching mechanism behind optimistic
/// atomicity (`Graph.beginNotificationBatch`/`endNotificationBatch`; `flush()`
/// is a no-op while `notifySuspendDepth > 0`). Companion to
/// `OptimisticAtomicityTests` (modifyOptimistic) and
/// `OptimisticCommitAtomicityTests` (commit) — this file covers the paths those
/// two don't: `applyAutoCommit`, NESTED batches (the depth counter), the
/// cross-thread "a swallowed flush is recovered by the trailing flush"
/// invariant, and `evictAll()` mid-batch not stranding the counter.
final class OptimisticNotificationBatchTests: XCTestCase {

    private final class Emits: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [JSONValue] = []
        func append(_ v: JSONValue) { lock.lock(); items.append(v); lock.unlock() }
        var all: [JSONValue] { lock.lock(); defer { lock.unlock() }; return items }
        var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    }

    private let query = """
        query GetProject($id: ID!) {
            project(id: $id) { id updatedAt tracks { id contentMuted } }
        }
        """

    private func makeClient() -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst, suspensionTimeout: 0))
    }

    private func seed(_ client: CachebayClient) throws {
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
    }

    /// updatedAt bumped to "t1" but the track mute not yet applied — the
    /// transient that must never reach a watcher.
    private func halfApplied(_ d: JSONValue) -> Bool {
        let bumped = d["project"]?["updatedAt"]?.string == "t1"
        let muted = d["project"]?["tracks"]?.array?.first?["contentMuted"]?.bool ?? false
        return bumped && !muted
    }

    // MARK: - applyAutoCommit atomicity
    // (modifyOptimistic + commit each have a dedicated atomicity test; the
    // auto-commit path got the same begin/end wrap but had no guard.)

    func test_applyAutoCommit_is_atomic_for_watchers_even_with_midclosure_read() throws {
        let client = makeClient()
        try seed(client)

        let emits = Emits()
        let handle = try client.watchQuery(
            query: query,
            options: WatchQueryOptions(
                variables: ["id": "p2"], immediate: true, onData: { emits.append($0) }))
        XCTAssertEqual(emits.count, 1, "immediate emit")

        client.modifyOptimistic(autoCommit: true) { b in
            b.patch(.key("Project:p2"), ["updatedAt": .string("t1")], mode: .merge)
            client.graph.flush()  // stands in for a mid-closure materialize/read
            b.patch(.key("Track:music"), ["contentMuted": .bool(true)], mode: .merge)
        }

        let post = Array(emits.all.dropFirst())
        XCTAssertFalse(
            post.contains(where: halfApplied),
            "applyAutoCommit leaked a half-applied layer to the watcher")
        XCTAssertEqual(emits.all.last?["project"]?["updatedAt"]?.string, "t1")
        XCTAssertEqual(emits.all.last?["project"]?["tracks"]?.array?.first?["contentMuted"]?.bool, true)

        handle.unsubscribe()
    }

    // MARK: - Nested modifyOptimistic (the depth counter)
    //
    // The inner transaction's trailing `flush()` MUST stay suppressed by the
    // outer batch (depth 2→1, still >0). If the depth counter were broken — e.g.
    // the inner `endNotificationBatch` zeroed depth instead of decrementing — the
    // inner flush would fire while only the outer's first patch is applied,
    // delivering a half-applied layer. This test makes that window observable.

    func test_nested_modifyOptimistic_innerFlush_staysSuppressed_byOuterBatch() throws {
        let client = makeClient()
        try seed(client)

        let emits = Emits()
        let handle = try client.watchQuery(
            query: query,
            options: WatchQueryOptions(
                variables: ["id": "p2"], immediate: true, onData: { emits.append($0) }))
        XCTAssertEqual(emits.count, 1, "immediate emit")

        let outer = client.modifyOptimistic { b in
            b.patch(.key("Project:p2"), ["updatedAt": .string("t1")], mode: .merge)
            // Inner layer touches nothing relevant; its OWN trailing flush must be
            // swallowed because the outer batch still holds depth > 0. If it fired,
            // the watcher would observe updatedAt=t1 with the track still un-muted.
            let inner = client.modifyOptimistic { _ in
                client.graph.flush()
            }
            inner.dispose()
            b.patch(.key("Track:music"), ["contentMuted": .bool(true)], mode: .merge)
        }

        let post = Array(emits.all.dropFirst())
        XCTAssertFalse(
            post.contains(where: halfApplied),
            "nested optimistic batch leaked a half-applied layer — depth counter not honoring re-entrancy")
        XCTAssertEqual(emits.all.last?["project"]?["updatedAt"]?.string, "t1")
        XCTAssertEqual(emits.all.last?["project"]?["tracks"]?.array?.first?["contentMuted"]?.bool, true)

        outer.dispose()
        handle.unsubscribe()
    }

    // MARK: - evictAll during an open batch must not strand the counter
    //
    // (Judges the review claim that evictAll mid-batch leaves notifySuspendDepth
    // stuck > 0, silencing the graph forever.) evictAll clearing `pending` is its
    // job — wiping the cache shouldn't emit the doomed intermediate. What MUST
    // hold: the batch closes normally (endNotificationBatch balances the begin),
    // so a subsequent write still reaches watchers.

    func test_evictAll_duringBatch_doesNotStrandSuspendCounter() throws {
        let client = makeClient()
        try seed(client)

        let emits = Emits()
        let handle = try client.watchQuery(
            query: query,
            options: WatchQueryOptions(
                variables: ["id": "p2"], immediate: true, onData: { emits.append($0) }))
        XCTAssertEqual(emits.count, 1, "immediate emit")

        client.modifyOptimistic { b in
            b.patch(.key("Project:p2"), ["updatedAt": .string("t1")], mode: .merge)
            client.graph.evictAll()  // wipes records + pending; counter untouched
        }
        let countAfterEvict = emits.count

        // The graph must NOT be permanently silent: a fresh write reaches the
        // watcher. If the suspend counter were stranded > 0, this flush would be
        // a no-op and no emit would arrive.
        try client.writeQuery(
            query: query, variables: ["id": "p2"],
            data: .object([
                "project": .object([
                    "__typename": "Project", "id": "p2", "updatedAt": .string("t2"),
                    "tracks": .array([
                        .object(["__typename": "Track", "id": "music", "contentMuted": .bool(true)])
                    ]),
                ])
            ]))

        XCTAssertGreaterThan(
            emits.count, countAfterEvict,
            "graph went permanently silent after evictAll mid-batch — suspend counter stranded")
        XCTAssertEqual(emits.all.last?["project"]?["updatedAt"]?.string, "t2")

        handle.unsubscribe()
    }

    // MARK: - Cross-thread: a swallowed flush is recovered by the trailing flush
    //
    // `notifySuspendDepth` is GLOBAL across threads. While thread C holds a batch
    // open, an unrelated thread W's `flush()` is swallowed — W's write sits in the
    // shared `pending`. Deterministic (semaphore-ordered, no timing luck): W's
    // write+flush is forced to run strictly inside C's open window, then C ends
    // the batch and flushes once. The write must be DELIVERED (delayed/merged),
    // never lost.

    func test_swallowedCrossThreadFlush_recoveredByTrailingFlush() throws {
        let client = makeClient()
        try seed(client)
        let graph = client.graph

        let emits = Emits()
        let handle = try client.watchQuery(
            query: query,
            options: WatchQueryOptions(
                variables: ["id": "p2"], immediate: true, onData: { emits.append($0) }))
        XCTAssertEqual(emits.count, 1, "immediate emit")

        let writerStart = DispatchSemaphore(value: 0)
        let writerDone = DispatchSemaphore(value: 0)
        let controllerDone = DispatchSemaphore(value: 0)

        // Controller: open batch, let the writer run inside the window, then end
        // + single trailing flush at depth 0.
        // All three waits are bounded: a stalled leg must fail THIS test,
        // not deadlock two GCD threads + the test thread for the whole run.
        DispatchQueue.global(qos: .userInitiated).async {
            graph.beginNotificationBatch()  // depth = 1
            writerStart.signal()
            _ = writerDone.wait(timeout: .now() + 10)  // writer's putRecord+flush has happened (swallowed)
            graph.endNotificationBatch()  // depth = 0
            graph.flush()  // must drain the writer's pending key
            controllerDone.signal()
        }

        // Writer: its flush runs at depth == 1 → swallowed.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = writerStart.wait(timeout: .now() + 10)
            graph.putRecord("Project:p2", ["updatedAt": .string("crossthread-final")])
            graph.flush()  // no-op while suspended; key stays in pending
            writerDone.signal()
        }

        XCTAssertEqual(
            controllerDone.wait(timeout: .now() + 10), .success,
            "batch controller did not finish — cross-queue semaphore chain stalled")

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if emits.all.last?["project"]?["updatedAt"]?.string == "crossthread-final" { break }
            usleep(1000)
        }
        handle.unsubscribe()

        XCTAssertEqual(graph.getField("Project:p2", "updatedAt")?.string, "crossthread-final")
        XCTAssertEqual(
            emits.all.last?["project"]?["updatedAt"]?.string, "crossthread-final",
            "cross-thread write swallowed during an open batch was never delivered (orphaned in pending)")
    }
}
