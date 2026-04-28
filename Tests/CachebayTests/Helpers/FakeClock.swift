import Foundation

/// Test clock that doesn't sleep — pending sleeps are parked on
/// continuations and resumed when the test calls `advance(by:)` /
/// `advanceUntilQuiescent()`. Lets reconnect tests assert on the
/// exact backoff sequence without burning real wall-clock seconds.
///
/// Usage:
///
/// ```swift
/// let clock = FakeClock()
/// let ws = URLSessionWebSocketTransport(url: ..., clock: clock)
/// // ... kick off some operation that calls `clock.sleep(for: 0.5)` ...
/// await clock.advance(by: .seconds(0.5))   // unblocks the sleep
/// ```
///
/// Conforms to `Clock<Duration>` so it can be passed wherever the
/// transport accepts an `any Clock<Duration>`.
final class FakeClock: Clock, @unchecked Sendable {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Swift.Duration

    private let lock = NSLock()
    private var _now: Instant
    private var pending: [(deadline: Instant, continuation: CheckedContinuation<Void, Error>)] = []

    init(now: Instant = .now) {
        self._now = now
    }

    var now: Instant {
        lock.lock(); defer { lock.unlock() }
        return _now
    }

    var minimumResolution: Duration { .nanoseconds(1) }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        // Fast path: deadline already passed in fake time.
        if isPastInFakeTime(deadline) { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                if !registerPendingSleep(deadline: deadline, continuation: cont) {
                    cont.resume()
                }
            }
        } onCancel: {
            cancelAllPending()
        }
    }

    private func isPastInFakeTime(_ deadline: Instant) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return deadline <= _now
    }

    /// Returns true if the continuation was parked; false if the
    /// deadline was already past (caller resumes immediately).
    private func registerPendingSleep(deadline: Instant, continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if deadline <= _now { return false }
        pending.append((deadline, continuation))
        return true
    }

    private func cancelAllPending() {
        lock.lock()
        let toResume = pending
        pending.removeAll()
        lock.unlock()
        for (_, c) in toResume { c.resume(throwing: CancellationError()) }
    }

    /// Advance fake time by `duration`. Any pending sleep whose
    /// deadline is at or before the new `now` resumes synchronously
    /// (test code can `await` the resulting state transitions).
    func advance(by duration: Duration) {
        lock.lock()
        _now = _now.advanced(by: duration)
        let nowSnapshot = _now
        let firing = pending.filter { $0.deadline <= nowSnapshot }
        pending.removeAll { $0.deadline <= nowSnapshot }
        lock.unlock()
        for (_, cont) in firing { cont.resume() }
    }

    /// Resume all currently pending sleeps regardless of their deadline.
    /// Useful when a test wants to drain the entire reconnect sequence
    /// without computing exact intervals.
    func releaseAllPending() {
        lock.lock()
        let firing = pending
        pending.removeAll()
        lock.unlock()
        for (_, cont) in firing { cont.resume() }
    }

    /// Snapshot of the current pending-sleep count. Used by polling
    /// loops to decide when to advance time.
    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    /// Wait until at least one sleep is pending, then resume it.
    /// Polls quickly (10µs) — production tests typically resolve
    /// in <1ms because the transport's reconnector calls `sleep` from
    /// its own task and yields cooperatively.
    func waitForPendingSleepThenAdvance(by duration: Duration, timeout: Duration = .seconds(2)) async throws {
        let start = ContinuousClock.now
        while pendingCount == 0 {
            if ContinuousClock.now.duration(to: start) > timeout {
                throw FakeClockError.timeoutWaitingForSleep
            }
            try await Task.sleep(for: .microseconds(10))
        }
        advance(by: duration)
    }

    enum FakeClockError: Error { case timeoutWaitingForSleep }
}
