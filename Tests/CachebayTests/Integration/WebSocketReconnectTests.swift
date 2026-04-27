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
}
