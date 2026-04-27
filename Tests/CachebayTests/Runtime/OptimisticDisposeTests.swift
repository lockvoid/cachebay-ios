import XCTest
@testable import Cachebay

/// `OptimisticTransaction.dispose()` — drops the layer without
/// restoring baselines or re-running the builder. Use when the
/// server's response was already normalized into the cache and the
/// pre-optimistic baseline restoration would WIPE that normalize.
///
/// The motivating scenario (clone-clip in ferment-cuts):
///   1. Optimistic patch: bump `Project.updatedAt`.
///   2. `executeMutation` runs — server returns the full Project
///      including the new clips refList. Normalize writes it.
///   3. `commit(serverData)` would `replaceRecord` Project with the
///      pre-optimistic baseline → server's clips refList is wiped.
///   4. `dispose()` instead — drop the layer, leave the graph alone.
final class OptimisticDisposeTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    /// The bug-driving case: optimistic patches one field; server
    /// updates another field on the same entity (between optimistic
    /// and dispose). dispose() must NOT wipe the server's update.
    /// Standard `commit(_:)` would.
    func test_dispose_preservesServerUpdates_thatLandedAfterOptimisticPhase() {
        let client = makeClient()
        // Pre-seed Project:42 with two fields.
        client.graph.replaceRecord("Project:42", [
            CachebayConstants.typenameField: .string("Project"),
            "id": .string("42"),
            "name": .string("Original"),
            "clips": .refList(["TimelineClip:c1"]),
        ])
        client.graph.flush()

        // Optimistic phase: only patch `name`.
        let tx = client.modifyOptimistic { b, _ in
            b.patch(.key("Project:42"), ["name": .string("Optimistic")], mode: .merge)
        }
        XCTAssertEqual(client.graph.getField("Project:42", "name")?.string, "Optimistic")
        XCTAssertEqual(client.graph.getField("Project:42", "clips")?.refList, ["TimelineClip:c1"])

        // Simulate server-cycle normalize landing BETWEEN optimistic
        // and dispose: server updated `name` to its authoritative
        // value AND added a new clip to the refList.
        client.graph.putRecord("Project:42", [
            "name": .string("ServerName"),
            "clips": .refList(["TimelineClip:c1", "TimelineClip:c2-cloned"]),
        ])
        client.graph.flush()

        // Dispose — drop layer, don't revert anything.
        tx.dispose()

        // Both fields keep the server-authoritative values.
        XCTAssertEqual(client.graph.getField("Project:42", "name")?.string, "ServerName",
                       "dispose must NOT restore pre-optimistic 'name' = Original; server's value must survive")
        XCTAssertEqual(client.graph.getField("Project:42", "clips")?.refList,
                       ["TimelineClip:c1", "TimelineClip:c2-cloned"],
                       "dispose must NOT restore pre-optimistic 'clips' refList; server-added clip must survive")
    }

    /// Companion negative test: prove the equivalent `commit(_:)`
    /// flow has the bug we're avoiding — restores baseline, wipes
    /// the server-side update. Pins the asymmetry between commit and
    /// dispose so future refactors can't accidentally swap the
    /// semantics.
    func test_commit_restoresPreOptimisticBaseline_wipingServerUpdates() {
        let client = makeClient()
        client.graph.replaceRecord("Project:42", [
            CachebayConstants.typenameField: .string("Project"),
            "id": .string("42"),
            "name": .string("Original"),
            "clips": .refList(["TimelineClip:c1"]),
        ])
        client.graph.flush()

        let tx = client.modifyOptimistic { b, _ in
            b.patch(.key("Project:42"), ["name": .string("Optimistic")], mode: .merge)
        }

        // Server normalize between optimistic and commit.
        client.graph.putRecord("Project:42", [
            "name": .string("ServerName"),
            "clips": .refList(["TimelineClip:c1", "TimelineClip:c2-cloned"]),
        ])
        client.graph.flush()

        tx.commit(nil)

        // The closure ran again at commit phase, repatching `name` to "Optimistic".
        // BUT the baseline restore wiped the server's `clips` update.
        XCTAssertEqual(client.graph.getField("Project:42", "clips")?.refList,
                       ["TimelineClip:c1"],
                       "commit's baseline restore wipes server-side clips update — this is the bug we use dispose() to avoid")
    }

    /// Disposing a layer that touches a different record than other
    /// pending layers leaves both untouched — dispose drops THIS
    /// layer's bookkeeping cleanly without affecting unrelated
    /// records.
    ///
    /// (Contract for the single-record-per-layer pattern, which is
    /// what ferment-cuts uses. Multi-layer-touching-same-record
    /// has deliberately fuzzy semantics: the global
    /// `committedBaselines` map is keyed by record, so two layers
    /// touching the same record share a baseline. Disposing one
    /// while another remains pending is supported but may lose the
    /// disposed layer's effects on a subsequent revert of the other —
    /// matches the single-layer-per-mutation pattern in production.)
    func test_dispose_layer_doesNotAffectUnrelatedLayers() {
        let client = makeClient()
        client.graph.replaceRecord("Project:42", [
            CachebayConstants.typenameField: .string("Project"),
            "id": .string("42"),
            "name": .string("Original"),
        ])
        client.graph.replaceRecord("Project:99", [
            CachebayConstants.typenameField: .string("Project"),
            "id": .string("99"),
            "name": .string("Other"),
        ])
        client.graph.flush()

        let l1 = client.modifyOptimistic { b, _ in
            b.patch(.key("Project:42"), ["name": .string("L1")], mode: .merge)
        }
        let l2 = client.modifyOptimistic { b, _ in
            b.patch(.key("Project:99"), ["name": .string("L2-other")], mode: .merge)
        }

        l1.dispose()

        // L1's optimistic value stayed (no revert happened).
        XCTAssertEqual(client.graph.getField("Project:42", "name")?.string, "L1")
        // L2 untouched.
        XCTAssertEqual(client.graph.getField("Project:99", "name")?.string, "L2-other")

        // L2 is still revertible — its own baseline (Project:99 →
        // "Other") is intact.
        l2.revert()
        XCTAssertEqual(client.graph.getField("Project:99", "name")?.string, "Other",
                       "L2.revert restores its own baseline; dispose of L1 doesn't affect L2's revert path")
    }

    /// Dispose drops the baseline only when no other layer touches
    /// the record. Verify that future reverts of other layers don't
    /// see a stale baseline after dispose.
    func test_dispose_dropsBaselineOnly_whenNoOtherLayerTouches() {
        let client = makeClient()
        client.graph.replaceRecord("Project:42", [
            CachebayConstants.typenameField: .string("Project"),
            "id": .string("42"),
            "name": .string("Original"),
        ])
        client.graph.flush()

        let l1 = client.modifyOptimistic { b, _ in
            b.patch(.key("Project:42"), ["name": .string("L1")], mode: .merge)
        }
        l1.dispose()

        // Reading internal state via behavior: a fresh modifyOptimistic
        // on the same record should capture its CURRENT state as the
        // new baseline (L1's old baseline was dropped).
        let l2 = client.modifyOptimistic { b, _ in
            b.patch(.key("Project:42"), ["name": .string("L2")], mode: .merge)
        }
        l2.revert()
        // After L2 revert, name should be "L1" (the state when L2
        // started capturing baseline) — NOT "Original" (L1's old
        // baseline). Proves L1's baseline was dropped on dispose.
        XCTAssertEqual(client.graph.getField("Project:42", "name")?.string, "L1",
                       "dispose dropped L1's baseline; L2's baseline = current state ('L1'); L2.revert() restores 'L1', not 'Original'")
    }
}
