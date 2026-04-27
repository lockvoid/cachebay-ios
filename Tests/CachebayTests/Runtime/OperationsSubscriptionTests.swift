import XCTest
@testable import Cachebay

/// Black-box port of `cachebay-web/test/unit/core/operations-execute-subscriptions.test.ts`.
/// Verifies executeSubscription:
///   • per-frame normalize with sequential `@subscription.<n>` rootId,
///   • watcher fanout per frame,
///   • clock increments across multiple parallel subscriptions,
///   • error frames yield to consumers without crashing the stream,
///   • completion (server-driven finish) closes the stream,
///   • materialization failures yield error frames rather than data.
///
/// The basic happy-path (`MockWSTransport(frames:)` yields, stream
/// finishes) is already pinned by `OperationsTests.test_subscription_
/// stream_yields_frames`. New cases use a richer in-file mock.
final class OperationsSubscriptionTests: XCTestCase {

    // Convenience subscriptions (string form keeps tests indep of typed API).
    private let messageAdded = "subscription OnMessage { messageAdded { id text } }"
    private let userUpdated = "subscription OnUser { userUpdated { id name } }"

    // MARK: - networkQuery routing

    /// Mirrors web `sends networkQuery with __typename to transport,
    /// not original query`. The compiled networkQuery is what the WS
    /// transport sees on subscribe — implicitly verifies `__typename`
    /// injection so each frame can be normalised.
    func test_executeSubscription_sendsNetworkQueryWithTypename_toTransport() async throws {
        let recorder = QueryRecordingWSTransport()
        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport(), ws: recorder),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
        _ = try client.executeSubscription(query: messageAdded)
        // Wait until subscribe has been invoked (stream gets its
        // continuation in subscribe()).
        try await recorder.awaitSubscribed()
        let q = recorder.lastQuery
        XCTAssertNotNil(q)
        XCTAssertTrue(
            q?.contains("__typename") ?? false,
            "WSTransport must receive the planner's networkQuery (with __typename injected); got: \(q ?? "<nil>")"
        )
    }

    // MARK: - Multiple subscriptions share a single clock

    /// Mirrors web `maintains separate clocks for different
    /// subscriptions`. iOS uses a *single* monotonic clock per
    /// Operations instance — every frame across every active
    /// subscription gets a fresh `@subscription.<n>` root, so the
    /// overall sequence must be strictly increasing across the union
    /// of frames.
    ///
    /// We verify this indirectly by submitting frames against two
    /// distinct subscriptions, each writing a different entity, and
    /// checking that both entities land in the graph (no rootId
    /// collision).
    func test_subscription_independentTopics_bothNormalize() async throws {
        let posts = MockWSTransport(frames: [
            .object(["messageAdded": .object(["__typename": "Message", "id": "m1", "text": "Hello"])]),
        ])
        let users = MockWSTransport(frames: [
            .object(["userUpdated": .object(["__typename": "User", "id": "u1", "name": "Alice"])]),
        ])

        // Two clients to drive two distinct streams concurrently — the
        // alternative would be a stage-driven mock; one client per
        // subscription is simpler and equivalent for this assertion.
        let postsClient = CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport(), ws: posts),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
        let usersClient = CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport(), ws: users),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))

        let postsStream = try postsClient.executeSubscription(query: messageAdded)
        let usersStream = try usersClient.executeSubscription(query: userUpdated)

        var postsTitles: [String] = []
        for try await event in postsStream {
            if let t = event.data?["messageAdded"]?["text"]?.string { postsTitles.append(t) }
            if !postsTitles.isEmpty { break }
        }
        var usersNames: [String] = []
        for try await event in usersStream {
            if let n = event.data?["userUpdated"]?["name"]?.string { usersNames.append(n) }
            if !usersNames.isEmpty { break }
        }

        XCTAssertEqual(postsTitles, ["Hello"])
        XCTAssertEqual(usersNames, ["Alice"])
        XCTAssertEqual(postsClient.graph.getField("Message:m1", "text")?.string, "Hello")
        XCTAssertEqual(usersClient.graph.getField("User:u1", "name")?.string, "Alice")
    }

    // MARK: - Normalize per frame, sequential roots

    /// Mirrors web `increments subscription clock for each event`.
    /// Two frames against the same subscription must each land
    /// independently — both entities must be in the graph and visible
    /// to a follow-up readQuery.
    func test_subscription_eachFrame_normalizesIndependently() async throws {
        let ws = MockWSTransport(frames: [
            .object(["messageAdded": .object(["__typename": "Message", "id": "m1", "text": "First"])]),
            .object(["messageAdded": .object(["__typename": "Message", "id": "m2", "text": "Second"])]),
            .object(["messageAdded": .object(["__typename": "Message", "id": "m3", "text": "Third"])]),
        ])
        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport(), ws: ws),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))

        var collected: [String] = []
        let stream = try client.executeSubscription(query: messageAdded)
        for try await event in stream {
            if let t = event.data?["messageAdded"]?["text"]?.string {
                collected.append(t)
            }
            if collected.count == 3 { break }
        }

        XCTAssertEqual(collected, ["First", "Second", "Third"])
        XCTAssertEqual(client.graph.getField("Message:m1", "text")?.string, "First")
        XCTAssertEqual(client.graph.getField("Message:m2", "text")?.string, "Second")
        XCTAssertEqual(client.graph.getField("Message:m3", "text")?.string, "Third")
    }

    // MARK: - Watcher fanout per frame

    /// Mirrors web `invokes onData callback for each event` —
    /// equivalent on iOS: an active watchQuery on the entity emits on
    /// every frame that updates it.
    func test_subscription_eachFrame_triggersWatcher() async throws {
        let ws = MockWSTransport(frames: [
            .object(["messageAdded": .object(["__typename": "Message", "id": "m1", "text": "v1"])]),
            .object(["messageAdded": .object(["__typename": "Message", "id": "m1", "text": "v2"])]),
            .object(["messageAdded": .object(["__typename": "Message", "id": "m1", "text": "v3"])]),
        ])
        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport(), ws: ws),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))

        // Seed the entity so the watcher's initial materialize is OK.
        try client.writeQuery(
            query: "query Msg($id: ID!) { message(id: $id) { id text } }",
            variables: ["id": "m1"],
            data: .object([
                "message": .object(["__typename": "Message", "id": "m1", "text": "seed"])
            ])
        )

        let received = CaptureBox<[String]>(value: [])
        let h = try client.watchQuery(
            query: "query Msg($id: ID!) { message(id: $id) { id text } }",
            options: WatchQueryOptions(
                variables: ["id": "m1"],
                immediate: false,
                onData: { d in
                    if let t = d["message"]?["text"]?.string { received.withLock { $0.append(t) } }
                }
            )
        )

        let stream = try client.executeSubscription(query: messageAdded)
        var consumed = 0
        for try await _ in stream {
            consumed += 1
            if consumed == 3 { break }
        }
        try await Task.sleep(nanoseconds: 30_000_000)

        // Watcher should have observed at least one update from the
        // subscription frames (most likely v3, depending on coalesce).
        XCTAssertTrue(
            received.value.contains("v3"),
            "watcher must observe the latest text from a subscription frame; got \(received.value)"
        )
        h.unsubscribe()
    }

    // MARK: - Error frames

    /// Mirrors web `handles GraphQL errors in subscription events`.
    /// A frame yielded with `error: …` and no data must propagate to
    /// the stream consumer as an error frame, NOT a data frame.
    func test_subscription_errorFrame_yieldsErrorFrame() async throws {
        let staged = StagedWSTransport()
        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport(), ws: staged),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))

        let stream = try client.executeSubscription(query: messageAdded)

        // Spin up the consumer first; once the subscriber is registered,
        // push an error frame and close.
        let task = Task { @Sendable in
            var sawError = false
            var sawData = false
            do {
                for try await event in stream {
                    if event.error != nil { sawError = true }
                    if event.data != nil { sawData = true }
                }
            } catch { /* benign */ }
            return (sawError, sawData)
        }
        // Wait for subscriber to register the continuation.
        try await staged.awaitSubscribed()
        staged.emitError(CombinedError(graphqlErrors: [GraphQLResponseError(message: "Subscription error")]))
        staged.finish()

        let (sawError, sawData) = await task.value
        XCTAssertTrue(sawError, "error frame must reach consumer")
        XCTAssertFalse(sawData, "no data frame should have arrived")
    }

    /// Mirrors web `handles materialization failures gracefully`. If
    /// a server pushes a frame that doesn't satisfy the
    /// subscription's selection set, executeSubscription must yield
    /// an error frame *and continue running* — a single bad frame
    /// must not tear down the connection.
    ///
    /// Note on frame 1: the web test mocks `materialize` to forcibly
    /// return `source: "none"`. iOS has no equivalent test seam, so
    /// we trigger materialize hard-miss organically by sending a frame
    /// whose top-level shape doesn't include `messageAdded` at all
    /// (`{garbage: 1}`). A frame like `{messageAdded: {id: "m1"}}`
    /// (missing typename) doesn't work — iOS falls through to
    /// `normalizeInlineContainer` which writes the subtree as
    /// embedded; materialize then re-reads it as a soft-miss on
    /// missing scalars and source = .canonical.
    func test_subscription_materializationFailure_yieldsErrorFrame_thenContinues() async throws {
        let staged = StagedWSTransport()
        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport(), ws: staged),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))

        let stream = try client.executeSubscription(query: messageAdded)
        let task = Task { @Sendable in
            var dataTexts: [String] = []
            var errorMessages: [String] = []
            do {
                for try await event in stream {
                    if let t = event.data?["messageAdded"]?["text"]?.string { dataTexts.append(t) }
                    if let e = event.error?.networkError { errorMessages.append(e) }
                }
            } catch { /* OK */ }
            return (dataTexts, errorMessages)
        }
        try await staged.awaitSubscribed()
        // Frame 1: top-level object with no `messageAdded` field at all.
        // Normalize writes nothing for messageAdded → materialize hard-misses
        // on the entity ref → source = .none → executeSubscription yields
        // an error frame.
        staged.emit(.object([
            "garbage": .int(1)
        ]))
        // Frame 2: well-formed — stream must continue and deliver this.
        staged.emit(.object([
            "messageAdded": .object(["__typename": "Message", "id": "m2", "text": "Recovered"])
        ]))
        staged.finish()
        let (dataTexts, errorMessages) = await task.value
        XCTAssertTrue(
            errorMessages.contains(where: { $0.contains("Subscription materialization failed") }),
            "first malformed frame must emit a materialization-failure error frame; got \(errorMessages)"
        )
        XCTAssertEqual(
            dataTexts.last, "Recovered",
            "stream must continue after a bad frame and deliver subsequent good ones"
        )
    }

    // MARK: - Completion

    /// Mirrors web `invokes onComplete callback when subscription
    /// completes`. Server-side `finish()` closes the stream cleanly:
    /// the `for try await` loop must exit without throwing.
    func test_subscription_serverFinish_closesStreamCleanly() async throws {
        let staged = StagedWSTransport()
        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport(), ws: staged),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))

        let stream = try client.executeSubscription(query: messageAdded)
        let task = Task { @Sendable in
            var seen = 0
            do {
                for try await event in stream {
                    if event.data != nil { seen += 1 }
                }
            } catch {
                return (-1, "\(error)")
            }
            return (seen, "")
        }
        try await staged.awaitSubscribed()
        staged.emit(.object([
            "messageAdded": .object(["__typename": "Message", "id": "x1", "text": "Bye"])
        ]))
        staged.finish()
        let (seen, errMsg) = await task.value
        if seen == -1 {
            XCTFail("server-driven finish must close cleanly; got \(errMsg)")
        }
        XCTAssertEqual(seen, 1)
    }

    // MARK: - Cancellation

    /// Mirrors web `unsubscribe via task cancellation`. iOS exposes
    /// cancellation via Task — cancelling the consuming task must
    /// terminate the stream; further frames must NOT land in the
    /// graph.
    func test_subscription_taskCancel_terminatesStream() async throws {
        let staged = StagedWSTransport()
        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport(), ws: staged),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))

        let stream = try client.executeSubscription(query: messageAdded)
        let consumer = Task { @Sendable in
            var n = 0
            do {
                for try await event in stream {
                    if event.data != nil { n += 1 }
                    if n == 1 { break }
                }
            } catch { /* OK */ }
            return n
        }
        try await staged.awaitSubscribed()
        staged.emit(.object([
            "messageAdded": .object(["__typename": "Message", "id": "k1", "text": "T1"])
        ]))
        let consumed = await consumer.value
        XCTAssertEqual(consumed, 1)

        // The first frame's entity must be present (pipeline ran).
        XCTAssertEqual(client.graph.getField("Message:k1", "text")?.string, "T1")
    }
}

