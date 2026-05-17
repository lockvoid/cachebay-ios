import XCTest
@testable import Cachebay

/// Contract tests for the v0.8.0 split-closure `modifyOptimistic`.
///
/// **Old shape** (v0.7.x and earlier):
/// ```
/// let tx = client.modifyOptimistic { b, ctx in
///     switch ctx.phase {
///     case .optimistic: …
///     case .commit:     …  // ctx.data: JSONValue?
///     }
/// }
/// tx.commit(.object(serverData))
/// ```
///
/// **New shape**:
/// ```
/// let tx = client.modifyOptimistic { b in
///     // optimistic ops only — runs immediately + on replay
/// }
/// tx.commit { b in
///     // commit ops — runs once, captures from outer scope (typed)
/// }
/// ```
///
/// The split kills `BuilderContext`, `BuilderPhase`, and the
/// `JSONValue?` plumbing. Typed server payloads land in `commit { … }`
/// via ordinary Swift closure capture — no `ctx.data` unwrap, no
/// generic parameter on `modifyOptimistic`, no `OperationData` glue.
final class OptimisticSplitClosuresTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    // MARK: - Optimistic closure runs immediately, no `ctx` parameter

    func test_optimisticClosure_runsOnceImmediately() {
        let client = makeClient()
        let runCount = CaptureBox<Int>(value: 0)

        _ = client.modifyOptimistic { b in
            runCount.value += 1
            b.patch(.key("Post:p1"), ["title": .string("v1")], mode: .merge)
        }

        XCTAssertEqual(runCount.value, 1)
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "v1")
    }

    // MARK: - Recorded ops replay after a sibling commits / reverts

    /// The optimistic closure runs once at `modifyOptimistic` time;
    /// the layer's recorded ops are what get replayed when a sibling
    /// commits or reverts. Pin the contract: the closure does NOT
    /// re-execute, but the surviving layer's *effects* still appear
    /// on top of the restored baseline.
    func test_recordedOps_replayAfterSiblingCommitOrRevert() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object(["__typename": .string("Post"), "id": .string("p1"), "title": .string("Original")])
        )

        let tx1Runs = CaptureBox<Int>(value: 0)
        let tx1 = client.modifyOptimistic { b in
            tx1Runs.value += 1
            b.patch(.key("Post:p1"), ["title": .string("L1")], mode: .merge)
        }
        XCTAssertEqual(tx1Runs.value, 1)

        let tx2 = client.modifyOptimistic { b in
            b.patch(.key("Post:p1"), ["title": .string("L2")], mode: .merge)
        }
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "L2")

        // Commit tx2 with no commit-time work. Its baseline is
        // restored, then surviving layers' OPS replay on top.
        tx2.commit { _ in }

        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "L1",
            "tx1's recorded op must replay after tx2 commits")
        XCTAssertEqual(tx1Runs.value, 1,
            "tx1's optimistic closure runs ONCE (at modifyOptimistic time); replay uses recorded ops, not closure re-execution. got \(tx1Runs.value)")

        // Revert tx1 → baseline restored, no survivors → "Original".
        tx1.revert()
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Original")
        XCTAssertEqual(tx1Runs.value, 1,
            "revert does not re-run the closure either")
    }

    // MARK: - Commit closure runs once, captures typed payload from outer scope

    func test_commitClosure_runsOnceAndCapturesFromOuterScope() {
        let client = makeClient()

        struct Response: Sendable { let id: String; let title: String }
        let response = Response(id: "real-1", title: "Server Title")

        let optRuns = CaptureBox<Int>(value: 0)
        let commitRuns = CaptureBox<Int>(value: 0)

        let tx = client.modifyOptimistic { b in
            optRuns.value += 1
            b.patch(.key("Post:temp"), ["title": .string("Optimistic")], mode: .merge)
        }

        // Optimistic state visible.
        XCTAssertEqual(client.graph.getField("Post:temp", "title")?.string, "Optimistic")

        // Commit closure captures `response` from outer scope — no
        // ctx.data, no JSONValue unwrap, no generic parameter.
        tx.commit { b in
            commitRuns.value += 1
            b.patch(.key("Post:\(response.id)"),
                    ["title": .string(response.title)], mode: .merge)
        }

        XCTAssertEqual(commitRuns.value, 1, "commit closure runs exactly once")
        XCTAssertEqual(optRuns.value, 1,
            "committed layer's OPTIMISTIC closure must NOT re-run (the layer is gone)")

        // Real-id record carries the server data.
        XCTAssertEqual(client.graph.getField("Post:real-1", "title")?.string, "Server Title")

        // Temp record was baseline-restored to nil (it didn't exist
        // before the optimistic phase, so baseline is "no record").
        XCTAssertNil(client.graph.getRecord("Post:temp"),
            "temp-id record must be gone after commit — baseline-restore drops it")
    }

    // MARK: - Revert restores baseline + replays survivors

    func test_revert_restoresBaselineAndReplaysSurvivors() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object(["__typename": .string("Post"), "id": .string("p1"), "title": .string("Original")])
        )

        let tx1 = client.modifyOptimistic { b in
            b.patch(.key("Post:p1"), ["title": .string("L1")], mode: .merge)
        }
        let tx2 = client.modifyOptimistic { b in
            b.patch(.key("Post:p1"), ["title": .string("L2")], mode: .merge)
        }

        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "L2")

        tx2.revert()
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "L1",
            "after tx2 revert, tx1 must replay")

        tx1.revert()
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Original",
            "after both revert, baseline restored")
    }

    // MARK: - Dispose drops the layer without restoring baseline

    func test_dispose_dropsLayerWithoutRestore() {
        let client = makeClient()
        let tx = client.modifyOptimistic { b in
            b.patch(.key("Post:p1"), ["title": .string("Optimistic")], mode: .merge)
        }
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Optimistic")

        tx.dispose()
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Optimistic",
            "dispose() must NOT restore baseline — graph keeps optimistic value")
    }

    // MARK: - Connection: temp-id link in optimistic, real-id link in commit

    func test_connection_tempIdLink_thenCommitWithRealId() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        // Captured from "outer scope" (server response in real flows).
        let realId = "real-1"
        let realTitle = "Server-authored"

        let tempId = "temp-\(UUID().uuidString)"
        let tx = client.modifyOptimistic { b in
            // Bootstrap the temp entity (optimistic-create flow).
            b.patch(.key("Post:\(tempId)"),
                    [
                        "__typename": .string("Post"),
                        "id": .string(tempId),
                        "title": .string("Drafting…"),
                    ],
                    mode: .merge)
            b.connection(ConnectionSelector(key: "posts"))
                .linkNode(.key("Post:\(tempId)"),
                          options: LinkNodeOptions(position: .start))
        }

        // Optimistic edge in place.
        let edgesOpt = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edgesOpt.count, 1)

        // Commit: write real entity + link real id; baseline-restore
        // drops the temp entity AND the temp edge automatically.
        tx.commit { b in
            b.patch(.key("Post:\(realId)"),
                    [
                        "__typename": .string("Post"),
                        "id": .string(realId),
                        "title": .string(realTitle),
                    ],
                    mode: .merge)
            b.connection(ConnectionSelector(key: "posts"))
                .linkNode(.key("Post:\(realId)"),
                          options: LinkNodeOptions(position: .start))
        }

        // Final connection has exactly one edge — the real one.
        let edgesFinal = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edgesFinal.count, 1)
        let nodeRef = edgesFinal.first.flatMap { client.graph.getField($0, "node")?.ref }
        XCTAssertEqual(nodeRef, "Post:\(realId)",
            "after commit, the only edge must point at the real entity")

        // Temp record gone (baseline-restored).
        XCTAssertNil(client.graph.getRecord("Post:\(tempId)"))
        // Real record exists with server-authored fields.
        XCTAssertEqual(client.graph.getField("Post:\(realId)", "title")?.string, realTitle)
    }

    // MARK: - applyAutoCommit takes a single closure (no ctx, no phase)

    func test_applyAutoCommit_singleClosureForm() {
        let client = makeClient()
        let runs = CaptureBox<Int>(value: 0)

        client.modifyOptimistic(autoCommit: true) { b in
            runs.value += 1
            b.patch(.key("Post:p1"), ["title": .string("Done")], mode: .merge)
        }

        XCTAssertEqual(runs.value, 1, "autoCommit closure runs exactly once")
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Done")
    }

    // MARK: - The commit closure cannot re-execute the optimistic ops by mistake
    //
    // In the v0.7.x dual-phase API a common bug was forgetting to
    // guard with `if ctx.phase == .optimistic` and accidentally
    // running the optimistic ops on commit too. With split closures,
    // there is no shared closure body — so this class of bug
    // structurally cannot occur. Pin it as a guarantee:

    func test_commitOps_doNotInheritFromOptimisticOps() {
        let client = makeClient()
        let optWrites = CaptureBox<Int>(value: 0)
        let commitWrites = CaptureBox<Int>(value: 0)

        let tx = client.modifyOptimistic { b in
            optWrites.value += 1
            b.patch(.key("Post:p1"), ["title": .string("Opt")], mode: .merge)
        }
        tx.commit { b in
            commitWrites.value += 1
            b.patch(.key("Post:p1"), ["title": .string("Final")], mode: .merge)
        }

        XCTAssertEqual(optWrites.value, 1)
        XCTAssertEqual(commitWrites.value, 1)
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Final")
    }
}

