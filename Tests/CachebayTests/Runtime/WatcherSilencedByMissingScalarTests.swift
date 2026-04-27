import XCTest
@testable import Cachebay

/// Replication of a bug found in ferment-cuts-ios on 2026-04-27.
///
/// **Symptom:** A watcher subscribed to a connection query stops firing
/// after an optimistic `addNode` — the new tile silently fails to land
/// in the UI, even though the canonical record was correctly updated.
///
/// **Root cause:** `Documents.readScalar` sets `canonicalOK = false`
/// whenever a scalar field is missing from a present record. The
/// optimistic `insertEdge` only writes `__typename` + `node` ref; if the
/// caller doesn't pass `edge: ["cursor": ...]`, the synthetic edge has
/// no `cursor` scalar. Any watcher whose query selects `cursor` on
/// edges then sees materialize return `source = .none` and silently
/// swallows every subsequent dep change — until a network refetch
/// overwrites the canonical with a clean edge list.
///
/// **Web parity:** `cachebay-web`'s `readScalar` writes `undefined` and
/// records a dev-mode miss diagnostic, but does NOT fail `canonicalOK`.
/// Only entity-record misses and ref-link misses fail materialize. This
/// test pins that semantic on the iOS port so a future regression
/// silencing watchers gets caught synchronously instead of in production.
final class WatcherSilencedByMissingScalarTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    /// Runs the test body on a background queue with a hard deadline.
    /// Any internal deadlock or accidental wait will fail the test
    /// instead of hanging the test runner.
    private func runWithTimeout(
        _ timeout: TimeInterval = 2,
        file: StaticString = #file,
        line: UInt = #line,
        _ body: @escaping () throws -> Void
    ) {
        let sem = DispatchSemaphore(value: 0)
        var caught: Error?
        DispatchQueue.global(qos: .userInitiated).async {
            do { try body() } catch { caught = error }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            XCTFail("test exceeded \(timeout)s deadline — likely watcher silently swallowed an update or a lock deadlocked", file: file, line: line)
            return
        }
        if let caught {
            XCTFail("test threw: \(caught)", file: file, line: line)
        }
    }

    private let connectionQuery = """
    query Posts($first: Int) {
        posts(first: $first) @connection(mode: "infinite") {
            pageInfo { endCursor hasNextPage }
            edges {
                cursor
                node { id title }
            }
        }
    }
    """

    /// Seed the canonical via a normal write so all edges have proper
    /// `cursor` scalars — mirrors the steady state of the cache after a
    /// network response.
    private func seedTwoCleanEdges(_ client: CachebayClient) throws {
        try client.writeQuery(
            query: self.connectionQuery,
            variables: ["first": .int(10)],
            data: .object([
                "posts": .object([
                    "__typename": .string("PostConnection"),
                    "pageInfo": .object([
                        "__typename": .string("PageInfo"),
                        "endCursor": .string("c2"),
                        "hasNextPage": .bool(false),
                    ]),
                    "edges": .array([
                        .object([
                            "__typename": .string("PostEdge"),
                            "cursor": .string("c1"),
                            "node": .object([
                                "__typename": .string("Post"),
                                "id": .string("p1"),
                                "title": .string("First"),
                            ]),
                        ]),
                        .object([
                            "__typename": .string("PostEdge"),
                            "cursor": .string("c2"),
                            "node": .object([
                                "__typename": .string("Post"),
                                "id": .string("p2"),
                                "title": .string("Second"),
                            ]),
                        ]),
                    ]),
                ])
            ])
        )
    }

    func test_watcher_keeps_firing_after_addNode_without_cursor() {
      runWithTimeout {
        let client = self.makeClient()
        try self.seedTwoCleanEdges(client)

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: self.connectionQuery,
            options: WatchQueryOptions(
                variables: ["first": .int(10)],
                immediate: true,
                onData: { received.append($0) }
            )
        )

        // Initial materialize fires once with both clean edges.
        XCTAssertEqual(received.value.count, 1, "initial materialize should fire on watcher creation")

        // Now optimistically prepend a third post WITHOUT supplying
        // `cursor` in `edge:` — exactly what the user's
        // `b.connection(key:).addNode(node: created, ...)` does in
        // production. The synthetic edge gets `__typename` + `node` ref
        // and that's it; no `cursor` scalar lands on the edge record.
        let canonicalKey: CacheKey = "@connection.posts({})"
        client.modifyOptimistic { b, _ in
            b.connection(key: canonicalKey).addNode(
                [
                    "__typename": .string("Post"),
                    "id": .string("p3"),
                    "title": .string("Third"),
                ],
                options: AddNodeOptions(position: .start)
            )
        }.commit(nil)

        // Bug: with `canonicalOK = false on scalar miss`, the materialize
        // returns `source = .none` and the watcher never re-fires. The
        // expected behaviour matches cachebay-web: missing scalar is a
        // soft miss, materialize returns the data with `cursor =
        // undefined` on the optimistic edge, watcher fires.
        XCTAssertEqual(received.value.count, 2, "watcher must fire after optimistic addNode even when the synthetic edge lacks a `cursor` scalar")

        // Sanity-check the shape of the second emission: 3 edges, the
        // new node at the start, undefined cursor on the optimistic edge
        // is acceptable.
        guard let last = received.value.last,
              case .object(let root) = last,
              case .object(let posts) = root["posts"] ?? .undefined,
              case .array(let edges) = posts["edges"] ?? .undefined
        else {
            XCTFail("watcher data shape unexpected: \(received.value.last ?? .undefined)")
            return
        }
        XCTAssertEqual(edges.count, 3, "post-addNode watcher payload should contain all 3 edges")
        // Guard the per-index reads against an early-bail materialize —
        // a `Fatal error: Index out of range` here would crash the
        // background queue and force the deadline-exceeded fail message
        // to swallow the actual root cause.
        guard edges.count == 3 else { return }
        XCTAssertEqual(edges[0]["node"]?["id"]?.string, "p3", "the optimistic edge should be at the start")
        XCTAssertEqual(edges[1]["node"]?["id"]?.string, "p1")
        XCTAssertEqual(edges[2]["node"]?["id"]?.string, "p2")

        handle.unsubscribe()
      }
    }

    /// Companion test: a brand-new watcher created on a cache that
    /// already has an optimistic-added edge (no `cursor`) should still
    /// produce data on its initial materialize. Otherwise a return-to-
    /// list flow (close editor → projects view re-mounts → watcher
    /// re-creates) renders empty until the next network refetch.
    func test_initialMaterialize_succeedsWhenCanonicalHasOptimisticEdgeWithoutCursor() {
      runWithTimeout {
        let client = self.makeClient()
        try self.seedTwoCleanEdges(client)

        // Plant the optimistic-added edge before any watcher exists, so
        // the watcher's first read sees the mixed-shape canonical.
        let canonicalKey: CacheKey = "@connection.posts({})"
        client.modifyOptimistic { b, _ in
            b.connection(key: canonicalKey).addNode(
                [
                    "__typename": .string("Post"),
                    "id": .string("p3"),
                    "title": .string("Third"),
                ],
                options: AddNodeOptions(position: .start)
            )
        }.commit(nil)

        let received = CaptureBox<[JSONValue]>(value: [])
        _ = try client.watchQuery(
            query: self.connectionQuery,
            options: WatchQueryOptions(
                variables: ["first": .int(10)],
                immediate: true,
                onData: { received.append($0) }
            )
        )

        XCTAssertEqual(received.value.count, 1, "initial materialize must succeed even when an existing edge lacks `cursor`")
      }
    }

    /// Replication of a follow-up bug observed in ferment-cuts-ios on
    /// 2026-04-27: after the previous fixes, the projects list was still
    /// emptying out after the network refetch. Cause: `Canonical
    /// .applyInfiniteMode` deduped incoming edges against ALL existing
    /// edges — including the ones it was about to *discard* in leader
    /// mode (`after == nil && before == nil`). When stale optimistic-
    /// added edges happened to share node ids with the network's leader
    /// page, every incoming edge was treated as a duplicate, the
    /// existing was discarded by the splice, and the merged edge list
    /// came out empty. Watcher fired with `edgeCount=0` and the UI went
    /// blank.
    ///
    /// Web doesn't dedup at all in this path; iOS still does, but the
    /// dedup must only consider edges that will SURVIVE the splice
    /// (prefix + suffix). In leader mode no existing is kept so no
    /// dedup runs.
    func test_leaderMerge_doesNotDropIncomingThatSharesNodeWithStaleExisting() {
      runWithTimeout {
        let client = self.makeClient()

        // Plant stale optimistic edges (no `cursor`) for the same nodes
        // the network will later return.
        let canonicalKey: CacheKey = "@connection.posts({})"
        client.modifyOptimistic { b, _ in
            let c = b.connection(key: canonicalKey)
            c.addNode(["__typename": .string("Post"), "id": .string("p1"), "title": .string("Stale-1")], options: AddNodeOptions(position: .end))
            c.addNode(["__typename": .string("Post"), "id": .string("p2"), "title": .string("Stale-2")], options: AddNodeOptions(position: .end))
        }.commit(nil)

        // Now write a leader page (after=null) that returns the same two
        // nodes — same ids, so the buggy dedup would treat them as
        // duplicates of the to-be-discarded existing edges and produce
        // an empty merged list.
        try client.writeQuery(
            query: self.connectionQuery,
            variables: ["first": .int(10)],
            data: .object([
                "posts": .object([
                    "__typename": .string("PostConnection"),
                    "pageInfo": .object([
                        "__typename": .string("PageInfo"),
                        "endCursor": .string("c2"),
                        "hasNextPage": .bool(false),
                    ]),
                    "edges": .array([
                        .object([
                            "__typename": .string("PostEdge"),
                            "cursor": .string("c1"),
                            "node": .object([
                                "__typename": .string("Post"),
                                "id": .string("p1"),
                                "title": .string("Network-1"),
                            ]),
                        ]),
                        .object([
                            "__typename": .string("PostEdge"),
                            "cursor": .string("c2"),
                            "node": .object([
                                "__typename": .string("Post"),
                                "id": .string("p2"),
                                "title": .string("Network-2"),
                            ]),
                        ]),
                    ]),
                ])
            ])
        )

        // Materialize — must reflect the leader page (2 edges), not 0.
        let received = CaptureBox<[JSONValue]>(value: [])
        _ = try client.watchQuery(
            query: self.connectionQuery,
            options: WatchQueryOptions(
                variables: ["first": .int(10)],
                immediate: true,
                onData: { received.append($0) }
            )
        )

        guard let last = received.value.last,
              case .object(let root) = last,
              case .object(let posts) = root["posts"] ?? .undefined,
              case .array(let edges) = posts["edges"] ?? .undefined
        else {
            XCTFail("watcher data shape unexpected: \(received.value.last ?? .undefined)")
            return
        }
        XCTAssertEqual(edges.count, 2, "leader-mode merge must keep the network's edges, not drop them as duplicates of stale optimistic edges")
      }
    }
}