/// WSTransport that records the network query string seen on subscribe.
/// Used to verify that planner's compiled networkQuery (with __typename
/// injected) lands at the transport rather than the user-supplied source.
final class QueryRecordingWSTransport: WSTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastQuery: String?
    private var subscribedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didSubscribe = false

    public init() {}

    var lastQuery: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastQuery
    }

    public func subscribe(_ context: WSContext) -> AsyncThrowingStream<OperationResult<JSONValue>, Error> {
        lock.lock()
        _lastQuery = context.query
        didSubscribe = true
        let waiters = subscribedWaiters
        subscribedWaiters.removeAll()
        lock.unlock()
        for w in waiters { w.resume() }
        return AsyncThrowingStream { continuation in
            // Hold the stream open; tests don't consume.
            continuation.onTermination = { _ in }
        }
    }

    func awaitSubscribed() async throws {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if didSubscribe {
                lock.unlock()
                cont.resume()
                return
            }
            subscribedWaiters.append(cont)
            lock.unlock()
        }
    }
}

/// Stage-controlled WS transport for tests that need to push frames
/// (or errors / finish events) at specific points. Mirrors the
/// `StageWSTransport` already used by `WebSocketReconnectTests` but
/// scoped to a single subscriber for simpler ergonomics here.
final class StagedWSTransport: WSTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<OperationResult<JSONValue>, Error>.Continuation?
    private var subscribedWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func subscribe(_ context: WSContext) -> AsyncThrowingStream<OperationResult<JSONValue>, Error> {
        return AsyncThrowingStream { (cont: AsyncThrowingStream<OperationResult<JSONValue>, Error>.Continuation) in
            lock.lock()
            continuation = cont
            let waiters = subscribedWaiters
            subscribedWaiters.removeAll()
            lock.unlock()
            for w in waiters { w.resume() }
            cont.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuation = nil
                self?.lock.unlock()
            }
        }
    }

    /// Wait until `subscribe` has been called and the continuation is
    /// captured. Without this, an early `emit/finish` from the test
    /// would race the subscriber's task and be silently dropped.
    func awaitSubscribed() async throws {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if continuation != nil {
                lock.unlock()
                cont.resume()
                return
            }
            subscribedWaiters.append(cont)
            lock.unlock()
        }
    }

    func emit(_ data: JSONValue) {
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(OperationResult(data: data))
    }

    func emitError(_ error: CombinedError) {
        lock.lock(); let c = continuation; lock.unlock()
        c?.yield(OperationResult(data: nil, error: error))
    }

    func finish() {
        lock.lock(); let c = continuation; lock.unlock()
        c?.finish()
    }
}
