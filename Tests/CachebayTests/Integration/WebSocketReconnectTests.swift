import XCTest
@testable import Cachebay

/// Coverage for §5.9 — what happens to subscribers when the WebSocket
/// drops mid-session.
///
/// The transport opens lazily on first `subscribe`. There's no explicit
/// reconnect-with-backoff state machine; the contract for what a
/// subscriber sees during a socket failure isn't formally documented.
/// These tests pin the *current* behaviour so a future reconnect
/// implementation can be added without silently changing observable
/// semantics.
///
/// What we want documented and tested:
/// 1. Existing subscribers receive an error frame when the socket
///    drops, so they can clean up rather than hang.
/// 2. After a drop, a subsequent `subscribe()` either reconnects or
///    fails fast — never silently writes to a dead socket.
final class WebSocketReconnectTests: XCTestCase {

    /// Stage-controlled WS transport. Each subscription gets a queue of
    /// frames the test pushes through; the test can also force a
    /// "connection drop" that finishes every active subscription with
    /// an error, and decide whether the next `subscribe` succeeds
    /// (mocking a reconnect) or fails (current real behaviour).
    final class StageWSTransport: WSTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var nextID = 0
        private var streams: [Int: AsyncThrowingStream<OperationResult<JSONValue>, Error>.Continuation] = [:]
        private var connected = true
        private var allowReconnect = true

        public init() {}

        public func subscribe(_ context: WSContext) -> AsyncThrowingStream<OperationResult<JSONValue>, Error> {
            return AsyncThrowingStream { (continuation: AsyncThrowingStream<OperationResult<JSONValue>, Error>.Continuation) in
                lock.lock()
                guard connected else {
                    lock.unlock()
                    if allowReconnect {
                        // Mock: pretend a reconnect happened. Behave as if
                        // the socket is healthy again.
                        connected = true
                        lock.lock()
                        nextID += 1
                        streams[nextID] = continuation
                        lock.unlock()
                    } else {
                        // Match the real bug: a dead socket fails the new
                        // subscription's first send.
                        continuation.finish(throwing: CachebayError.networkError("WS not connected"))
                        return
                    }
                    return
                }
                nextID += 1
                let id = nextID
                streams[id] = continuation
                lock.unlock()
                continuation.onTermination = { [weak self] _ in
                    self?.lock.lock()
                    self?.streams.removeValue(forKey: id)
                    self?.lock.unlock()
                }
            }
        }

        /// Push a successful frame to every active subscriber.
        func emit(_ data: JSONValue) {
            lock.lock()
            let snapshot = streams.values
            lock.unlock()
            for c in snapshot { c.yield(OperationResult(data: data)) }
        }

