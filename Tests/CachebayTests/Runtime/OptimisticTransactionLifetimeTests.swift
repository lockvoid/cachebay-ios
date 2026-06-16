import XCTest
@testable import Cachebay

/// `OptimisticTransaction` lifetime contract — v0.9.2.
///
/// Before v0.9.2: `OptimisticTransaction` was a `Sendable struct` of
/// closures. The actual layer it referenced lived in
/// `Optimistic.layers` (strong reference, kept alive by the array
/// entry). A caller that dropped `tx` without calling
/// `dispose()`/`commit()`/`revert()` leaked the layer permanently —
/// the layer kept replaying its entity ops on every subsequent
/// `documents.normalize` call (via the v0.9.1 replay hook), causing
/// unbounded phantom writes for the rest of the process lifetime.
///
/// v0.9.2 flips `OptimisticTransaction` to a `final class` whose
/// `deinit` auto-disposes if no explicit resolution ran. Combined
/// with a one-line idempotency guard on `Optimistic.commit(...)`,
/// this makes:
/// - dropping a tx safe (auto-dispose on last reference release),
/// - resolving a tx idempotent (double-dispose / double-commit /
///   double-revert are no-ops),
/// - explicit resolve followed by tx going out of scope safe (deinit's
///   dispose call is a no-op because the layer was already removed).
///
/// Verification strategy: drive the lifetime semantic through
/// **observable behavior** (replay-after-normalize would re-apply the
/// layer's ops if it were still pending), not by reading `layers`
/// directly. The bug is "leaked layers replay forever"; the fix is
/// "leaked layers get cleaned up"; the test asserts the cleanup.
final class OptimisticTransactionLifetimeTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
    }

    private func seedBaseline(_ client: CachebayClient, title: String = "Baseline") throws {
        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string(title),
            ])
        )
    }

    private func normalizeServerValue(_ client: CachebayClient, title: String) throws {
        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string(title),
            ])
        )
    }

    // MARK: - 1. Dropped tx auto-disposes

    /// A caller that opens a layer and drops the `tx` without
    /// resolving must not leak the layer. We observe this via the
    /// v0.9.1 replay hook: if the layer were still pending, a
    /// subsequent server-response normalize would have its writes
    /// clobbered by the layer's replay. After fix, the layer is
    /// auto-disposed → no replay → server-normalize wins.
    func test_droppedTransaction_autoDisposes() throws {
        let client = makeClient()
        try seedBaseline(client)

        do {
            // Open a layer, patch optimistically, drop the tx
            // immediately. Using `var tx: OptimisticTransaction? = …`
            // + `tx = nil` is the deterministic pattern for "drop
            // the only strong reference now"; Swift ARC doesn't
            // guarantee deinit at brace-end without it.
            var tx: OptimisticTransaction? = client.modifyOptimistic { b in
                b.patch(.key("Post:p1"), ["title": .string("Optimistic")], mode: .merge)
            }
            XCTAssertEqual(
                client.graph.getField("Post:p1", "title")?.string, "Optimistic",
                "optimistic patch is visible while tx is held")
            tx = nil
            _ = tx
        }

        // Server-response normalize. Pre-fix: layer's replay would
        // re-apply title="Optimistic", clobbering "ServerValue".
        // Post-fix: layer was auto-disposed, no replay, server wins.
        try normalizeServerValue(client, title: "ServerValue")
        XCTAssertEqual(
            client.graph.getField("Post:p1", "title")?.string, "ServerValue",
            "after dropped tx auto-disposes, the next server-normalize wins clean (no phantom replay)")
    }

    // MARK: - 2. Task cancellation disposes the layer

    /// A Task that opens a layer then awaits something cancellable
    /// (network, timer, …) and gets cancelled must not leak. The
    /// cancelled Task's frame unwinds, tx goes out of scope, deinit
    /// fires, layer is disposed.
    func test_taskCancellation_disposesLayer() async throws {
        let client = makeClient()
        try seedBaseline(client)

        let task = Task<Void, Error> { @Sendable in
            let tx = client.modifyOptimistic { b in
                b.patch(.key("Post:p1"), ["title": .string("Optimistic")], mode: .merge)
            }
            // Cancellable sleep — when the task is cancelled, this
            // throws CancellationError, the frame unwinds, `tx` drops.
            try await Task.sleep(nanoseconds: 5_000_000_000)
            // This line is never reached if cancelled before sleep ends.
            tx.dispose()
        }

        // Let the Task start + apply its optimistic patch.
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(
            client.graph.getField("Post:p1", "title")?.string, "Optimistic",
            "tx is live; optimistic patch visible")

        task.cancel()
        _ = try? await task.value

        // After the cancelled Task's frame unwound, tx was released
        // → auto-dispose → no replay on next normalize.
        try normalizeServerValue(client, title: "ServerValue")
        XCTAssertEqual(
            client.graph.getField("Post:p1", "title")?.string, "ServerValue",
            "task-cancellation-released tx must auto-dispose")
    }

    // MARK: - 3. Thrown error between open and resolve disposes the layer

    /// The classic "forgot the error path" leak: open a layer, do some
    /// work that throws, never reach the resolve site. The catch
    /// rejoins the caller's flow; the local `tx` was released as part
    /// of stack unwinding; deinit fires; layer cleaned up.
    func test_throwBetweenOpenAndResolve_disposesLayer() throws {
        let client = makeClient()
        try seedBaseline(client)

        enum TestError: Error { case oops }

        do {
            let tx = client.modifyOptimistic { b in
                b.patch(.key("Post:p1"), ["title": .string("Optimistic")], mode: .merge)
            }
            _ = tx  // ensure compiler doesn't optimize the reference away
            // Simulate an error path that fires before the caller's
            // explicit tx.commit/revert.
            throw TestError.oops
        } catch {
            // tx scope ended on the throw; deinit ran.
        }

        try normalizeServerValue(client, title: "ServerValue")
        XCTAssertEqual(
            client.graph.getField("Post:p1", "title")?.string, "ServerValue",
            "thrown error released tx via stack unwind; layer auto-disposed")
    }

    // MARK: - 4. Explicit dispose + tx drop is idempotent (no double-resolve)

    /// `tx.dispose()` then tx goes out of scope. Deinit will call
    /// dispose again. The underlying `Optimistic.dispose(layer:)` is
    /// idempotent via `firstIndex` — second call is a no-op. Pin
    /// this so future refactors don't accidentally break it.
    func test_explicitDispose_thenTxDrop_isIdempotent() throws {
        let client = makeClient()
        try seedBaseline(client)

        do {
            let tx = client.modifyOptimistic { b in
                b.patch(.key("Post:p1"), ["title": .string("Optimistic")], mode: .merge)
            }
            tx.dispose()
            // tx goes out of scope → deinit calls dispose again.
            // Must not crash, must not corrupt internal state.
        }

        // Sanity: a fresh layer captures the post-dispose state as
        // its baseline; revert returns to that state. If deinit had
        // double-disposed and corrupted baselines, this would fail.
        let tx2 = client.modifyOptimistic { b in
            b.patch(.key("Post:p1"), ["title": .string("Second")], mode: .merge)
        }
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Second")
        tx2.revert()
        XCTAssertEqual(
            client.graph.getField("Post:p1", "title")?.string, "Optimistic",
            "post-double-dispose state intact; tx2's baseline = post-dispose state ('Optimistic')")
    }

    // MARK: - 5. Explicit commit + tx drop must not re-run the commit closure

    /// `tx.commit { … }` runs the commit closure once. When `tx`
    /// drops, deinit calls `dispose()` (not commit) — but the
    /// layer is already removed, so `Optimistic.dispose` is a no-op.
    /// Critical guarantee: the commit closure runs **exactly once**.
    func test_explicitCommit_thenTxDrop_runsCommitClosureExactlyOnce() throws {
        let client = makeClient()
        try seedBaseline(client)

        let commitRuns = CaptureBox<Int>(value: 0)

        do {
            let tx = client.modifyOptimistic { b in
                b.patch(.key("Post:p1"), ["title": .string("Optimistic")], mode: .merge)
            }
            tx.commit { b in
                commitRuns.value += 1
                b.patch(.key("Post:p1"), ["title": .string("Committed")], mode: .merge)
            }
            // tx out of scope → deinit. If commit closure ran again,
            // we'd see commitRuns == 2. With idempotency, it's 1.
        }

        XCTAssertEqual(
            commitRuns.value, 1,
            "commit closure must run exactly once even when deinit fires after explicit commit")
        XCTAssertEqual(
            client.graph.getField("Post:p1", "title")?.string, "Committed",
            "graph reflects the committed write, not a phantom re-run")
    }

    // MARK: - 6. Calling commit twice explicitly must run the closure once

    /// Direct test of `Optimistic.commit`'s idempotency guard:
    /// calling `tx.commit { … }` a second time after the layer has
    /// already been resolved must be a no-op. Closure provided to
    /// the second call must not run.
    func test_explicitCommit_calledTwice_runsClosureOnce() throws {
        let client = makeClient()
        try seedBaseline(client)

        let commitRuns = CaptureBox<Int>(value: 0)

        let tx = client.modifyOptimistic { b in
            b.patch(.key("Post:p1"), ["title": .string("Optimistic")], mode: .merge)
        }
        tx.commit { b in
            commitRuns.value += 1
            b.patch(.key("Post:p1"), ["title": .string("First")], mode: .merge)
        }
        tx.commit { b in
            commitRuns.value += 1
            b.patch(.key("Post:p1"), ["title": .string("Second")], mode: .merge)
        }

        XCTAssertEqual(
            commitRuns.value, 1,
            "commit-after-commit must be a no-op; second closure must not run")
        XCTAssertEqual(
            client.graph.getField("Post:p1", "title")?.string, "First",
            "graph holds the first commit's value; second commit's writes never landed")
    }

    // MARK: - 7. Indirect lifetime: tx held by an outer reference

    /// Real apps stash the `tx` on a view model / state object that's
    /// itself reference-counted. Releasing the outer object must
    /// cascade to disposing the layer.
    func test_outerReferenceRelease_cascadesToTxDisposal() throws {
        let client = makeClient()
        try seedBaseline(client)

        final class Holder: @unchecked Sendable {
            var tx: OptimisticTransaction?
        }

        do {
            var holder: Holder? = Holder()
            holder!.tx = client.modifyOptimistic { b in
                b.patch(.key("Post:p1"), ["title": .string("Optimistic")], mode: .merge)
            }
            XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Optimistic")
            holder = nil  // Release the Holder; its `tx` property drops; deinit cascade.
            _ = holder
        }

        try normalizeServerValue(client, title: "ServerValue")
        XCTAssertEqual(
            client.graph.getField("Post:p1", "title")?.string, "ServerValue",
            "Holder release cascaded to OptimisticTransaction deinit → layer auto-disposed")
    }
}
