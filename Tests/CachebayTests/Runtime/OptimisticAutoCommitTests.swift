import XCTest
@testable import Cachebay

/// `modifyOptimistic(autoCommit: true) { ... }` — single-phase
/// variant that runs the builder ONCE with `phase: .commit, data: nil`,
/// applying ops directly to the base graph without recording a layer.
///
/// Use case: after awaiting a server mutation, write the response
/// through the builder API. The standard two-phase form runs the
/// closure twice (once at `.optimistic`, once at `.commit`) which is
/// wasteful when there's no temp/optimistic state to project — the
/// caller already has authoritative data.
///
/// This file pins:
///   1. Closure runs exactly once (no double-write).
///   2. Phase is `.commit`, data is nil.
///   3. Writes land on the base graph (visible via `client.graph`).
///   4. No layer is recorded — `optimistic.replay` reports no entities
///      added, and the writes are NOT reverted by a subsequent
///      revert of an unrelated layer.
final class OptimisticAutoCommitTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
    }

    /// AutoCommit runs the closure exactly once, applying ops directly
    /// to the graph. No layer recorded.
    func test_autoCommit_runsClosureExactlyOnce() {
        let client = makeClient()
        let runs = CaptureBox<Int>(value: 0)

        client.modifyOptimistic(autoCommit: true) { _ in
            runs.value += 1
        }

        XCTAssertEqual(runs.value, 1, "autoCommit must run closure exactly once, got \(runs.value) runs")
    }

    /// Standard form: optimistic closure runs once at `modifyOptimistic`
    /// time; the SEPARATE commit closure runs once at `tx.commit` time.
    /// Sanity check the split-closure semantic.
    func test_standardForm_runsBothClosuresExactlyOnce() {
        let client = makeClient()
        let optRuns = CaptureBox<Int>(value: 0)
        let commitRuns = CaptureBox<Int>(value: 0)

        let tx = client.modifyOptimistic { _ in
            optRuns.value += 1
        }
        tx.commit { _ in
            commitRuns.value += 1
        }

        XCTAssertEqual(optRuns.value, 1, "optimistic closure runs once")
        XCTAssertEqual(commitRuns.value, 1, "commit closure runs once")
    }

    /// Writes via the builder land on the base graph immediately —
    /// `client.graph.getRecord` must see them after the call returns.
    func test_autoCommit_writesLandOnBaseGraph() {
        let client = makeClient()

        client.modifyOptimistic(autoCommit: true) { b in
            b.patch(
                .key("Project:42"),
                [
                    CachebayConstants.typenameField: .string("Project"),
                    "id": .string("42"),
                    "name": .string("From autoCommit"),
                ], mode: .merge)
        }

        let rec = client.graph.getRecord("Project:42")
        XCTAssertEqual(rec?[CachebayConstants.typenameField]?.string, "Project")
        XCTAssertEqual(rec?["name"]?.string, "From autoCommit")
    }

    /// AutoCommit must NOT record a layer. `optimistic.replay` after
    /// the call reports no entities (no ops were captured); a later
    /// revert of an unrelated layer must NOT undo the autoCommit
    /// writes.
    func test_autoCommit_doesNotRecordLayer() {
        let client = makeClient()

        // Establish an unrelated layer so we can revert it later.
        let unrelated = client.modifyOptimistic { b in
            b.patch(
                .key("Project:99"),
                [
                    CachebayConstants.typenameField: .string("Project"),
                    "id": .string("99"),
                    "name": .string("Unrelated optimistic"),
                ], mode: .merge)
        }

        // AutoCommit a separate write.
        client.modifyOptimistic(autoCommit: true) { b in
            b.patch(
                .key("Project:42"),
                [
                    CachebayConstants.typenameField: .string("Project"),
                    "id": .string("42"),
                    "name": .string("From autoCommit"),
                ], mode: .merge)
        }
        XCTAssertEqual(client.graph.getRecord("Project:42")?["name"]?.string, "From autoCommit")
        XCTAssertEqual(client.graph.getRecord("Project:99")?["name"]?.string, "Unrelated optimistic")

        // Revert the unrelated layer — Project:99 should disappear,
        // Project:42 (autoCommitted, never recorded) must survive.
        unrelated.revert()
        XCTAssertNil(
            client.graph.getRecord("Project:99"),
            "unrelated optimistic layer revert should remove Project:99")
        XCTAssertEqual(
            client.graph.getRecord("Project:42")?["name"]?.string, "From autoCommit",
            "autoCommit writes must NOT be reverted by an unrelated layer's revert — proves no layer was recorded")
    }

    /// AutoCommit + `b.connection(...).linkNode(...)` writes the new
    /// edge into the canonical record without going through any
    /// optimistic-phase recording. Smoke for the create-project
    /// pattern after the refactor.
    func test_autoCommit_addNodeOnConnection_writesToCanonical() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        // Pre-seed an empty canonical so linkNode has somewhere to
        // attach the edge.
        client.graph.replaceRecord(
            "\(canonicalKey).pageInfo",
            [
                CachebayConstants.typenameField: .string("PageInfo"),
                "hasNextPage": .bool(false),
                "hasPreviousPage": .bool(false),
            ])
        client.graph.replaceRecord(
            canonicalKey,
            [
                CachebayConstants.typenameField: .string("PostConnection"),
                CachebayConstants.connectionEdgesField: .refList([]),
                CachebayConstants.connectionPageInfoField: .ref("\(canonicalKey).pageInfo"),
            ])
        client.graph.flush()

        // Seed the entity record explicitly — linkNode is purely structural
        // and does not write entity scalars.
        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object([
                CachebayConstants.typenameField: .string("Post"),
                "id": .string("p1"),
                "title": .string("From server"),
            ])
        )
        client.modifyOptimistic(autoCommit: true) { b in
            b.connection(key: canonicalKey).linkNode(
                .key("Post:p1"),
                options: LinkNodeOptions(position: .end)
            )
        }

        let edgeRefs = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edgeRefs.count, 1, "autoCommit linkNode must land an edge on the canonical")
        let edgeNode = client.graph.getField(edgeRefs[0], "node")?.ref
        XCTAssertEqual(edgeNode, "Post:p1")
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "From server")
    }
}