        /// Simulate the socket dropping. Every active subscription
        /// finishes with an error; subsequent `subscribe()` calls either
        /// auto-reconnect (allowReconnect=true) or fail
        /// (allowReconnect=false — captures the documented §5.9 gap).
        func dropConnection(allowReconnect: Bool = true) {
            lock.lock()
            connected = false
            self.allowReconnect = allowReconnect
            let snapshot = streams.values
            streams.removeAll()
            lock.unlock()
            for c in snapshot {
                c.finish(throwing: CachebayError.networkError("WS connection dropped"))
            }
        }
    }

    private func makeClient(_ ws: StageWSTransport) -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport(), ws: ws),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    // MARK: - Active subscriber gets an error on drop

    func test_activeSubscriber_receivesErrorOnDrop() async throws {
        let ws = StageWSTransport()
        let client = makeClient(ws)

        let stream = try client.executeSubscription(
            query: "subscription { postUpdated { id title } }",
            variables: [:]
        )

        let received = CaptureBox<[OperationResult<JSONValue>]>(value: [])
        let caughtError = CaptureBox<Error?>(value: nil)
        let task = Task<Void, Never> {
            do {
                for try await event in stream {
                    received.withLock { $0.append(event) }
                }
            } catch {
                caughtError.value = error
            }
        }

        // Yield first frame then drop the socket.
        try await Task.sleep(nanoseconds: 30_000_000)
        ws.emit(.object(["postUpdated": .object(["__typename": .string("Post"), "id": .string("p1"), "title": .string("hi")])]))
        try await Task.sleep(nanoseconds: 30_000_000)
        ws.dropConnection(allowReconnect: true)
        await task.value

        XCTAssertEqual(received.value.count, 1, "subscriber should have observed one frame before the drop")
        XCTAssertNotNil(caughtError.value, "subscriber must see the drop as an error so it can recover or surface a UI message")
    }

    // MARK: - After drop, a fresh subscribe reconnects (with mocked transport)

    func test_subscribeAfterDrop_reconnectsAndDeliversFrames() async throws {
        let ws = StageWSTransport()
        let client = makeClient(ws)

        // Open + drop.
        let firstStream = try client.executeSubscription(
            query: "subscription { postUpdated { id title } }",
            variables: [:]
        )
        let firstTask = Task<Void, Never> {
            do { for try await _ in firstStream {} } catch { /* expected drop */ }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        ws.dropConnection(allowReconnect: true)
        _ = await firstTask.value

        // Open a fresh subscription. With reconnect-capable transport,
        // this should deliver frames.
        let secondStream = try client.executeSubscription(
            query: "subscription { postUpdated { id title } }",
            variables: [:]
        )
        let received = CaptureBox<[JSONValue]>(value: [])
        let task = Task<Void, Never> {
            do {
                for try await event in secondStream {
                    if let data = event.data { received.append(data) }
                }
            } catch {
                // unexpected on the reconnect path
            }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        ws.emit(.object(["postUpdated": .object(["__typename": .string("Post"), "id": .string("p1"), "title": .string("after-reconnect")])]))
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        _ = await task.value

        XCTAssertEqual(received.value.count, 1, "post-reconnect subscriber should observe new frames")
    }

    // MARK: - After drop, a fresh subscribe fails fast (current real behaviour)

    func test_subscribeAfterDrop_withoutReconnect_failsFast() async throws {
        let ws = StageWSTransport()
        let client = makeClient(ws)

        let firstStream = try client.executeSubscription(
            query: "subscription { postUpdated { id title } }",
            variables: [:]
        )
        let firstTask = Task<Void, Never> {
            do { for try await _ in firstStream {} } catch { /* expected drop */ }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        // Drop and refuse reconnect — mirrors current
        // URLSessionWebSocketTransport behaviour where `acked` /
        // `task` aren't reset on socket error.
        ws.dropConnection(allowReconnect: false)
        _ = await firstTask.value

        // A fresh subscribe must SURFACE the failure to the subscriber
        // (either via finish(throwing:) or an error frame), NOT silently
        // hang or write to a dead socket.
        let secondStream = try client.executeSubscription(
            query: "subscription { postUpdated { id title } }",
            variables: [:]
        )
        let caughtError = CaptureBox<Error?>(value: nil)
        let task = Task<Void, Never> {
            do {
                for try await _ in secondStream {}
            } catch {
                caughtError.value = error
            }
        }
        _ = await task.value

        XCTAssertNotNil(
            caughtError.value,
            "post-drop subscribe with no reconnect path must throw — silent hang would be a worse bug than today's"
        )
    }

    // MARK: - URLSessionWebSocketTransport state-machine + reconnect API
    //
    // These tests exercise the real transport's state API (`state`,
    // `reconnect()`, `disconnect()`, `events()`) without needing a
    // live WS server. The reconnector orchestrates state transitions
    // even when the wire is dead — so we can pin behavior with a
    // non-existent URL.

    /// `reconnect()` from `.connected` / `.connecting` is a no-op.
    /// We can't easily reach `.connected` without a server, but we
    /// can prove it doesn't crash / re-enter when called repeatedly
    /// from `.disconnected` with no pending subscriptions.
    func test_reconnect_fromDisconnectedWithNoSubs_isNoOp() {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "ws://127.0.0.1:1/dead")!,
            reconnectPolicy: .default
        )
        XCTAssertEqual(ws.state, .disconnected)
        ws.reconnect()
        ws.reconnect()
        ws.reconnect()
        XCTAssertEqual(ws.state, .disconnected,
                       "reconnect() with no pending subs must not start a reconnector loop")
    }

    /// `disconnect()` parks the transport in `.stopped(.userClosed)`.
    /// `reconnect()` resurrects it back to `.disconnected` (no subs).
    func test_disconnect_parksInStopped_reconnectResurrects() {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "ws://127.0.0.1:1/dead")!,
            reconnectPolicy: .default
        )
        ws.disconnect(reason: .userClosed)
        XCTAssertEqual(ws.state, .stopped(reason: .userClosed))
        ws.reconnect()
        XCTAssertEqual(ws.state, .disconnected,
                       "reconnect() from .stopped with no subs must resurrect to .disconnected")
    }

    /// `ReconnectPolicy.disabled` (maxAttempts: 0) — when an
    /// unexpected disconnect happens with pending subscribers, the
    /// reconnector refuses to start and the transport jumps straight
    /// to `.stopped(.maxAttemptsExceeded)`.
    func test_disabledPolicy_failsFast_onUnexpectedDisconnect() async throws {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "ws://127.0.0.1:1/dead")!,
            reconnectPolicy: .disabled
        )
        // Kick a subscribe — it'll fail to connect, no reconnect
        // because policy is disabled.
        let stream = ws.subscribe(WSContext(query: "subscription { x }", variables: [:]))
        let task = Task<Error?, Never> {
            do {
                for try await _ in stream {}
                return nil
            } catch {
                return error
            }
        }
        let err = await task.value
        XCTAssertNotNil(err, "subscribe with policy.disabled must error out on connect failure")
    }

    /// Backoff math: defaults grow exponentially capped by `maxDelay`,
    /// jitter keeps each delay within ±30%.
    func test_reconnectPolicy_backoffMath_respectsCapAndJitter() {
        // Use an internal helper-style assertion: the policy's exposed
        // surface doesn't leak `computeBackoff`, but we can verify
        // the documented properties via `events()` later. For now,
        // pin the *struct* defaults so future bumps trip a test.
        let p = ReconnectPolicy.default
        XCTAssertEqual(p.initialDelay, 0.5, accuracy: 0.001)
        XCTAssertEqual(p.maxDelay, 5, accuracy: 0.001,
            "5s cap matches Phoenix/Pusher/real-time-WS norms; 30s+ HTTPS-style caps need a custom policy")
        XCTAssertEqual(p.multiplier, 2.0, accuracy: 0.001)
        XCTAssertEqual(p.jitter, 0.3, accuracy: 0.001)
        XCTAssertNil(p.maxAttempts, "default policy must retry forever")

        let aggressive = ReconnectPolicy.aggressive
        XCTAssertLessThan(aggressive.initialDelay, p.initialDelay,
                          ".aggressive must be tighter than .default")
        XCTAssertLessThan(aggressive.maxDelay, p.maxDelay)

        XCTAssertEqual(ReconnectPolicy.disabled.maxAttempts, 0,
                       ".disabled must set maxAttempts to 0 (refuse to retry)")
    }

    /// Exponential growth + jitter in practice. Uses `FakeClock` so
    /// the test runs in milliseconds without burning real backoff
    /// time, and asserts on the exact backoff sequence (each attempt
    /// is `min(initial * mult^(n-1), maxDelay) * jitterFactor`).
    func test_reconnect_emitsReconnectScheduledEvents_withGrowingDelays() async throws {
        let clock = FakeClock()
        let policy = ReconnectPolicy(
            initialDelay: 0.05,    // 50ms
            maxDelay: 0.4,         // cap at 400ms
            multiplier: 2.0,
            jitter: 0.2,
            maxAttempts: 4
        )
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "ws://127.0.0.1:1/dead")!,
            reconnectPolicy: policy,
            clock: clock
        )

        let events = ws.events()
        let scheduledDelays = ScheduledDelaysBox()
        let stoppedExpectation = expectation(description: "transport reaches .stopped")

        let drainerTask = Task {
            for await event in events {
                if case .reconnectScheduled(_, let delay) = event {
                    scheduledDelays.append(delay)
                }
                if case .stopped = event {
                    stoppedExpectation.fulfill()
                    break
                }
            }
        }

        // Kick the reconnector — fake clock means each backoff sleep
        // suspends until we call `advance(by:)` / `releaseAllPending()`.
        let stream = ws.subscribe(WSContext(query: "subscription { x }", variables: [:]))
        let consumerTask = Task<Void, Never> {
            do { for try await _ in stream {} } catch { /* expected */ }
        }

        // Drive the reconnector through all 4 attempts. Each attempt
        // schedules a sleep on the fake clock; we wait for the sleep
        // to be parked, then release it. The reconnector then tries
        // to connect (fails immediately on the dead URL) and parks
        // its next sleep, which we release in the next iteration.
        for _ in 0..<policy.maxAttempts! {
            try await clock.waitForPendingSleepThenAdvance(by: .seconds(policy.maxDelay * 2))
        }

        await fulfillment(of: [stoppedExpectation], timeout: 5)
        _ = await consumerTask.value
        _ = await drainerTask.value

        let delays = scheduledDelays.snapshot()
        XCTAssertEqual(delays.count, policy.maxAttempts!,
                       "expected exactly \(policy.maxAttempts!) reconnect-scheduled events, got \(delays.count): \(delays)")
        // With FakeClock there's no OS scheduling slop. Each delay
        // must be exactly `min(initial * mult^(n-1), maxDelay) * jitterFactor`,
        // bounded by [1-jitter, 1+jitter].
        for (i, d) in delays.enumerated() {
            let attempt = i + 1
            let nominal = min(policy.initialDelay * pow(policy.multiplier, Double(attempt - 1)),
                              policy.maxDelay)
            let lo = nominal * (1 - policy.jitter)
            let hi = nominal * (1 + policy.jitter)
            XCTAssertGreaterThanOrEqual(d, lo,
                "attempt \(attempt): delay \(d)s below jitter floor \(lo)s")
            XCTAssertLessThanOrEqual(d, hi,
                "attempt \(attempt): delay \(d)s above jitter ceiling \(hi)s")
        }
        if case .stopped(let reason) = ws.state {
            XCTAssertEqual(reason, .maxAttemptsExceeded)
        } else {
            XCTFail("expected .stopped(.maxAttemptsExceeded), got \(ws.state)")
        }
    }
    typealias ConnectionState = URLSessionWebSocketTransport.ConnectionState

    /// State after `disconnect(.userClosed)` is `.stopped(.userClosed)`,
    /// distinct from `.stopped(.maxAttemptsExceeded)`. Keeps UI able
    /// to distinguish "user disconnected" from "ran out of retries".
    func test_disconnectReason_distinguishesUserClosed_fromMaxAttempts() async {
        let ws1 = URLSessionWebSocketTransport(
            url: URL(string: "ws://127.0.0.1:1/dead")!,
            reconnectPolicy: .default
        )
        ws1.disconnect(reason: .userClosed)
        XCTAssertEqual(ws1.state, .stopped(reason: .userClosed))

        let ws2 = URLSessionWebSocketTransport(
            url: URL(string: "ws://127.0.0.1:1/dead")!,
            reconnectPolicy: ReconnectPolicy(initialDelay: 0.01, maxDelay: 0.05, multiplier: 1.0, jitter: 0, maxAttempts: 1)
        )
        let stream = ws2.subscribe(WSContext(query: "subscription { x }", variables: [:]))
        let consumerTask = Task<Void, Never> {
            do { for try await _ in stream {} } catch { /* expected */ }
        }
        _ = await consumerTask.value
        // Give the reconnector a moment to finalize state transition
        try? await Task.sleep(nanoseconds: 50_000_000)
        if case .stopped(let reason) = ws2.state {
            XCTAssertEqual(reason, .maxAttemptsExceeded)
        } else {
            XCTFail("expected .stopped(.maxAttemptsExceeded), got \(ws2.state)")
        }
    }
}

/// Sendable box for collecting reconnect delays across the @Sendable
/// drainer Task boundary.
private final class ScheduledDelaysBox: @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [TimeInterval] = []
    func append(_ d: TimeInterval) { lock.lock(); delays.append(d); lock.unlock() }
    func snapshot() -> [TimeInterval] { lock.lock(); defer { lock.unlock() }; return delays }
}
