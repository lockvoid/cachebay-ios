import Observation
import Foundation
import Cachebay

/// The observable state behind `@CachebayQuery`. Drives a single `client.watch`
/// subscription and reconciles variable changes **in place** via the watcher's
/// `update` (so filters and `@connection` pagination both work with no churn —
/// this is "`handle.update` for SwiftUI").
///
/// Testable in isolation: call `sync(client:variables:)` and read `data`/`error`/
/// `phase`. Cache emissions delivered on the main thread arrive synchronously.
@MainActor
@Observable
public final class CachebayQueryController<Op: CachebayOperation> {
    public enum Phase: Sendable { case loading, loaded, failed }

    public private(set) var data: Op.Data?
    public private(set) var error: CombinedError?
    public private(set) var phase: Phase = .loading

    // `nonisolated(unsafe)`: WatchQueryHandle is Sendable; we touch `handle` from the
    // main actor (sync/stop) and from `deinit` (nonisolated). `subscribed` is only
    // ever read/written on the main actor.
    @ObservationIgnored nonisolated(unsafe) private var handle: WatchQueryHandle?
    @ObservationIgnored private var subscribed: [String: JSONValue]?

    public nonisolated init() {}

    /// (Re)subscribe, or swap variables in place when they change. Idempotent per
    /// render — called from the property wrapper's `update()`.
    public func sync(client: CachebayClient, variables: Op.Variables) {
        let bridged = variables.__cachebay
        if handle == nil {
            subscribed = bridged
            if data == nil { phase = .loading }
            do {
                handle = try client.watch(
                    Op.self,
                    variables: variables,
                    immediate: true,
                    onData: { [weak self] d in self?.deliver { self?.apply(d) } },
                    onError: { [weak self] e in self?.deliver { self?.applyError(e) } }
                )
            } catch {
                applyError(CombinedError(networkError: error))
            }
        } else if bridged != subscribed {
            // Variables changed (filter swap, or pagination cursor advance).
            subscribed = bridged
            handle?.update(bridged, true)
        }
    }

    /// Tear down the subscription. The property wrapper relies on `@State`
    /// deallocation + `deinit`; call this explicitly for manual lifecycles.
    public func stop() {
        handle?.unsubscribe()
        handle = nil
        subscribed = nil
    }

    deinit {
        handle?.unsubscribe()
    }

    private func apply(_ d: Op.Data) {
        data = d
        error = nil
        phase = .loaded
    }

    private func applyError(_ e: CombinedError) {
        error = e
        phase = .failed
    }

    /// Deliver an update on the main actor. Cache emissions that fire on the main
    /// thread (e.g. the `immediate` read during `sync`) are applied synchronously;
    /// background emissions hop to the main queue (FIFO-ordered).
    nonisolated private func deliver(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
    }
}
