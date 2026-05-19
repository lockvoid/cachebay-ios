import Foundation

/// Cancellation handle returned by the callback-based `executeMutation`
/// / `executeQuery` / `executeSubscription` overloads.
///
/// Holding the token lets the caller `cancel()` an in-flight operation:
///
/// - For one-shot operations (mutation, query): cancels the underlying
///   detached `Task` that's driving the network call, and prevents any
///   not-yet-fired `onData` / `onError` callback from invoking the
///   consumer's handler.
/// - For long-lived subscriptions: same plus tears down the underlying
///   stream so no further frames arrive.
///
/// Discarding the token (the common case — fire-and-forget) is fine:
/// the operation runs to natural completion and callbacks fire as
/// usual. The token is decoratively `@discardableResult` on every
/// returning overload.
///
/// **Lifecycle isolation.** The token's internal task is created with
/// `Task.detached`, so it does NOT inherit the caller's structured
/// concurrency cancellation. A SwiftUI view tearing down between
/// `executeMutation(...)` and the server response does NOT cancel the
/// operation — that's the whole reason the sync overload exists. If
/// the caller wants the operation to abort on view teardown, they
/// explicitly hold the token and call `cancel()`.
///
/// `cancel()` is **idempotent** — calling it twice is harmless. It is
/// also safe to call from any thread (operations may complete on
/// background threads; their callbacks check `isCancelled` before
/// invoking the consumer's handler).
public final class CachebayToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    private var task: Task<Void, Never>?

    public init() {}

    /// Cancel the in-flight operation. Flips `isCancelled` to `true`
    /// synchronously, then cancels the internal task. Subsequent
    /// `onData` / `onError` callback fires will see `isCancelled` and
    /// no-op before invoking the consumer's handler.
    public func cancel() {
        lock.lock()
        let alreadyCancelled = _isCancelled
        _isCancelled = true
        let t = task
        lock.unlock()
        if !alreadyCancelled {
            t?.cancel()
        }
    }

    /// `true` once `cancel()` has been called.
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isCancelled
    }

    /// Internal: attach the driving task. Called by the sync overloads
    /// immediately after spawning the detached task. Honours a race
    /// where the caller managed to `cancel()` before the spawn returned
    /// (e.g. token captured in a view's onDisappear that fires the same
    /// tick the operation begins).
    internal func attachTask(_ t: Task<Void, Never>) {
        lock.lock()
        let alreadyCancelled = _isCancelled
        task = t
        lock.unlock()
        if alreadyCancelled {
            t.cancel()
        }
    }
}
