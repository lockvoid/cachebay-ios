import XCTest
@testable import Cachebay

/// `Optimistic.replay(connectionKeys:)` return value — `ReplayResult`
/// captures which entity keys were added (`linkNode`) and which were
/// removed (`unlinkNode`) within the scope of the replay. Mirrors
/// cachebay-web's `replayOptimistic({connections}) → {added, removed}`
/// (`optimistic.test.ts:663` "returns added and removed nodes for
/// scoped connections" and `:725` "remains idempotent for the same
/// connection scope").
///
/// Used by the Canonical merger to know which optimistic ops landed
/// during a replay pass so it can re-emit watcher notifications for
/// just those entities.
final class OptimisticReplayResultTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    /// Web `optimistic.test.ts:663`. Replay scoped to connection A
    /// reports the entities added under A and the entities removed
    /// under A; entities under unscoped connections are not reported.
    func test_replay_scopedToConnection_reportsAddedAndRemoved() {
        let client = makeClient()
        let keyA: CacheKey = "@connection.posts.A({})"
        let keyB: CacheKey = "@connection.posts.B({})"

        // Pre-seed empty canonicals for both A and B so linkNode lands.
        let pageInfoA: CacheKey = "\(keyA).pageInfo"
        let pageInfoB: CacheKey = "\(keyB).pageInfo"
        for (canonical, pi) in [(keyA, pageInfoA), (keyB, pageInfoB)] {
            client.graph.replaceRecord(pi, [
                CachebayConstants.typenameField: .string("PageInfo"),
                "hasNextPage": .bool(false),
                "hasPreviousPage": .bool(false),
            ])
            client.graph.replaceRecord(canonical, [
                CachebayConstants.typenameField: .string("Connection"),
                CachebayConstants.connectionEdgesField: .refList([]),
                CachebayConstants.connectionPageInfoField: .ref(pi),
            ])
        }
        client.graph.flush()

        // One transaction adds Post:p1 to A and removes Post:p99 from B.
        // (p99 doesn't actually exist; unlinkNode is a no-op as a graph
        // mutation but should still register as an op for the layer.)
        let _tx = client.modifyOptimistic { b in
            b.connection(key: keyA).linkNode(
                .object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p1"),
                ]),
                options: LinkNodeOptions(position: .end)
            )
            b.connection(key: keyB).unlinkNode(.key("Post:p99"))
        }

        // Direct access to the underlying `Optimistic` for replay assertion.
        let resultA = client.optimistic.replay(connectionKeys: [keyA])
        XCTAssertTrue(resultA.linked.contains("Post:p1"), "linked must contain Post:p1, got \(resultA.linked)")
        XCTAssertTrue(resultA.unlinked.isEmpty, "scoped to A, unlinked must be empty, got \(resultA.unlinked)")

        let resultBoth = client.optimistic.replay(connectionKeys: [keyA, keyB])
        XCTAssertTrue(resultBoth.linked.contains("Post:p1"))
        XCTAssertTrue(resultBoth.unlinked.contains("Post:p99"),
                      "scoped to both, unlinked must include Post:p99, got \(resultBoth.unlinked)")
        withExtendedLifetime(_tx) {}
    }

    /// Web `optimistic.test.ts:725` "remains idempotent for the same
    /// connection scope". Replay returns the same added/removed set
    /// every time it's called for a stable layer set.
    func test_replay_idempotentForSameScope() {
        let client = makeClient()
        let key: CacheKey = "@connection.posts({})"
        let pageInfoKey: CacheKey = "\(key).pageInfo"
        client.graph.replaceRecord(pageInfoKey, [
            CachebayConstants.typenameField: .string("PageInfo"),
            "hasNextPage": .bool(false),
            "hasPreviousPage": .bool(false),
        ])
        client.graph.replaceRecord(key, [
            CachebayConstants.typenameField: .string("Connection"),
            CachebayConstants.connectionEdgesField: .refList([]),
            CachebayConstants.connectionPageInfoField: .ref(pageInfoKey),
        ])
        client.graph.flush()

        let _tx = client.modifyOptimistic { b in
            let c = b.connection(key: key)
            c.linkNode(.object([
                CachebayConstants.typenameField: .string("Post"),
                "id": .string("p1"),
            ]), options: LinkNodeOptions(position: .end))
            c.linkNode(.object([
                CachebayConstants.typenameField: .string("Post"),
                "id": .string("p2"),
            ]), options: LinkNodeOptions(position: .end))
        }

        let r1 = client.optimistic.replay(connectionKeys: [key])
        let r2 = client.optimistic.replay(connectionKeys: [key])
        XCTAssertEqual(r1.linked, r2.linked)
        XCTAssertEqual(r1.unlinked, r2.unlinked)
        XCTAssertEqual(r1.linked, ["Post:p1", "Post:p2"])
        XCTAssertTrue(r1.unlinked.isEmpty)
        withExtendedLifetime(_tx) {}
    }

    /// Replay with an empty `connectionKeys` array applies all ops
    /// across all connections (unscoped) and returns the union.
    func test_replay_emptyScope_isUnscoped() {
        let client = makeClient()
        let keyA: CacheKey = "@connection.posts.A({})"
        let keyB: CacheKey = "@connection.posts.B({})"
        for k in [keyA, keyB] {
            client.graph.replaceRecord("\(k).pageInfo", [
                CachebayConstants.typenameField: .string("PageInfo"),
                "hasNextPage": .bool(false),
                "hasPreviousPage": .bool(false),
            ])
            client.graph.replaceRecord(k, [
                CachebayConstants.typenameField: .string("Connection"),
                CachebayConstants.connectionEdgesField: .refList([]),
                CachebayConstants.connectionPageInfoField: .ref("\(k).pageInfo"),
            ])
        }
        client.graph.flush()

        let _tx = client.modifyOptimistic { b in
            b.connection(key: keyA).linkNode(.object([
                CachebayConstants.typenameField: .string("Post"),
                "id": .string("p1"),
            ]), options: LinkNodeOptions(position: .end))
            b.connection(key: keyB).linkNode(.object([
                CachebayConstants.typenameField: .string("Post"),
                "id": .string("p2"),
            ]), options: LinkNodeOptions(position: .end))
        }

        let result = client.optimistic.replay(connectionKeys: [])
        XCTAssertEqual(result.linked, ["Post:p1", "Post:p2"],
                       "unscoped replay must report both, got \(result.linked)")
        withExtendedLifetime(_tx) {}
    }
}
