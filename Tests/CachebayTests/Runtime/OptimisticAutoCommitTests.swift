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
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    /// AutoCommit runs the closure exactly once, in `.commit` phase.
    /// The standard form runs it twice (`.optimistic` + `.commit`).
    func test_autoCommit_runsClosureOnce_inCommitPhase() {
        let client = makeClient()
        let phaseRecord = AutoCommitPhaseLog()

        client.modifyOptimistic(autoCommit: true) { _, ctx in
            phaseRecord.append(phase: ctx.phase, hasData: ctx.data != nil)
        }

        let entries = phaseRecord.snapshot()
        XCTAssertEqual(entries.count, 1, "autoCommit must run closure exactly once, got \(entries.count) runs")
        XCTAssertEqual(entries[0].phase, .commit, "autoCommit phase must be .commit")
        XCTAssertFalse(entries[0].hasData, "autoCommit ctx.data must be nil (caller uses outer-scope data)")
    }

    /// Standard form (no autoCommit label): closure runs twice across
    /// the two-phase commit cycle. Sanity check that adding the
    /// autoCommit overload didn't accidentally change baseline
    /// behavior.
    func test_standardForm_runsClosureTwice_optimisticThenCommit() {
        let client = makeClient()
        let phaseRecord = AutoCommitPhaseLog()

        let tx = client.modifyOptimistic { _, ctx in
            phaseRecord.append(phase: ctx.phase, hasData: ctx.data != nil)
        }
        tx.commit(nil)

        let entries = phaseRecord.snapshot()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].phase, .optimistic)
        XCTAssertEqual(entries[1].phase, .commit)
    }

    /// Writes via the builder land on the base graph immediately —
    /// `client.graph.getRecord` must see them after the call returns.
    func test_autoCommit_writesLandOnBaseGraph() {
        let client = makeClient()

        client.modifyOptimistic(autoCommit: true) { b, _ in
            b.patch(.key("Project:42"), [
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
        let unrelated = client.modifyOptimistic { b, _ in
            b.patch(.key("Project:99"), [
                CachebayConstants.typenameField: .string("Project"),
                "id": .string("99"),
                "name": .string("Unrelated optimistic"),
            ], mode: .merge)
        }

        // AutoCommit a separate write.
        client.modifyOptimistic(autoCommit: true) { b, _ in
            b.patch(.key("Project:42"), [
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
        XCTAssertNil(client.graph.getRecord("Project:99"),
                     "unrelated optimistic layer revert should remove Project:99")
        XCTAssertEqual(client.graph.getRecord("Project:42")?["name"]?.string, "From autoCommit",
                       "autoCommit writes must NOT be reverted by an unrelated layer's revert — proves no layer was recorded")
    }

    /// AutoCommit + `b.connection(...).addNode(...)` writes the new
    /// edge into the canonical record without going through any
    /// optimistic-phase recording. Smoke for the create-project
    /// pattern after the refactor.
    func test_autoCommit_addNodeOnConnection_writesToCanonical() throws {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        // Pre-seed an empty canonical so addNode has somewhere to
        // attach the edge.
        client.graph.replaceRecord("\(canonicalKey).pageInfo", [
            CachebayConstants.typenameField: .string("PageInfo"),
            "hasNextPage": .bool(false),
            "hasPreviousPage": .bool(false),
        ])
        client.graph.replaceRecord(canonicalKey, [
            CachebayConstants.typenameField: .string("PostConnection"),
            CachebayConstants.connectionEdgesField: .refList([]),
            CachebayConstants.connectionPageInfoField: .ref("\(canonicalKey).pageInfo"),
        ])
        client.graph.flush()

        client.modifyOptimistic(autoCommit: true) { b, _ in
            b.connection(key: canonicalKey).addNode(
                [
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p1"),
                    "title": .string("From server"),
                ],
                options: AddNodeOptions(position: .end)
            )
        }

        let edgeRefs = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edgeRefs.count, 1, "autoCommit addNode must land an edge on the canonical")
        let edgeNode = client.graph.getField(edgeRefs[0], "node")?.ref
        XCTAssertEqual(edgeNode, "Post:p1")
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "From server")
    }
}

/// Sendable log of phase observations across @Sendable closure calls.
private final class AutoCommitPhaseLog: @unchecked Sendable {
    struct Entry: Sendable {
        let phase: BuilderPhase
        let hasData: Bool
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    func append(phase: BuilderPhase, hasData: Bool) {
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(phase: phase, hasData: hasData))
    }
    func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}
