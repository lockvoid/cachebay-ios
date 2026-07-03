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
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport(), ws: ws),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
    }

    /// Bounded replacement for a bare `await task.value`. The pumps these
    /// tests spawn finish only when a stream errors or completes; if that
    /// callback never arrives (starved cooperative pool, a socket that
    /// neither connects nor errors), an unbounded await hangs the ENTIRE
    /// suite run at whichever test happens to be executing. Poll with a
    /// deadline instead: a stall becomes a clean failure at this line.
    @discardableResult
    private func awaitBounded<T: Sendable>(
        _ task: Task<T, Never>,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> T? {
        let result = CaptureBox<T?>(value: nil)
        Task<Void, Never> {
            let v = await task.value
            result.value = v
        }
        let deadline = Date().addingTimeInterval(timeout)
        while result.value == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let value = result.value else {
            XCTFail(
                "spawned task did not finish within \(timeout)s — an unbounded `await task.value` here would have hung the whole suite run",
                file: file, line: line)
            return nil
        }
        return value
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
        await awaitBounded(task)

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
            do { for try await _ in firstStream {} } catch { /* expected drop */  }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        ws.dropConnection(allowReconnect: true)
        await awaitBounded(firstTask)

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
        await awaitBounded(task)

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
            do { for try await _ in firstStream {} } catch { /* expected drop */  }
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        // Drop and refuse reconnect — mirrors current
        // URLSessionWebSocketTransport behaviour where `acked` /
        // `task` aren't reset on socket error.
        ws.dropConnection(allowReconnect: false)
        await awaitBounded(firstTask)

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
        await awaitBounded(task)

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
        XCTAssertEqual(
            ws.state, .disconnected,
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
        XCTAssertEqual(
            ws.state, .disconnected,
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
        guard let err = await awaitBounded(task) else { return }
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
        XCTAssertEqual(
            p.maxDelay, 5, accuracy: 0.001,
            "5s cap matches Phoenix/Pusher/real-time-WS norms; 30s+ HTTPS-style caps need a custom policy")
        XCTAssertEqual(p.multiplier, 2.0, accuracy: 0.001)
        XCTAssertEqual(p.jitter, 0.3, accuracy: 0.001)
        XCTAssertNil(p.maxAttempts, "default policy must retry forever")

        let aggressive = ReconnectPolicy.aggressive
        XCTAssertLessThan(
            aggressive.initialDelay, p.initialDelay,
            ".aggressive must be tighter than .default")
        XCTAssertLessThan(aggressive.maxDelay, p.maxDelay)

        XCTAssertEqual(
            ReconnectPolicy.disabled.maxAttempts, 0,
            ".disabled must set maxAttempts to 0 (refuse to retry)")
    }

    /// Exponential growth + jitter in practice. Uses `FakeClock` so
    /// the test runs in milliseconds without burning real backoff
    /// time, and asserts on the exact backoff sequence (each attempt
    /// is `min(initial * mult^(n-1), maxDelay) * jitterFactor`).
    func test_reconnect_emitsReconnectScheduledEvents_withGrowingDelays() async throws {
        let clock = FakeClock()
        let policy = ReconnectPolicy(
            initialDelay: 0.05,  // 50ms
            maxDelay: 0.4,  // cap at 400ms
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
            do { for try await _ in stream {} } catch { /* expected */  }
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
        await awaitBounded(consumerTask)
        await awaitBounded(drainerTask)

        let delays = scheduledDelays.snapshot()
        XCTAssertEqual(
            delays.count, policy.maxAttempts!,
            "expected exactly \(policy.maxAttempts!) reconnect-scheduled events, got \(delays.count): \(delays)")
        // With FakeClock there's no OS scheduling slop. Each delay
        // must be exactly `min(initial * mult^(n-1), maxDelay) * jitterFactor`,
        // bounded by [1-jitter, 1+jitter].
        for (i, d) in delays.enumerated() {
            let attempt = i + 1
            let nominal = min(
                policy.initialDelay * pow(policy.multiplier, Double(attempt - 1)),
                policy.maxDelay)
            let lo = nominal * (1 - policy.jitter)
            let hi = nominal * (1 + policy.jitter)
            XCTAssertGreaterThanOrEqual(
                d, lo,
                "attempt \(attempt): delay \(d)s below jitter floor \(lo)s")
            XCTAssertLessThanOrEqual(
                d, hi,
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
            do { for try await _ in stream {} } catch { /* expected */  }
        }
        await awaitBounded(consumerTask)
        // Give the reconnector a moment to finalize state transition
        try? await Task.sleep(nanoseconds: 50_000_000)
        if case .stopped(let reason) = ws2.state {
            XCTAssertEqual(reason, .maxAttemptsExceeded)
        } else {
            XCTFail("expected .stopped(.maxAttemptsExceeded), got \(ws2.state)")
        }
    }

    // MARK: - Default WS connect timeout
    //
    // URLSession's default `timeoutIntervalForRequest` is 60s — tuned
    // for HTTPS request/response, wrong for WebSocket connect attempts
    // during a server-restart window. A 60s stuck attempt eats the
    // entire 5s-cap backoff schedule. Cachebay defaults the WS-specific
    // connect timeout to 10s, which is:
    //   - greater than `ReconnectPolicy.default.maxDelay` (5s) so each
    //     backoff cycle gets a full attempt
    //   - covers slow cold-start servers (k8s pod boot, fly machine
    //     resume — typically 3–7s)
    //   - fails fast enough on half-connected sockets that backoff
    //     actually progresses

    /// When no explicit `URLSession` is provided, the transport must
    /// default to a short WS-specific connect timeout (~10s), not
    /// URLSession's 60s default.
    func test_defaultSession_hasShortConnectTimeout() {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!
        )
        let timeout = ws.session.configuration.timeoutIntervalForRequest
        XCTAssertLessThanOrEqual(
            timeout, 15,
            "default WS connect timeout must be ~10s, not URLSession's 60s default")
        XCTAssertGreaterThan(
            timeout, ReconnectPolicy.default.maxDelay,
            "default WS connect timeout must exceed maxDelay (5s) so each backoff cycle gets a full attempt")
    }

    // MARK: - Pending vs subscribed (subscribe-during-handshake race)
    //
    // The race: a caller invokes `subscribe()` while the transport is
    // still in `.connecting` (the very first handshake, or a reconnect
    // attempt mid-flight). The new entry lands in the subscription
    // registry immediately so it survives a drop. But when
    // `connection_ack` arrives, the dispatch path snapshots the registry
    // and replays `subscribe` for *every* entry — including ones whose
    // own caller-side Task is parked in `waitForAck()` and *also* about
    // to send `subscribe` once it wakes up.
    //
    // Result without the fix: two `subscribe` frames for the same id.
    // graphql-transport-ws-conformant servers reject the duplicate
    // (close code 4409 "Subscriber for <id> already exists") — and even
    // tolerant servers would yield each event twice initially. Apollo
    // iOS solves this with a `.pending` / `.subscribed` two-phase
    // registry: replay only the `.subscribed` ones.

    /// `subscribe()` invoked during `.connecting` must result in
    /// **exactly one** wire-level `subscribe` frame, not two.
    func test_subscribeDuringConnecting_doesNotDoubleSubscribeOnAck() async throws {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!
        )

        let frames = OutboundFrameSink()
        ws._testOutboundSink = { msg in frames.append(msg) }

        // Pretend the handshake is in flight: state is .connecting,
        // ack hasn't landed yet. Mirrors what `ensureConnected()` would
        // have set up before sending `connection_init`.
        ws._testForceState(.connecting, acked: false)

        // Caller-side: subscribe while still connecting. The entry
        // registers; the awaiting Task parks in `waitForAck()`.
        let stream = ws.subscribe(WSContext(query: "subscription { x }", variables: [:]))
        let consumer = Task<Void, Never> {
            do { for try await _ in stream {} } catch { /* expected on cancel */  }
        }

        // Let the subscribe Task register + park.
        try await Task.sleep(nanoseconds: 20_000_000)

        // Server lands connection_ack.
        ws._testInjectInbound(#"{"type":"connection_ack"}"#)

        // Let downstream Tasks (caller's Task waking up + any replay
        // path) settle.
        try await Task.sleep(nanoseconds: 50_000_000)

        let subscribes = frames.snapshot().filter {
            if case .subscribe = $0 { return true } else { return false }
        }
        XCTAssertEqual(
            subscribes.count, 1,
            "subscribe registered during .connecting must produce exactly one wire-level `subscribe` — the caller's awaiting Task already sends it; the connection_ack replay must skip it")

        consumer.cancel()
    }

    /// Counterpart to the above: a subscription that *was* live before
    /// a drop (state `.subscribed`) must be replayed by the
    /// `connection_ack` handler on reconnect. The fix for the
    /// pending-double-subscribe race must not regress this path.
    func test_subscribedEntries_areReplayedOnReconnectAck() async throws {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!
        )

        let frames = OutboundFrameSink()
        ws._testOutboundSink = { msg in frames.append(msg) }

        // Pretend we've been connected before, dropped, and are
        // mid-reconnect. There is one previously-live subscription
        // already in the registry as `.subscribed`.
        ws._testForceState(.reconnecting(attempt: 1), acked: false)
        ws._testRegisterSubscribed(id: "1", query: "subscription { y }", variables: [:])

        // Server lands the new connection_ack on the reconnect socket.
        ws._testInjectInbound(#"{"type":"connection_ack"}"#)

        // Let the spawned replay Task run.
        try await Task.sleep(nanoseconds: 50_000_000)

        let replays = frames.snapshot().filter {
            if case .subscribe(let id, _, _) = $0 { return id == "1" }
            return false
        }
        XCTAssertEqual(
            replays.count, 1,
            ".subscribed entries must be replayed exactly once when connection_ack lands on a reconnect socket")
    }

    // MARK: - updateConnectionParams (auth-rotation hook)
    //
    // Apollo iOS exposes `updateConnectingPayload(_:reconnectIfConnected:)`
    // for callers who need to rotate auth tokens without manually
    // wrangling disconnect → reset connectionParams → reconnect. We
    // ship the same shape under the cachebay-native name
    // `updateConnectionParams`. Two semantics are mandatory:
    //
    //   1. The next `connection_init` frame must use the new params
    //      (whether triggered now or on a future reconnect).
    //   2. `reconnectIfConnected: true` from `.connected` must drop the
    //      socket and bring it back so the new params land immediately;
    //      `false` defers the change to the next natural reconnect.

    /// New `connection_init` frame after `reconnectIfConnected: true`
    /// from `.connected` must carry the updated params payload.
    func test_updateConnectionParams_withReconnectTrue_nextInitUsesNewParams() async throws {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!,
            connectionParams: ["authToken": .string("OLD")]
        )
        let frames = OutboundFrameSink()
        ws._testOutboundSink = { msg in frames.append(msg) }

        // Simulate a live, acked connection.
        ws._testForceState(.connected, acked: true)

        ws.updateConnectionParams(["authToken": .string("NEW")], reconnectIfConnected: true)

        // The reconnect path tears down the socket and starts a fresh
        // connect attempt; that fresh attempt sends `connection_init`.
        // Give the orchestrator a moment to run.
        try await Task.sleep(nanoseconds: 100_000_000)

        let inits = frames.snapshot().compactMap { msg -> [String: JSONValue]? in
            if case .connectionInit(let params) = msg { return params }
            return nil
        }
        XCTAssertFalse(inits.isEmpty, "reconnectIfConnected:true must trigger a fresh connection_init")
        XCTAssertEqual(
            inits.last?["authToken"], .string("NEW"),
            "the new connection_init must carry the updated params, not the stale ones")

        // The fresh connect attempt is parked in waitForAck() (no ack is
        // ever injected here). Tear it down, or the reconnector + ack
        // continuation leak into the rest of the suite run.
        ws.disconnect()
    }

    /// `reconnectIfConnected: false` must update the params without
    /// dropping a live connection. The new value takes effect on the
    /// next natural reconnect.
    func test_updateConnectionParams_withReconnectFalse_doesNotDropLiveConnection() async throws {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!,
            connectionParams: ["authToken": .string("OLD")]
        )
        ws._testForceState(.connected, acked: true)

        ws.updateConnectionParams(["authToken": .string("NEW")], reconnectIfConnected: false)

        // Give any in-flight orchestration a moment.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(
            ws.state, .connected,
            "reconnectIfConnected:false must not tear down a live socket")
        XCTAssertEqual(
            ws.connectionParams["authToken"], .string("NEW"),
            "the params must still be updated for the next natural reconnect")
    }

    // MARK: - Ping / pong (graphql-transport-ws keepalive)
    //
    // Long-idle WebSocket connections are killed by NAT timeouts and
    // proxy idle-disconnect policies (typically 60–120s). The
    // graphql-transport-ws spec defines `ping`/`pong` protocol messages
    // for client-side keepalives. Disabled by default (cost is one
    // small frame per interval; only worth it for apps that hold
    // subscriptions across long quiet periods on cellular/WiFi).

    /// When `pingInterval` is nil (default), no ping frames are ever
    /// emitted, no matter how much time passes.
    func test_pingDefault_isDisabled() async throws {
        let clock = FakeClock()
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!,
            clock: clock
        )
        let frames = OutboundFrameSink()
        ws._testOutboundSink = { msg in frames.append(msg) }

        ws._testForceState(.connected, acked: true)
        ws._testInjectInbound(#"{"type":"connection_ack"}"#)

        // Burn fake time well past any reasonable interval.
        for _ in 0..<5 {
            clock.advance(by: .seconds(60))
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let pings = frames.snapshot().filter {
            if case .ping = $0 { return true } else { return false }
        }
        XCTAssertTrue(pings.isEmpty, "no pings must be sent when pingInterval is nil")
    }

    /// With `pingInterval` set, a `ping` frame goes out every interval
    /// after `connection_ack` lands.
    func test_pingInterval_sendsPeriodicPingsAfterAck() async throws {
        let clock = FakeClock()
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!,
            pingInterval: .seconds(20),
            clock: clock
        )
        let frames = OutboundFrameSink()
        ws._testOutboundSink = { msg in frames.append(msg) }

        ws._testForceState(.connecting, acked: false)
        ws._testInjectInbound(#"{"type":"connection_ack"}"#)

        // Drive three intervals.
        for _ in 0..<3 {
            try await clock.waitForPendingSleepThenAdvance(by: .seconds(20))
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let pings = frames.snapshot().filter {
            if case .ping = $0 { return true } else { return false }
        }
        XCTAssertGreaterThanOrEqual(
            pings.count, 3,
            "expected at least 3 ping frames after 3 intervals; got \(pings.count)")

        // The ping timer is parked in the fake clock's sleep and captures
        // the transport strongly — disconnect so neither outlives the test.
        ws.disconnect()
    }

    /// When the server sends `{"type":"ping"}` (allowed by the spec),
    /// the client must respond with `{"type":"pong"}` so the server
    /// knows we're alive.
    func test_serverPing_isAnsweredWithPong() async throws {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!
        )
        let frames = OutboundFrameSink()
        ws._testOutboundSink = { msg in frames.append(msg) }

        ws._testForceState(.connected, acked: true)
        ws._testInjectInbound(#"{"type":"ping"}"#)

        try? await Task.sleep(nanoseconds: 20_000_000)

        let pongs = frames.snapshot().filter {
            if case .pong = $0 { return true } else { return false }
        }
        XCTAssertEqual(
            pongs.count, 1,
            "client must answer server ping with exactly one pong")
    }

    /// `pingInterval` ticking must stop after disconnect / teardown,
    /// otherwise we'd leak Tasks across reconnects.
    func test_pingTimer_stopsAfterDisconnect() async throws {
        let clock = FakeClock()
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!,
            pingInterval: .seconds(10),
            clock: clock
        )
        let frames = OutboundFrameSink()
        ws._testOutboundSink = { msg in frames.append(msg) }

        ws._testForceState(.connecting, acked: false)
        ws._testInjectInbound(#"{"type":"connection_ack"}"#)

        // Tick once, then disconnect.
        try await clock.waitForPendingSleepThenAdvance(by: .seconds(10))
        try? await Task.sleep(nanoseconds: 10_000_000)
        let beforeDisconnect = frames.snapshot().filter {
            if case .ping = $0 { return true } else { return false }
        }.count

        ws.disconnect()
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Tick a long way past additional intervals.
        clock.releaseAllPending()
        try? await Task.sleep(nanoseconds: 20_000_000)
        clock.advance(by: .seconds(60))
        try? await Task.sleep(nanoseconds: 20_000_000)

        let afterDisconnect = frames.snapshot().filter {
            if case .ping = $0 { return true } else { return false }
        }.count

        XCTAssertEqual(
            beforeDisconnect, afterDisconnect,
            "ping timer must stop on disconnect — got \(beforeDisconnect) before, \(afterDisconnect) after")
    }

    // MARK: - subscriptionsChanged(active:) event
    //
    // The transport emits `subscriptionsChanged(active:)` on every
    // count transition — register (+1), unregister/complete/error
    // (−1), and bulk drain on `disconnect()` / terminal stop (→ 0).
    // It DOES NOT emit on `markSubscriptionLive` (status flip; count
    // unchanged) nor on the auto-reconnect cycle (subscriptions are
    // preserved across the gap, not removed).
    //
    // Payload is captured under `lock` at the moment of the mutation
    // — the `emitLocked` path keeps mutation+emit atomic so concurrent
    // registers can't reorder the count sequence consumers see.
    private func collectSubscriptionCounts(_ events: [URLSessionWebSocketTransport.ConnectionEvent]) -> [Int] {
        events.compactMap { ev in
            if case .subscriptionsChanged(let n) = ev { return n }
            return nil
        }
    }

    /// `subscribe()` emits `subscriptionsChanged(active: 1)`. Stream
    /// teardown (consumer cancel) emits `subscriptionsChanged(active: 0)`.
    func test_subscriptionsChanged_subscribeAndCancel_emitsOneThenZero() async throws {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!
        )
        ws._testOutboundSink = { _ in }
        ws._testForceState(.connecting, acked: false)

        let eventStream = ws.events()
        let collected = ConnectionEventCollector()
        let drainer = Task<Void, Never> {
            for await ev in eventStream { collected.append(ev) }
        }

        let stream = ws.subscribe(WSContext(query: "subscription { x }", variables: [:]))
        let consumer = Task<Void, Never> {
            do { for try await _ in stream {} } catch { /* expected */  }
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        let afterRegister = collectSubscriptionCounts(collected.snapshot())
        XCTAssertEqual(
            afterRegister, [1],
            "subscribe() must emit subscriptionsChanged(1); got \(afterRegister)")

        consumer.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)

        let afterCancel = collectSubscriptionCounts(collected.snapshot())
        XCTAssertEqual(
            afterCancel, [1, 0],
            "consumer cancel must emit subscriptionsChanged(0); got \(afterCancel)")

        drainer.cancel()
    }

    /// Multiple subscriptions accumulate the count, and individual
    /// terminations decrement it. Counts MUST observe in monotonic
    /// arithmetic order — no skips, no out-of-order emits.
    func test_subscriptionsChanged_multipleSubs_countTracksAccurately() async throws {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!
        )
        ws._testOutboundSink = { _ in }
        ws._testForceState(.connecting, acked: false)

        let eventStream = ws.events()
        let collected = ConnectionEventCollector()
        let drainer = Task<Void, Never> {
            for await ev in eventStream { collected.append(ev) }
        }

        let s1 = ws.subscribe(WSContext(query: "subscription { a }", variables: [:]))
        let c1 = Task<Void, Never> { do { for try await _ in s1 {} } catch {} }
        try await Task.sleep(nanoseconds: 10_000_000)

        let s2 = ws.subscribe(WSContext(query: "subscription { b }", variables: [:]))
        let c2 = Task<Void, Never> { do { for try await _ in s2 {} } catch {} }
        try await Task.sleep(nanoseconds: 10_000_000)

        let s3 = ws.subscribe(WSContext(query: "subscription { c }", variables: [:]))
        let c3 = Task<Void, Never> { do { for try await _ in s3 {} } catch {} }
        try await Task.sleep(nanoseconds: 30_000_000)

        let countsAfterAll = collectSubscriptionCounts(collected.snapshot())
        XCTAssertEqual(
            countsAfterAll, [1, 2, 3],
            "three sequential subscribes must emit 1, 2, 3 in order; got \(countsAfterAll)")

        c2.cancel()
        try await Task.sleep(nanoseconds: 30_000_000)
        c1.cancel()
        try await Task.sleep(nanoseconds: 30_000_000)
        c3.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)

        let final = collectSubscriptionCounts(collected.snapshot())
        XCTAssertEqual(
            final, [1, 2, 3, 2, 1, 0],
            "decrements must be monotonic; got \(final)")

        drainer.cancel()
    }

    /// Server-initiated `complete` frame ends the subscription and
    /// emits `subscriptionsChanged(active: 0)`.
    func test_subscriptionsChanged_serverComplete_emitsDecrement() async throws {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!
        )
        ws._testOutboundSink = { _ in }
        ws._testForceState(.connecting, acked: false)

        let eventStream = ws.events()
        let collected = ConnectionEventCollector()
        let drainer = Task<Void, Never> {
            for await ev in eventStream { collected.append(ev) }
        }

        let stream = ws.subscribe(WSContext(query: "subscription { x }", variables: [:]))
        let consumer = Task<Void, Never> {
            do { for try await _ in stream {} } catch { /* expected */  }
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        // Drive the awaiting subscriber to a fully-subscribed state so
        // the registry has a stable id for us to target.
        ws._testInjectInbound(#"{"type":"connection_ack"}"#)
        try await Task.sleep(nanoseconds: 30_000_000)

        // Server says "we're done with this subscription".
        ws._testInjectInbound(#"{"id":"sub-1","type":"complete"}"#)
        try await Task.sleep(nanoseconds: 50_000_000)

        let counts = collectSubscriptionCounts(collected.snapshot())
        XCTAssertEqual(
            counts, [1, 0],
            "server `complete` must emit subscriptionsChanged(0); got \(counts)")

        consumer.cancel()
        drainer.cancel()
    }

    /// Server-initiated `error` frame ends the subscription with an
    /// error and emits `subscriptionsChanged(active: 0)`.
    func test_subscriptionsChanged_serverError_emitsDecrement() async throws {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!
        )
        ws._testOutboundSink = { _ in }
        ws._testForceState(.connecting, acked: false)

        let eventStream = ws.events()
        let collected = ConnectionEventCollector()
        let drainer = Task<Void, Never> {
            for await ev in eventStream { collected.append(ev) }
        }

        let stream = ws.subscribe(WSContext(query: "subscription { x }", variables: [:]))
        let consumer = Task<Void, Never> {
            do { for try await _ in stream {} } catch { /* expected */  }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        ws._testInjectInbound(#"{"type":"connection_ack"}"#)
        try await Task.sleep(nanoseconds: 30_000_000)

        ws._testInjectInbound(#"{"id":"sub-1","type":"error","payload":[{"message":"boom"}]}"#)
        try await Task.sleep(nanoseconds: 50_000_000)

        let counts = collectSubscriptionCounts(collected.snapshot())
        XCTAssertEqual(
            counts, [1, 0],
            "server `error` must emit subscriptionsChanged(0); got \(counts)")

        consumer.cancel()
        drainer.cancel()
    }

    /// `markSubscriptionLive` flips `.pending → .subscribed` without
    /// changing count — it MUST NOT emit `subscriptionsChanged`.
    /// Drives a full register → ack → send-subscribe → live cycle and
    /// asserts only the initial register emit fires.
    func test_subscriptionsChanged_markLive_doesNotEmit() async throws {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!
        )
        ws._testOutboundSink = { _ in }
        ws._testForceState(.connecting, acked: false)

        let eventStream = ws.events()
        let collected = ConnectionEventCollector()
        let drainer = Task<Void, Never> {
            for await ev in eventStream { collected.append(ev) }
        }

        let stream = ws.subscribe(WSContext(query: "subscription { x }", variables: [:]))
        let consumer = Task<Void, Never> {
            do { for try await _ in stream {} } catch { /* cancel */  }
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        ws._testInjectInbound(#"{"type":"connection_ack"}"#)
        // Wait long enough for the awaiting Task to wake, send its
        // subscribe frame, and call markSubscriptionLive.
        try await Task.sleep(nanoseconds: 80_000_000)

        let counts = collectSubscriptionCounts(collected.snapshot())
        XCTAssertEqual(
            counts, [1],
            "markSubscriptionLive must NOT emit a count event (count is unchanged); got \(counts)")

        consumer.cancel()
        drainer.cancel()
    }

    /// `disconnect()` drains every active subscription — the bulk
    /// teardown emits exactly one `subscriptionsChanged(active: 0)`,
    /// not one per subscription.
    func test_subscriptionsChanged_disconnectDrainsAndEmitsZero() async throws {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!
        )
        ws._testOutboundSink = { _ in }
        ws._testForceState(.connecting, acked: false)

        let eventStream = ws.events()
        let collected = ConnectionEventCollector()
        let drainer = Task<Void, Never> {
            for await ev in eventStream { collected.append(ev) }
        }

        let s1 = ws.subscribe(WSContext(query: "subscription { a }", variables: [:]))
        let c1 = Task<Void, Never> { do { for try await _ in s1 {} } catch {} }
        let s2 = ws.subscribe(WSContext(query: "subscription { b }", variables: [:]))
        let c2 = Task<Void, Never> { do { for try await _ in s2 {} } catch {} }
        try await Task.sleep(nanoseconds: 30_000_000)

        ws.disconnect()
        try await Task.sleep(nanoseconds: 80_000_000)

        let counts = collectSubscriptionCounts(collected.snapshot())
        XCTAssertEqual(
            counts, [1, 2, 0],
            "disconnect() must emit a single subscriptionsChanged(0) for the bulk drain; got \(counts)")

        c1.cancel(); c2.cancel(); drainer.cancel()
    }

    /// `disconnect()` on an empty registry MUST NOT emit a spurious
    /// `subscriptionsChanged(0)` — guard against 0→0 noise in
    /// telemetry / UI.
    func test_subscriptionsChanged_emptyDisconnect_doesNotEmitZero() async throws {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!
        )
        let eventStream = ws.events()
        let collected = ConnectionEventCollector()
        let drainer = Task<Void, Never> {
            for await ev in eventStream { collected.append(ev) }
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        ws.disconnect()
        try await Task.sleep(nanoseconds: 30_000_000)

        let counts = collectSubscriptionCounts(collected.snapshot())
        XCTAssertEqual(
            counts, [],
            "disconnect() with no subscriptions must NOT emit subscriptionsChanged; got \(counts)")

        drainer.cancel()
    }

    /// Server-initiated `connection_error` parks the transport in
    /// `.stopped(.unauthorized)` and drains pending subscriptions —
    /// the drain must emit `subscriptionsChanged(active: 0)`.
    func test_subscriptionsChanged_terminalStopDrainsAndEmitsZero() async throws {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!
        )
        ws._testOutboundSink = { _ in }
        ws._testForceState(.connecting, acked: false)

        let eventStream = ws.events()
        let collected = ConnectionEventCollector()
        let drainer = Task<Void, Never> {
            for await ev in eventStream { collected.append(ev) }
        }

        let stream = ws.subscribe(WSContext(query: "subscription { x }", variables: [:]))
        let consumer = Task<Void, Never> {
            do { for try await _ in stream {} } catch { /* expected */  }
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        // Server rejects the handshake — terminal stop with drain.
        ws._testInjectInbound(#"{"type":"connection_error"}"#)
        try await Task.sleep(nanoseconds: 80_000_000)

        let counts = collectSubscriptionCounts(collected.snapshot())
        XCTAssertEqual(
            counts, [1, 0],
            "terminal stop must drain subscriptions and emit subscriptionsChanged(0); got \(counts)")

        consumer.cancel()
        drainer.cancel()
    }

    /// Auto-reconnect preserves subscriptions across the gap — the
    /// transport must NOT emit any `subscriptionsChanged` events
    /// during a `.disconnected` → `.reconnecting` → ack cycle.
    func test_subscriptionsChanged_reconnectCycle_doesNotEmit() async throws {
        let clock = FakeClock()
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!,
            reconnectPolicy: ReconnectPolicy(
                initialDelay: 0.05, maxDelay: 0.1,
                multiplier: 2.0, jitter: 0, maxAttempts: 1
            ),
            clock: clock
        )
        ws._testOutboundSink = { _ in }

        // Subscribe to the events stream BEFORE seeding the registry —
        // otherwise the `_testRegisterSubscribed` emit lands while the
        // continuation is still nil and is dropped on the floor.
        let eventStream = ws.events()
        let collected = ConnectionEventCollector()
        let drainer = Task<Void, Never> {
            for await ev in eventStream { collected.append(ev) }
        }

        ws._testForceState(.connected, acked: true)
        ws._testRegisterSubscribed(id: "sub-prev", query: "subscription { y }", variables: [:])

        try await Task.sleep(nanoseconds: 30_000_000)
        let beforeReconnect = collectSubscriptionCounts(collected.snapshot())
        XCTAssertEqual(
            beforeReconnect, [1],
            "_testRegisterSubscribed sets the baseline at 1; got \(beforeReconnect)")

        // Provoke an unexpected disconnect via the receive-loop path
        // simulation: a non-finishing teardown that preserves subs.
        // We use the real teardown plumbing by injecting the
        // `subscribe` Task's send error: drive `disconnect-with-keep`
        // through the same internal API the receive loop calls.
        // Easiest reproducible path: drop and trigger the reconnector.
        // Without a real socket we approximate by forcing state to
        // `.disconnected` and starting the reconnector via reconnect().
        ws._testForceState(.disconnected, acked: false)
        ws.reconnect()
        try await Task.sleep(nanoseconds: 80_000_000)

        // Now drive the reconnector forward enough to land an ack and
        // close out the loop.
        ws._testInjectInbound(#"{"type":"connection_ack"}"#)
        try await Task.sleep(nanoseconds: 80_000_000)

        let counts = collectSubscriptionCounts(collected.snapshot())
        XCTAssertEqual(
            counts, [1],
            "reconnect cycle must NOT emit additional subscriptionsChanged events (subs preserved); got \(counts)")

        drainer.cancel()
    }

    /// Ordering invariant: `subscriptionsChanged(1)` is observed on
    /// the events stream before any of the subscribe()-spawned Task's
    /// downstream events (`.connecting`, `.messageSent(connection_init)`,
    /// etc). Captures the under-lock emit guarantee.
    func test_subscriptionsChanged_ordering_emittedBeforeConnectingEvent() async throws {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!
        )
        ws._testOutboundSink = { _ in }

        let eventStream = ws.events()
        let collected = ConnectionEventCollector()
        let drainer = Task<Void, Never> {
            for await ev in eventStream { collected.append(ev) }
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        let stream = ws.subscribe(WSContext(query: "subscription { x }", variables: [:]))
        let consumer = Task<Void, Never> {
            do { for try await _ in stream {} } catch { /* cancel */  }
        }
        try await Task.sleep(nanoseconds: 60_000_000)

        let events = collected.snapshot()
        let countIdx = events.firstIndex {
            if case .subscriptionsChanged = $0 { return true }
            return false
        }
        let connectingIdx = events.firstIndex {
            if case .connecting = $0 { return true }
            return false
        }
        XCTAssertNotNil(
            countIdx,
            "subscriptionsChanged(1) was never emitted; events=\(events)")
        XCTAssertNotNil(
            connectingIdx,
            "connecting was never emitted; events=\(events)")
        XCTAssertLessThan(
            countIdx ?? .max, connectingIdx ?? .min,
            "subscriptionsChanged(1) must be emitted under-lock from registerSubscription, BEFORE the spawned Task emits .connecting; events=\(events)")

        consumer.cancel()
        drainer.cancel()
    }

    // MARK: - Duplicate-disconnect collapse
    //
    // Each physical socket failure can trip BOTH the send path
    // (connection_init send fails) AND the receive-loop catch (the
    // `task.receive()` await throws) for the same dead socket.
    // Without dedupe, both emit `.disconnected(...)` and consumers see
    // two events for one underlying drop. Smoke logs from a real
    // failed-handshake retry cycle showed:
    //
    //     [WS] disconnected: receiveLoopError: Could not connect to the server.
    //     [WS] disconnected: sendError: Could not connect to the server.
    //
    // back-to-back per attempt. The `teardown` early-exit gate catches
    // the second one only when `_state` is in
    // `{disconnected, reconnecting, stopped}` — but during a failed
    // attempt the first teardown leaves state at `.connecting` (because
    // `then: nil` when subs are pending), letting the duplicate slip
    // through.

    /// At most one `.disconnected` event per failed connection
    /// attempt, even when both the send path and the receive-loop
    /// path race to report the same physical drop.
    func test_failedAttempt_emitsAtMostOneDisconnectedEventPerSocket() async throws {
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "ws://127.0.0.1:1/dead")!,
            reconnectPolicy: ReconnectPolicy(initialDelay: 0.01, maxDelay: 0.05, multiplier: 2.0, jitter: 0, maxAttempts: 1)
        )

        // Drain events while the reconnector burns through its single
        // attempt and lands in .stopped(.maxAttemptsExceeded).
        let collected = ConnectionEventCollector()
        let drainer = Task<Void, Never> {
            for await ev in ws.events() {
                collected.append(ev)
                if case .stopped = ev { return }
            }
        }

        // Subscribe to provoke a connect attempt against the dead URL.
        let stream = ws.subscribe(WSContext(query: "subscription { x }", variables: [:]))
        let consumer = Task<Void, Never> {
            do { for try await _ in stream {} } catch { /* expected */  }
        }
        await awaitBounded(consumer)
        await awaitBounded(drainer)

        // Group disconnect events between connecting markers so the
        // assertion targets *per-attempt* duplicates, not the total
        // across the whole reconnect schedule.
        let events = collected.snapshot()
        var disconnectsThisAttempt = 0
        var maxDisconnectsInAnyAttempt = 0
        for ev in events {
            switch ev {
            case .connecting:
                maxDisconnectsInAnyAttempt = max(maxDisconnectsInAnyAttempt, disconnectsThisAttempt)
                disconnectsThisAttempt = 0
            case .disconnected:
                disconnectsThisAttempt += 1
            default:
                break
            }
        }
        maxDisconnectsInAnyAttempt = max(maxDisconnectsInAnyAttempt, disconnectsThisAttempt)
        XCTAssertLessThanOrEqual(
            maxDisconnectsInAnyAttempt, 1,
            "each physical socket failure must emit AT MOST ONE `.disconnected` event — got \(maxDisconnectsInAnyAttempt) in a single attempt; events=\(events)")
    }

    /// A caller-supplied `URLSession` must be used as-is — the transport
    /// must not mutate its configuration or wrap it.
    func test_customSession_isPreservedUntouched() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 42
        let custom = URLSession(configuration: cfg)
        let ws = URLSessionWebSocketTransport(
            url: URL(string: "wss://example.test/graphql")!,
            session: custom
        )
        XCTAssertTrue(
            ws.session === custom,
            "explicit session must be used as-is, not replaced")
        XCTAssertEqual(
            ws.session.configuration.timeoutIntervalForRequest, 42,
            "explicit session's timeoutIntervalForRequest must not be mutated")
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

/// Sendable box for collecting outbound WS frames across the test seam
/// closure boundary.
private final class OutboundFrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [WSClientMessage] = []
    func append(_ m: WSClientMessage) { lock.lock(); frames.append(m); lock.unlock() }
    func snapshot() -> [WSClientMessage] { lock.lock(); defer { lock.unlock() }; return frames }
}

/// Sendable box for collecting `ConnectionEvent`s from the events()
/// stream across the drainer Task boundary.
private final class ConnectionEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [URLSessionWebSocketTransport.ConnectionEvent] = []
    func append(_ e: URLSessionWebSocketTransport.ConnectionEvent) { lock.lock(); events.append(e); lock.unlock() }
    func snapshot() -> [URLSessionWebSocketTransport.ConnectionEvent] { lock.lock(); defer { lock.unlock() }; return events }
}
