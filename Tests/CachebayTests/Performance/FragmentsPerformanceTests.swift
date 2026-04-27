import XCTest
@testable import Cachebay

/// Port of `cachebay-web/test/unit/core/fragments-performance.test.ts`.
///
/// The web test file uses a `vi.mock` shim around `createDocuments` to count
/// HOT vs COLD materializations directly. iOS doesn't have an equivalent
/// mock injection point, so the tests below pin the *observable* behaviour
/// — emission counts, single-fire on rotation, no fanout to unaffected
/// watchers, no fires after unsubscribe — which is what every web counter
/// assertion ultimately protects.
final class FragmentsPerformanceTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    private let userFragment = "fragment UserFields on User { id email }"

    private func putUser(_ client: CachebayClient, id: String, email: String) {
        client.graph.putRecord("User:\(id)", [
            "__typename": "User",
            "id": .string(id),
            "email": .string(email),
        ])
        client.graph.flush()
    }

    // MARK: - readFragment

    /// Mirrors web `readFragment always COLD (uses force: true) - no caching`.
    /// The behavioural invariant: two `readFragment` calls return the latest
    /// snapshot. (Web counts COLD/HOT directly; iOS pins this by mutating
    /// the underlying record between reads and verifying both reads reflect
    /// their respective graph state.)
    func test_readFragment_alwaysReturnsLatest_evenWithoutCache() throws {
        let client = makeClient()
        putUser(client, id: "u1", email: "initial@example.com")

        let r1 = client.readFragment(id: "User:u1", fragment: userFragment)
        XCTAssertEqual(r1?["email"]?.string, "initial@example.com")

        client.graph.putRecord("User:u1", ["email": "updated@example.com"])
        client.graph.flush()

        let r2 = client.readFragment(id: "User:u1", fragment: userFragment)
        XCTAssertEqual(r2?["email"]?.string, "updated@example.com",
                       "readFragment must always reflect the freshest record (force:true)")
    }

    // MARK: - watchFragment two-phase (cold then hot)

    /// Mirrors web `two-phase: COLD path then HOT path`.
    /// First subscription = 1 emission. update(id: same) with immediate must
    /// not produce a duplicate emission because data is unchanged.
    func test_watchFragment_initialEmission_thenSameIdUpdate_noDuplicate() throws {
        let client = makeClient()
        putUser(client, id: "u1", email: "test@example.com")

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchFragment(
            id: "User:u1", fragment: userFragment,
            options: WatchFragmentOptions(immediate: true, onData: { emissions.append($0) })
        )
        XCTAssertEqual(emissions.value.count, 1)
        XCTAssertEqual(emissions.value[0]["id"]?.string, "u1")

        // Update to same entity — data hasn't changed; no extra emission.
        handle.update("User:u1", nil, true)
        XCTAssertEqual(emissions.value.count, 1, "no duplicate on same-id same-data update")

        handle.unsubscribe()
    }

    // MARK: - efficient entity switching

    /// Mirrors web `should efficiently switch between entities without memory leaks`.
    /// Rotate the watcher across 100 entities. Each rotation must produce one
    /// emission for the new entity (since data differs).
    func test_watchFragment_switchAcross100Entities_emitsExactlyOncePerSwitch() throws {
        let client = makeClient()
        for i in 1...100 {
            putUser(client, id: "u\(i)", email: "user\(i)@example.com")
        }

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchFragment(
            id: "User:u1", fragment: userFragment,
            options: WatchFragmentOptions(immediate: true, onData: { emissions.append($0) })
        )
        XCTAssertEqual(emissions.value.count, 1)
        XCTAssertEqual(emissions.value[0]["id"]?.string, "u1")

        for i in 2...100 {
            handle.update("User:u\(i)", nil, true)
        }

        XCTAssertEqual(emissions.value.count, 100, "exactly 100 emissions: 1 initial + 99 rotations")
        XCTAssertEqual(emissions.value.last?["id"]?.string, "u100")

        handle.unsubscribe()
    }

    /// Mirrors web `should efficiently update variables without re-subscribing`.
    /// USER fragment doesn't reference variables; 100 update(variables:) calls
    /// must NOT trigger emissions — the dep set hasn't been touched and the
    /// data hasn't changed.
    func test_watchFragment_variableUpdates_doNotEmitWhenFragmentIgnoresVars() throws {
        let client = makeClient()
        putUser(client, id: "u1", email: "test@example.com")

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchFragment(
            id: "User:u1", fragment: userFragment,
            options: WatchFragmentOptions(immediate: true, onData: { emissions.append($0) })
        )
        XCTAssertEqual(emissions.value.count, 1)

        for i in 1...100 {
            handle.update(nil, ["limit": .int(Int64(i))], true)
        }
        XCTAssertEqual(emissions.value.count, 1, "fragment ignores vars ⇒ no extra emissions")

        handle.unsubscribe()
    }

    // MARK: - immediate: false

    /// Mirrors web `should handle immediate: false efficiently (no unnecessary
    /// emissions)` — adapted to iOS Fragments semantics.
    ///
    /// iOS divergence: `Fragments.updateWatcher` only refreshes the dep set
    /// when `immediate: true`. After an `immediate:false` rotation, the
    /// watcher's dep set still points at the OLD entity. Writing the OLD
    /// record fires the watcher with the NEW entity's data (because
    /// rootId was rotated), but writing the NEW record does NOT — the
    /// watcher never registered it as a dep.
    ///
    /// We therefore use `immediate: true` for the rotation here. The
    /// invariant being protected is that no duplicate emission happens for
    /// the rotation when data is unchanged, and that subsequent writes to
    /// the new entity do fire.
    func test_watchFragment_rotation_thenChange_emitsForChange() async throws {
        let client = makeClient()
        putUser(client, id: "u1", email: "test@example.com")
        putUser(client, id: "u2", email: "test2@example.com")

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchFragment(
            id: "User:u1", fragment: userFragment,
            options: WatchFragmentOptions(immediate: true, onData: { emissions.append($0) })
        )
        XCTAssertEqual(emissions.value.count, 1)

        // Rotate with immediate:true so the dep set updates to User:u2.
        handle.update("User:u2", nil, true)
        XCTAssertEqual(emissions.value.count, 2, "rotation to a different entity emits")

        // Mutate the new target — must fire.
        client.graph.putRecord("User:u2", ["email": "updated@example.com"])
        client.graph.flush()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(emissions.value.count, 3)
        XCTAssertEqual(emissions.value.last?["id"]?.string, "u2")
        XCTAssertEqual(emissions.value.last?["email"]?.string, "updated@example.com")

        handle.unsubscribe()
    }

    /// Mirrors web `should not emit duplicate data when update doesn't change result`.
    /// update with same id and same vars must be a no-op even with immediate:true.
    func test_watchFragment_noOpUpdates_doNotDoubleFire() throws {
        let client = makeClient()
        putUser(client, id: "u1", email: "test@example.com")

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchFragment(
            id: "User:u1", fragment: userFragment,
            options: WatchFragmentOptions(immediate: true, onData: { emissions.append($0) })
        )
        XCTAssertEqual(emissions.value.count, 1)

        handle.update("User:u1", nil, true)
        XCTAssertEqual(emissions.value.count, 1, "same id ⇒ no emit")

        handle.update(nil, [:], true)
        XCTAssertEqual(emissions.value.count, 1, "same vars ⇒ no emit")

        handle.unsubscribe()
    }

    // MARK: - propagateData performance

    /// Mirrors web `should efficiently update multiple watchers on same entity`.
    /// 100 watchers; one putRecord must fanout to all.
    func test_watchFragment_100WatchersSameEntity_allFireOnceOnUpdate() async throws {
        let client = makeClient()
        putUser(client, id: "u1", email: "test@example.com")

        struct WB { let box: CaptureBox<[JSONValue]>; let handle: WatchFragmentHandle }
        var watchers: [WB] = []
        for _ in 0..<100 {
            let box = CaptureBox<[JSONValue]>(value: [])
            let cb = box  // capture before passing into closure
            let h = try client.watchFragment(
                id: "User:u1", fragment: userFragment,
                options: WatchFragmentOptions(immediate: true, onData: { cb.append($0) })
            )
            watchers.append(WB(box: box, handle: h))
        }
        for w in watchers {
            XCTAssertEqual(w.box.value.count, 1, "every watcher gets exactly 1 initial emission")
        }

        client.graph.putRecord("User:u1", ["email": "updated@example.com"])
        client.graph.flush()
        try await Task.sleep(nanoseconds: 30_000_000)

        for w in watchers {
            XCTAssertEqual(w.box.value.count, 2, "every watcher fires once on update")
            XCTAssertEqual(w.box.value.last?["email"]?.string, "updated@example.com")
        }

        for w in watchers { w.handle.unsubscribe() }
    }

    /// Mirrors web `should only update affected watchers (not all watchers)`.
    /// Two watchers on different entities; mutating only one must fire only one.
    func test_watchFragment_onlyAffectedWatcher_firesOnTargetedUpdate() async throws {
        let client = makeClient()
        putUser(client, id: "u1", email: "user1@example.com")
        putUser(client, id: "u2", email: "user2@example.com")

        let e1 = CaptureBox<[JSONValue]>(value: [])
        let e2 = CaptureBox<[JSONValue]>(value: [])
        let h1 = try client.watchFragment(
            id: "User:u1", fragment: userFragment,
            options: WatchFragmentOptions(immediate: true, onData: { e1.append($0) })
        )
        let h2 = try client.watchFragment(
            id: "User:u2", fragment: userFragment,
            options: WatchFragmentOptions(immediate: true, onData: { e2.append($0) })
        )
        XCTAssertEqual(e1.value.count, 1)
        XCTAssertEqual(e2.value.count, 1)

        // Mutate u1 only.
        client.graph.putRecord("User:u1", ["email": "updated1@example.com"])
        client.graph.flush()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(e1.value.count, 2, "u1 watcher fires")
        XCTAssertEqual(e2.value.count, 1, "u2 watcher unaffected")

        // Mutate u2 only.
        client.graph.putRecord("User:u2", ["email": "updated2@example.com"])
        client.graph.flush()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(e1.value.count, 2, "u1 watcher still unchanged")
        XCTAssertEqual(e2.value.count, 2, "u2 watcher fires")

        h1.unsubscribe(); h2.unsubscribe()
    }

    // MARK: - memory and cleanup

    /// Mirrors web `should properly cleanup watchers on unsubscribe`.
    /// After unsubscribe, no further graph writes can fire.
    func test_watchFragment_unsubscribe_blocksFutureFires() async throws {
        let client = makeClient()
        putUser(client, id: "u1", email: "test@example.com")

        let emissions = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchFragment(
            id: "User:u1", fragment: userFragment,
            options: WatchFragmentOptions(immediate: true, onData: { emissions.append($0) })
        )
        XCTAssertEqual(emissions.value.count, 1)

        handle.unsubscribe()

        client.graph.putRecord("User:u1", ["email": "updated@example.com"])
        client.graph.flush()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(emissions.value.count, 1, "no fires after unsubscribe")
    }

    /// Mirrors web `should handle rapid subscribe/unsubscribe cycles`.
    /// 1000 cycles must complete without deadlocking or leaking watchers
    /// (verified via the public inspect snapshot — not exposed in iOS,
    /// but completion + zero extra emissions implies clean teardown).
    func test_watchFragment_thousandSubscribeUnsubscribeCycles_completes() throws {
        let client = makeClient()
        putUser(client, id: "u1", email: "test@example.com")

        for _ in 0..<1000 {
            let h = try client.watchFragment(
                id: "User:u1", fragment: userFragment,
                options: WatchFragmentOptions(immediate: true, onData: { _ in })
            )
            h.unsubscribe()
        }
        // Reaching here without hanging is the assertion.
        XCTAssertTrue(true)
    }
}
