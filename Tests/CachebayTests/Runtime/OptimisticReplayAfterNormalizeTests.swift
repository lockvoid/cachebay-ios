import XCTest
@testable import Cachebay

/// Contract tests for **entity replay-after-normalize**.
///
/// Cachebay already replays pending optimistic ops on **connection
/// canonicals** when a server response normalizes into them — that's
/// why optimistic edges survive a paginate-after-cursor merge (the
/// `OptimisticReplayer` bridge in `Canonical.updateConnection`).
///
/// Until v0.9.1, **entities had no symmetric protection**. A server
/// response that normalized into an entity record (mutation response,
/// subscription frame, query refresh) would shallow-merge over any
/// pending optimistic patch on the same fields, silently clobbering
/// the user's optimistic state.
///
/// Concrete repro (the bug captured here):
///   1. Layer A patches `Clip:c1.captionsEnabled = true`.
///   2. Layer B patches `Clip:c1.volume = 0.5`.
///   3. Server response 1 normalizes the FULL `ClipFields` shape with
///      `volume: 1.0` (server didn't know about layer B yet).
///   4. Without replay: graph snaps to `volume: 1.0` — user sees a
///      flicker, layer B's patch is silently lost.
///   5. With replay (the fix): after normalize, layer B's recorded op
///      re-applies → graph stays at `volume: 0.5`.
///
/// Mirror of the chat-pipeline race fixed in v0.7.0 (link primitive
/// can't smuggle scalars), now closed on the symmetric axis: entity
/// fields can't be clobbered by server-response normalize while a
/// pending optimistic layer holds a write on them.
final class OptimisticReplayAfterNormalizeTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    // MARK: - The core race

    /// Two concurrent optimistic layers, one server-response normalize
    /// in between — both pending optimistic field values must survive.
    func test_pendingOptimisticFields_surviveServerNormalize() throws {
        let client = makeClient()

        // Seed Clip:c1 with baseline state.
        try client.writeFragment(
            id: "Clip:c1",
            fragment: "fragment C on Clip { id captionsEnabled volume }",
            data: .object([
                "__typename": .string("Clip"),
                "id": .string("c1"),
                "captionsEnabled": .bool(false),
                "volume": .double(1.0),
            ])
        )

        // Layer A: optimistically flip captionsEnabled to true.
        let txA = client.modifyOptimistic { b in
            b.patch(.key("Clip:c1"), ["captionsEnabled": .bool(true)], mode: .merge)
        }
        // Layer B: optimistically set volume to 0.5.
        let txB = client.modifyOptimistic { b in
            b.patch(.key("Clip:c1"), ["volume": .double(0.5)], mode: .merge)
        }

        XCTAssertEqual(client.graph.getField("Clip:c1", "captionsEnabled")?.bool, true)
        XCTAssertEqual(client.graph.getField("Clip:c1", "volume")?.double, 0.5)

        // Simulate the server response to mutation A. Server didn't
        // know about layer B's volume change yet, so the response
        // carries the pre-existing `volume: 1.0` alongside the field
        // mutation A targeted (captionsEnabled: true).
        //
        // Pre-fix this overwrites layer B's volume=0.5 with 1.0.
        // Post-fix the entity-replay step kicks in and re-applies
        // layer B's op, keeping volume=0.5.
        try client.writeFragment(
            id: "Clip:c1",
            fragment: "fragment C on Clip { id captionsEnabled volume }",
            data: .object([
                "__typename": .string("Clip"),
                "id": .string("c1"),
                "captionsEnabled": .bool(true),
                "volume": .double(1.0),
            ])
        )

        XCTAssertEqual(client.graph.getField("Clip:c1", "captionsEnabled")?.bool, true,
            "captionsEnabled must reflect the server-confirmed value")
        XCTAssertEqual(client.graph.getField("Clip:c1", "volume")?.double, 0.5,
            "Pending optimistic layer B's volume=0.5 must survive the server-response normalize. Pre-fix this fails with volume=1.0.")

        // Tidy: both layers dispose normally; final state preserved
        // because dispose doesn't restore baselines and replay-on-
        // normalize already converged the right answer.
        txA.dispose()
        txB.dispose()
        XCTAssertEqual(client.graph.getField("Clip:c1", "volume")?.double, 0.5)
    }

    // MARK: - Scoping: replay runs only for entities the normalize touched

    /// Replay must be scoped — a normalize that writes only `Clip:c1`
    /// must not trigger replays for `Clip:c2`. Otherwise unrelated
    /// optimistic ops would re-execute on every normalize.
    func test_replay_isScopedToEntitiesTouchedByNormalize() throws {
        let client = makeClient()

        try client.writeFragment(
            id: "Clip:c2",
            fragment: "fragment C on Clip { id volume }",
            data: .object([
                "__typename": .string("Clip"),
                "id": .string("c2"),
                "volume": .double(1.0),
            ])
        )

        // Optimistically patch BOTH c1 and c2.
        let tx = client.modifyOptimistic { b in
            b.patch(.key("Clip:c1"), ["volume": .double(0.5)], mode: .merge)
            b.patch(.key("Clip:c2"), ["volume": .double(0.7)], mode: .merge)
        }

        // Server normalize writes ONLY Clip:c1 (returning volume: 1.0).
        // Layer's c1 op must re-apply (within scope); layer's c2 op
        // must NOT re-apply gratuitously (out of scope — wasted work).
        // We can't directly observe "did c2's op re-apply unnecessarily"
        // beyond asserting the final state is correct, but we can pin
        // the final values to make sure the scope filter is honored.
        try client.writeFragment(
            id: "Clip:c1",
            fragment: "fragment C on Clip { id volume }",
            data: .object([
                "__typename": .string("Clip"),
                "id": .string("c1"),
                "volume": .double(1.0),
            ])
        )

        XCTAssertEqual(client.graph.getField("Clip:c1", "volume")?.double, 0.5,
            "in-scope (c1): replay re-applies optimistic volume=0.5")
        XCTAssertEqual(client.graph.getField("Clip:c2", "volume")?.double, 0.7,
            "out-of-scope (c2): optimistic volume=0.7 still visible (never touched by normalize)")

        tx.dispose()
    }

    // MARK: - Layer order: latest-id-wins on field conflicts

    /// Two layers patching the SAME field on the same record. After
    /// a normalize that touches that record, the latest layer's value
    /// must win the replay (consistent with normal layered-write
    /// semantics).
    func test_replay_appliesLayersInIdOrder_latestWins() throws {
        let client = makeClient()

        try client.writeFragment(
            id: "Clip:c1",
            fragment: "fragment C on Clip { id volume }",
            data: .object([
                "__typename": .string("Clip"),
                "id": .string("c1"),
                "volume": .double(1.0),
            ])
        )

        let tx1 = client.modifyOptimistic { b in
            b.patch(.key("Clip:c1"), ["volume": .double(0.3)], mode: .merge)
        }
        let tx2 = client.modifyOptimistic { b in
            b.patch(.key("Clip:c1"), ["volume": .double(0.5)], mode: .merge)
        }

        // Graph reflects layer 2 (latest).
        XCTAssertEqual(client.graph.getField("Clip:c1", "volume")?.double, 0.5)

        // Normalize a server response with volume=1.0.
        // Replay must run in layer-id order: layer 1 re-applies 0.3,
        // then layer 2 re-applies 0.5. Final: 0.5.
        try client.writeFragment(
            id: "Clip:c1",
            fragment: "fragment C on Clip { id volume }",
            data: .object([
                "__typename": .string("Clip"),
                "id": .string("c1"),
                "volume": .double(1.0),
            ])
        )

        XCTAssertEqual(client.graph.getField("Clip:c1", "volume")?.double, 0.5,
            "after replay, latest-id layer's value wins")

        tx1.dispose()
        tx2.dispose()
    }

    // MARK: - Multi-field merge: normalize wins on UNpatched fields

    /// A pending optimistic layer that patches only `volume` must NOT
    /// suppress the server's `captionsEnabled` update. Replay is per-op
    /// scoped — only fields a layer explicitly patched are re-applied;
    /// fields the layer didn't touch get the server-normalized value.
    func test_replay_preservesNonPatchedFieldsFromNormalize() throws {
        let client = makeClient()

        try client.writeFragment(
            id: "Clip:c1",
            fragment: "fragment C on Clip { id captionsEnabled volume }",
            data: .object([
                "__typename": .string("Clip"),
                "id": .string("c1"),
                "captionsEnabled": .bool(false),
                "volume": .double(1.0),
            ])
        )

        // Layer patches volume only.
        let tx = client.modifyOptimistic { b in
            b.patch(.key("Clip:c1"), ["volume": .double(0.5)], mode: .merge)
        }

        // Server response updates captionsEnabled (server-side change
        // the user didn't request) AND returns volume=1.0 (its current
        // server value).
        try client.writeFragment(
            id: "Clip:c1",
            fragment: "fragment C on Clip { id captionsEnabled volume }",
            data: .object([
                "__typename": .string("Clip"),
                "id": .string("c1"),
                "captionsEnabled": .bool(true),
                "volume": .double(1.0),
            ])
        )

        XCTAssertEqual(client.graph.getField("Clip:c1", "captionsEnabled")?.bool, true,
            "server-side update on a field the layer didn't patch must win the normalize")
        XCTAssertEqual(client.graph.getField("Clip:c1", "volume")?.double, 0.5,
            "layer's pending patch on `volume` must re-apply over the server's 1.0")

        tx.dispose()
    }

    // MARK: - Multiple entities in one normalize call

    /// A single normalize call that writes multiple entities triggers
    /// replay for EACH entity touched. Pin this so a multi-record
    /// payload doesn't degrade to "replay only the first" or similar.
    func test_replay_runsForEachEntity_inMultiEntityNormalize() throws {
        let client = makeClient()

        try client.writeFragment(
            id: "Clip:c1",
            fragment: "fragment C on Clip { id volume }",
            data: .object([
                "__typename": .string("Clip"),
                "id": .string("c1"),
                "volume": .double(1.0),
            ])
        )
        try client.writeFragment(
            id: "Clip:c2",
            fragment: "fragment C on Clip { id volume }",
            data: .object([
                "__typename": .string("Clip"),
                "id": .string("c2"),
                "volume": .double(1.0),
            ])
        )

        let tx = client.modifyOptimistic { b in
            b.patch(.key("Clip:c1"), ["volume": .double(0.3)], mode: .merge)
            b.patch(.key("Clip:c2"), ["volume": .double(0.7)], mode: .merge)
        }

        // Single normalize call that walks a tree carrying BOTH clips
        // as nested entities under a parent.
        try client.writeFragment(
            id: "Project:p1",
            fragment: """
            fragment P on Project {
              id
              clips {
                id
                volume
              }
            }
            """,
            data: .object([
                "__typename": .string("Project"),
                "id": .string("p1"),
                "clips": .array([
                    .object([
                        "__typename": .string("Clip"),
                        "id": .string("c1"),
                        "volume": .double(1.0),
                    ]),
                    .object([
                        "__typename": .string("Clip"),
                        "id": .string("c2"),
                        "volume": .double(1.0),
                    ]),
                ]),
            ])
        )

        XCTAssertEqual(client.graph.getField("Clip:c1", "volume")?.double, 0.3,
            "layer's volume=0.3 on c1 must re-apply")
        XCTAssertEqual(client.graph.getField("Clip:c2", "volume")?.double, 0.7,
            "layer's volume=0.7 on c2 must re-apply (both replays happen, not just one)")

        tx.dispose()
    }

    // MARK: - No pending layers: normalize is a pure no-op replay

    /// With no pending optimistic layers, replay-after-normalize is a
    /// no-op. The server response wins outright. Pins that the replay
    /// hook doesn't have hidden costs when nothing is optimistic.
    func test_normalize_unchanged_whenNoPendingLayers() throws {
        let client = makeClient()

        try client.writeFragment(
            id: "Clip:c1",
            fragment: "fragment C on Clip { id volume }",
            data: .object([
                "__typename": .string("Clip"),
                "id": .string("c1"),
                "volume": .double(1.0),
            ])
        )

        // Second writeFragment writes a new value with no layers pending.
        try client.writeFragment(
            id: "Clip:c1",
            fragment: "fragment C on Clip { id volume }",
            data: .object([
                "__typename": .string("Clip"),
                "id": .string("c1"),
                "volume": .double(0.7),
            ])
        )

        XCTAssertEqual(client.graph.getField("Clip:c1", "volume")?.double, 0.7,
            "no pending layers → normalize wins unmodified")
    }

    // MARK: - Subscription frames: the most race-prone path

    /// Subscription auto-normalize is the path that originally
    /// motivated v0.7.0's `linkNode`-doesn't-write-scalars fix (the
    /// chat-pipeline `Created` / `Updated` race). The producer task
    /// inside `executeSubscription` normalizes each incoming WS frame
    /// **before** yielding to the user's `for await` loop, so any
    /// pending optimistic patch must survive those auto-normalize
    /// calls — otherwise a frame can silently clobber an in-flight
    /// optimistic edit between user-handler invocations.
    ///
    /// This test exercises the full subscription pipeline (transport
    /// → operations → documents.normalize → replayEntityOps hook) to
    /// pin the protection end-to-end.
    func test_subscriptionFrame_triggersEntityReplay() async throws {
        let ws = StageSubscriptionTransport()
        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport(), ws: ws),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))

        // Seed Post:p1 with baseline scalars.
        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title body }",
            data: .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("Original title"),
                "body": .string("Original body"),
            ])
        )

        // Optimistically patch `body` only — the field a future
        // subscription frame's stale data will threaten to clobber.
        let tx = client.modifyOptimistic { b in
            b.patch(.key("Post:p1"), ["body": .string("Drafting new body…")], mode: .merge)
        }

        // Set up a subscription. The producer task inside Cachebay
        // will auto-normalize every frame we push.
        let stream = try client.executeSubscription(
            query: "subscription { postUpdated { id title body } }",
            variables: [:]
        )
        let received = CaptureBox<Int>(value: 0)
        let consumer = Task<Void, Never> {
            do {
                for try await _ in stream {
                    received.value += 1
                }
            } catch { /* tolerate teardown */ }
        }
        // Let the Cachebay subscription producer-Task register its
        // continuation on the transport before we emit. Without this,
        // the emit can race the consumer setup and the first frame is
        // dropped.
        try await Task.sleep(nanoseconds: 30_000_000)

        // Server publishes a `postUpdated` frame carrying the OLD
        // body — server didn't know about the user's draft yet.
        // Pre-fix: normalize merges body="Original body" over the
        // optimistic patch. Post-fix: replay re-applies the patch.
        ws.emit(.object([
            "postUpdated": .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("Server-updated title"),
                "body": .string("Original body"),
            ])
        ]))
        // Wait briefly for the producer task to normalize the frame.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Server-updated title",
            "subscription frame's title update on an UNpatched field must land")
        XCTAssertEqual(client.graph.getField("Post:p1", "body")?.string, "Drafting new body…",
            "pending optimistic patch on `body` must survive the subscription auto-normalize")

        consumer.cancel()
        _ = await consumer.value
        tx.dispose()
    }

    /// Multiple subscription frames in a row, each potentially
    /// carrying stale data on a patched field. Each frame's normalize
    /// must independently replay the layer. Pin that the replay isn't
    /// "fire once then stop" — it must run per frame.
    func test_subscriptionFrames_eachTriggerReplay() async throws {
        let ws = StageSubscriptionTransport()
        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport(), ws: ws),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))

        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title likes }",
            data: .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("Original"),
                "likes": .int(0),
            ])
        )

        // Optimistically bump likes.
        let tx = client.modifyOptimistic { b in
            b.patch(.key("Post:p1"), ["likes": .int(42)], mode: .merge)
        }

        let stream = try client.executeSubscription(
            query: "subscription { postUpdated { id title likes } }",
            variables: [:]
        )
        let consumer = Task<Void, Never> {
            do {
                for try await _ in stream {}
            } catch {}
        }
        // Let the producer-Task register its WS continuation.
        try await Task.sleep(nanoseconds: 30_000_000)

        // 3 frames in a row, each carrying likes=0 (stale relative
        // to the optimistic patch). Each must trigger replay.
        for i in 0..<3 {
            ws.emit(.object([
                "postUpdated": .object([
                    "__typename": .string("Post"),
                    "id": .string("p1"),
                    "title": .string("Frame \(i)"),
                    "likes": .int(0),
                ])
            ]))
            try await Task.sleep(nanoseconds: 30_000_000)
            XCTAssertEqual(client.graph.getField("Post:p1", "likes")?.int, 42,
                "frame \(i): pending optimistic likes=42 must survive")
        }

        // Verify the server-updated field (title) reflects the LAST frame.
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Frame 2")

        consumer.cancel()
        _ = await consumer.value
        tx.dispose()
    }

    // MARK: - .replace mode entity ops survive normalize

    /// A layer that uses `.replace` mode rewrites the record outright
    /// (drops fields not in the patch). When replay re-applies a
    /// `.replace` op after normalize, the replace semantic must hold —
    /// the server-normalized fields the layer didn't include are
    /// dropped per the layer's intent.
    func test_replaceMode_replayDropsFieldsNotInLayerPatch() throws {
        let client = makeClient()

        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title body }",
            data: .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("Original"),
                "body": .string("Original body"),
            ])
        )

        // Layer issues a `.replace` patch — only id + typename + a
        // new title. Other fields must be gone after layer applies.
        let tx = client.modifyOptimistic { b in
            b.patch(.key("Post:p1"), [
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("Replaced"),
            ], mode: .replace)
        }

        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Replaced")
        XCTAssertNil(client.graph.getField("Post:p1", "body"),
            ".replace must drop fields outside the patch")

        // Server response normalize tries to re-introduce `body` and
        // change `title`. Replay re-applies the layer's `.replace`
        // op, dropping `body` and writing `title: "Replaced"` again.
        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title body }",
            data: .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("Server title"),
                "body": .string("Server body"),
            ])
        )

        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Replaced",
            ".replace layer's title must win over server normalize")
        XCTAssertNil(client.graph.getField("Post:p1", "body"),
            "`.replace` mode must drop server-normalized `body` because the layer's patch didn't include it")

        tx.dispose()
    }

    // MARK: - Mixed entity + connection ops in one normalize

    /// A normalize that touches both an entity AND a connection
    /// canonical (typical query refresh shape) must trigger BOTH
    /// entity-replay AND connection-replay. Pin that the two replay
    /// hooks don't interfere with each other and both run.
    func test_mixedOps_entityAndConnection_bothReplay() throws {
        let client = makeClient()

        // Seed Post:p1 and an empty connection canonical (the @connection
        // record is created by the first executeQuery / fragment write).
        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("Original"),
            ])
        )

        // Layer touches BOTH the entity and the connection canonical
        // in the same modifyOptimistic call.
        let tx = client.modifyOptimistic { b in
            // Entity op: patch the title.
            b.patch(.key("Post:p1"), ["title": .string("Optimistic title")], mode: .merge)
            // Connection op: link a brand-new optimistic post into the
            // posts connection.
            b.patch(.key("Post:tmp"), [
                "__typename": .string("Post"),
                "id": .string("tmp"),
            ], mode: .merge)
            b.connection(ConnectionSelector(key: "posts"))
                .linkNode(.key("Post:tmp"), options: LinkNodeOptions(position: .start))
        }

        // Server-cycle refresh: posts list returns ONLY Post:p1 with
        // its OLD title. Server didn't know about the optimistic
        // temp post nor about the title edit.
        try client.writeQuery(
            query: """
            query Posts {
              posts(first: 10) @connection(key: "posts") {
                pageInfo { hasNextPage hasPreviousPage }
                edges {
                  cursor
                  node { __typename id title }
                }
              }
            }
            """,
            data: .object([
                "posts": .object([
                    "__typename": .string("PostConnection"),
                    "pageInfo": .object([
                        "__typename": .string("PageInfo"),
                        "hasNextPage": .bool(false),
                        "hasPreviousPage": .bool(false),
                    ]),
                    "edges": .array([
                        .object([
                            "__typename": .string("PostEdge"),
                            "cursor": .string("c1"),
                            "node": .object([
                                "__typename": .string("Post"),
                                "id": .string("p1"),
                                "title": .string("Server title"),
                            ]),
                        ]),
                    ]),
                ])
            ])
        )

        // Entity replay must run: Post:p1.title stays "Optimistic title"
        // despite the server response carrying "Server title".
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Optimistic title",
            "entity replay: pending title patch must survive the canonical-page normalize")

        // Connection replay must run: the temp post stays linked at
        // start despite the server response not including it.
        let canonicalKey: CacheKey = "@connection.posts({})"
        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        let nodeRefs = edges.compactMap { client.graph.getField($0, "node")?.ref }
        XCTAssertTrue(nodeRefs.contains("Post:tmp"),
            "connection replay: optimistic temp post must still be linked after the canonical-page normalize")

        tx.dispose()
    }
}

// MARK: - Stage WS transport (subscription test seam)

/// Minimal subscription transport: lets a test push frames into every
/// active subscription. Mirrors the `StageWSTransport` pattern from
/// `WebSocketReconnectTests` but private to this file (single-shot
/// concerns).
private final class StageSubscriptionTransport: WSTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [Int: AsyncThrowingStream<OperationResult<JSONValue>, Error>.Continuation] = [:]
    private var nextID = 0

    func subscribe(_ context: WSContext) -> AsyncThrowingStream<OperationResult<JSONValue>, Error> {
        AsyncThrowingStream { continuation in
            self.lock.lock()
            self.nextID += 1
            let id = self.nextID
            self.streams[id] = continuation
            self.lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.streams.removeValue(forKey: id)
                self?.lock.unlock()
            }
        }
    }

    func emit(_ data: JSONValue) {
        lock.lock()
        let snapshot = streams.values
        lock.unlock()
        for c in snapshot { c.yield(OperationResult(data: data)) }
    }
}
