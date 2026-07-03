import XCTest
@testable import Cachebay

/// Per-frame normalization opt-out for subscriptions ("subscription as
/// signal"): an optional `onFrame` hook is evaluated with the RAW frame
/// BEFORE normalization and returns a `FrameDisposition`:
///   • `.normalize` — today's pipeline: write store, fire watchers,
///     deliver the materialized result.
///   • `.skip` — the frame ends here: NO store write, NO watcher fanout,
///     NO data delivery. The caller acted inside `onFrame` (e.g. enqueued
///     a refetch); the follow-up query is then the sole writer.
///
/// Motivating case: a slim high-frequency subscription frame that
/// deliberately omits heavy fields (realtime transport message cap) must
/// not write a partial record where `state == succeeded` but `data` is
/// absent — the write itself is the harmful act, so it must be skipped,
/// not undone.
final class SubscriptionFrameDispositionTests: XCTestCase {

    private let messageAdded = "subscription OnMessage { messageAdded { id text } }"
    private let messageQuery = "query Msg($id: ID!) { message(id: $id) { id text } }"

    private func makeClient(ws: WSTransport) -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport(), ws: ws),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
    }

    // MARK: - .skip is a strict no-op

    /// A skipped frame must not create the entity record and must not
    /// surface as a data frame to the stream consumer.
    func test_skip_writesNothing_andDeliversNoDataFrame() async throws {
        let staged = StagedWSTransport()
        let client = makeClient(ws: staged)

        let stream = try client.executeSubscription(
            query: messageAdded,
            onFrame: { _ in .skip }
        )
        let consumer = Task { @Sendable in
            var dataFrames = 0
            do {
                for try await event in stream where event.data != nil { dataFrames += 1 }
            } catch { /* benign */ }
            return dataFrames
        }
        try await staged.awaitSubscribed()
        staged.emit(.object([
            "messageAdded": .object(["__typename": "Message", "id": "m1", "text": "stealth"])
        ]))
        staged.finish()

        let dataFrames = await consumer.value
        XCTAssertEqual(dataFrames, 0, ".skip must suppress data delivery")
        XCTAssertNil(
            client.graph.getField("Message:m1", "text"),
            ".skip must not write the entity record"
        )
    }

    /// A skipped frame must fire zero watchers AND must not stomp the
    /// record the store already holds (defense-in-depth: a stray slim
    /// frame must not downgrade an existing entity).
    func test_skip_firesZeroWatchers_andPreservesExistingRecord() async throws {
        let staged = StagedWSTransport()
        let client = makeClient(ws: staged)

        try client.writeQuery(
            query: messageQuery,
            variables: ["id": "m1"],
            data: .object([
                "message": .object(["__typename": "Message", "id": "m1", "text": "seed"])
            ])
        )

        let received = CaptureBox<[String]>(value: [])
        let h = try client.watchQuery(
            query: messageQuery,
            options: WatchQueryOptions(
                variables: ["id": "m1"],
                immediate: false,
                onData: { d in
                    if let t = d["message"]?["text"]?.string { received.withLock { $0.append(t) } }
                }
            )
        )

        let stream = try client.executeSubscription(
            query: messageAdded,
            onFrame: { _ in .skip }
        )
        let consumer = Task { @Sendable in
            do { for try await _ in stream {} } catch { /* benign */ }
        }
        try await staged.awaitSubscribed()
        staged.emit(.object([
            "messageAdded": .object(["__typename": "Message", "id": "m1", "text": "stomp"])
        ]))
        staged.finish()
        await consumer.value
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(received.value, [], ".skip must fire zero watchers; got \(received.value)")
        XCTAssertEqual(
            client.graph.getField("Message:m1", "text")?.string, "seed",
            ".skip must leave the existing record untouched"
        )
        h.unsubscribe()
    }

    // MARK: - .normalize is today's behavior

    /// Returning `.normalize` must be indistinguishable from not passing
    /// `onFrame` at all: store write, data delivery, watcher fanout.
    func test_normalize_disposition_matchesDefaultPipeline() async throws {
        let ws = MockWSTransport(frames: [
            .object(["messageAdded": .object(["__typename": "Message", "id": "m1", "text": "Hello"])])
        ])
        let client = makeClient(ws: ws)

        var delivered: [String] = []
        let stream = try client.executeSubscription(
            query: messageAdded,
            onFrame: { _ in .normalize }
        )
        for try await event in stream {
            if let t = event.data?["messageAdded"]?["text"]?.string { delivered.append(t) }
        }

        XCTAssertEqual(delivered, ["Hello"])
        XCTAssertEqual(client.graph.getField("Message:m1", "text")?.string, "Hello")
    }

    // MARK: - Hook contract: raw frame, pre-store

    /// `onFrame` must receive the raw frame exactly as the transport
    /// yielded it, and must run BEFORE the store is touched — even when
    /// it returns `.normalize`.
    func test_onFrame_receivesRawFrame_beforeStoreWrite() async throws {
        let rawFrame: JSONValue = .object([
            "messageAdded": .object(["__typename": "Message", "id": "m1", "text": "Hello"])
        ])
        let ws = MockWSTransport(frames: [rawFrame])
        let client = makeClient(ws: ws)

        let seenFrame = CaptureBox<JSONValue?>(value: nil)
        let storeAtDecision = CaptureBox<JSONValue?>(value: .string("sentinel"))
        let stream = try client.executeSubscription(
            query: messageAdded,
            onFrame: { frame in
                seenFrame.withLock { $0 = frame }
                storeAtDecision.withLock { $0 = client.graph.getField("Message:m1", "text") }
                return .normalize
            }
        )
        for try await event in stream where event.data != nil { break }

        XCTAssertEqual(seenFrame.value, rawFrame, "onFrame must see the raw transport frame")
        XCTAssertNil(storeAtDecision.value, "onFrame must run before the frame is normalized")
    }

    // MARK: - Mixed streams: per-frame decision

    /// One subscription must interleave normalizing and skipped frames;
    /// the hook is consulted per frame, no caching of the first answer.
    func test_mixedStream_evaluatesDispositionPerFrame() async throws {
        let ws = MockWSTransport(frames: [
            .object(["messageAdded": .object(["__typename": "Message", "id": "m1", "text": "First"])]),
            .object(["messageAdded": .object(["__typename": "Message", "id": "m2", "text": "Second"])]),
            .object(["messageAdded": .object(["__typename": "Message", "id": "m3", "text": "Third"])]),
        ])
        let client = makeClient(ws: ws)

        var delivered: [String] = []
        let stream = try client.executeSubscription(
            query: messageAdded,
            onFrame: { frame in
                frame["messageAdded"]?["id"]?.string == "m2" ? .skip : .normalize
            }
        )
        for try await event in stream {
            if let t = event.data?["messageAdded"]?["text"]?.string { delivered.append(t) }
        }

        XCTAssertEqual(delivered, ["First", "Third"])
        XCTAssertEqual(client.graph.getField("Message:m1", "text")?.string, "First")
        XCTAssertNil(client.graph.getField("Message:m2", "text"), "skipped frame must not land")
        XCTAssertEqual(client.graph.getField("Message:m3", "text")?.string, "Third")
    }

    // MARK: - Signal → refetch → write path stays unbroken

    /// After a skipped (signal) frame, a normal query write for the same
    /// entity must fire watchers as usual — the skip must not leave the
    /// store or the watcher graph in a wedged state.
    func test_afterSkip_queryWriteForSameEntity_firesWatchers() async throws {
        let staged = StagedWSTransport()
        let client = makeClient(ws: staged)

        try client.writeQuery(
            query: messageQuery,
            variables: ["id": "m1"],
            data: .object([
                "message": .object(["__typename": "Message", "id": "m1", "text": "v0"])
            ])
        )
        let received = CaptureBox<[String]>(value: [])
        let h = try client.watchQuery(
            query: messageQuery,
            options: WatchQueryOptions(
                variables: ["id": "m1"],
                immediate: false,
                onData: { d in
                    if let t = d["message"]?["text"]?.string { received.withLock { $0.append(t) } }
                }
            )
        )

        let stream = try client.executeSubscription(
            query: messageAdded,
            onFrame: { _ in .skip }
        )
        let consumer = Task { @Sendable in
            do { for try await _ in stream {} } catch { /* benign */ }
        }
        try await staged.awaitSubscribed()
        staged.emit(.object([
            "messageAdded": .object(["__typename": "Message", "id": "m1", "text": "signal"])
        ]))
        staged.finish()
        await consumer.value

        // The "refetch" lands as a plain query write — the sole writer.
        try client.writeQuery(
            query: messageQuery,
            variables: ["id": "m1"],
            data: .object([
                "message": .object(["__typename": "Message", "id": "m1", "text": "v1"])
            ])
        )
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(
            received.value, ["v1"],
            "watcher must see exactly the query write, never the skipped frame; got \(received.value)"
        )
        XCTAssertEqual(client.graph.getField("Message:m1", "text")?.string, "v1")
        h.unsubscribe()
    }

    // MARK: - Hook only sees real data frames

    /// Empty-object data frames and error-only frames bypass the hook
    /// entirely (they were never normalized either); the error still
    /// reaches the consumer.
    func test_onFrame_notInvoked_forEmptyOrErrorOnlyFrames() async throws {
        let staged = StagedWSTransport()
        let client = makeClient(ws: staged)

        let hookCalls = CaptureBox<Int>(value: 0)
        let stream = try client.executeSubscription(
            query: messageAdded,
            onFrame: { _ in
                hookCalls.withLock { $0 += 1 }
                return .skip
            }
        )
        let consumer = Task { @Sendable in
            var errors = 0
            do {
                for try await event in stream where event.error != nil { errors += 1 }
            } catch { /* benign */ }
            return errors
        }
        try await staged.awaitSubscribed()
        staged.emit(.object([:]))
        staged.emitError(CombinedError(networkMessage: "boom"))
        staged.finish()

        let errors = await consumer.value
        XCTAssertEqual(hookCalls.value, 0, "hook must only see non-empty data frames")
        XCTAssertEqual(errors, 1, "error-only frame must still reach the consumer")
    }

    // MARK: - Error frames piggybacked on skipped data

    /// A frame carrying BOTH data and an error: `.skip` suppresses the
    /// data path but must not swallow the error — it still reaches the
    /// consumer as an error frame.
    func test_skip_preservesPiggybackedError() async throws {
        let staged = StagedWSTransport()
        let client = makeClient(ws: staged)

        let stream = try client.executeSubscription(
            query: messageAdded,
            onFrame: { _ in .skip }
        )
        let consumer = Task { @Sendable in
            var sawData = false
            var errors: [String] = []
            do {
                for try await event in stream {
                    if event.data != nil { sawData = true }
                    if let e = event.error { errors.append(e.description) }
                }
            } catch { /* benign */ }
            return (sawData, errors)
        }
        try await staged.awaitSubscribed()
        staged.emit(
            .object(["messageAdded": .object(["__typename": "Message", "id": "m1", "text": "x"])]),
            error: CombinedError(graphqlErrors: [GraphQLResponseError(message: "partial failure")])
        )
        staged.finish()

        let (sawData, errors) = await consumer.value
        XCTAssertFalse(sawData, ".skip must suppress the data frame")
        XCTAssertEqual(errors.count, 1, "the piggybacked error must still be delivered; got \(errors)")
        XCTAssertNil(client.graph.getField("Message:m1", "text"))
    }
}

// MARK: - Typed layer

@CachebayData(typename: "")
private struct CookUpdatedData: Sendable, Hashable, CachebayValue {
    // Non-optional, matching the real schema (`cookUpdated: Cook!`) — so a
    // frame whose `Cook` fails to decode fails the ROOT decode instead of
    // being absorbed as `cookUpdated == nil`.
    let cookUpdated: Cook
    @CachebayData(typename: "Cook")
    struct Cook: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let state: String
    }
}
private struct CookUpdatedSub: CachebayOperation {
    struct Variables: OperationVariables {
        var __cachebay: [String: JSONValue] { [:] }
    }
    typealias Data = CookUpdatedData
    static let document: QueryDocument = .source(
        "subscription CookUpdatedSub { cookUpdated { __typename id state } }"
    )
}

final class TypedSubscriptionFrameDispositionTests: XCTestCase {

    private func makeClient(ws: WSTransport) -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport(), ws: ws),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
    }

    /// The typed hook receives the DECODED raw frame (`Op.Data`); frames
    /// it skips never reach `onData`, frames it normalizes flow through
    /// today's pipeline. Mirrors the intended usage:
    /// `succeeded → signal-only, everything else → normalize live`.
    func test_typed_onFrame_decodedFrame_skipSuppressesOnData() {
        let ws = MockWSTransport(frames: [
            .object(["cookUpdated": .object(["__typename": "Cook", "id": "c1", "state": "running"])]),
            .object(["cookUpdated": .object(["__typename": "Cook", "id": "c1", "state": "succeeded"])]),
            .object(["cookUpdated": .object(["__typename": "Cook", "id": "c1", "state": "failed"])]),
        ])
        let client = makeClient(ws: ws)

        let hookSaw = CaptureBox<[String]>(value: [])
        let dataSaw = CaptureBox<[String]>(value: [])
        let exp = expectation(description: "onData for normalized frames only")
        exp.expectedFulfillmentCount = 2

        let token = client.executeSubscription(
            CookUpdatedSub.self, variables: .init(),
            onFrame: { frame in
                let state = frame.cookUpdated.state
                hookSaw.withLock { $0.append(state) }
                return state == "succeeded" ? .skip : .normalize
            },
            onData: { data in
                dataSaw.withLock { $0.append(data.cookUpdated.state) }
                exp.fulfill()
            },
            onError: { err in XCTFail("unexpected onError: \(err)") }
        )
        wait(for: [exp], timeout: 2.0)

        XCTAssertEqual(hookSaw.value, ["running", "succeeded", "failed"], "hook must see every decoded frame")
        XCTAssertEqual(dataSaw.value, ["running", "failed"], "skipped frame must never reach onData")
        XCTAssertEqual(
            client.graph.getField("Cook:c1", "state")?.string, "failed",
            "store must hold the last NORMALIZED state; the skipped 'succeeded' frame must not have landed"
        )
        token.cancel()
    }

    /// If the raw frame fails the typed decode, the hook cannot run —
    /// the frame falls back to `.normalize` (fail-open: today's pipeline,
    /// which may still normalize/materialize what the typed decode
    /// couldn't represent).
    func test_typed_onFrame_decodeFailure_defaultsToNormalize() async throws {
        // `state` (required) is missing → CookUpdatedData decode fails.
        let ws = MockWSTransport(frames: [
            .object(["cookUpdated": .object(["__typename": "Cook", "id": "c9"])])
        ])
        let client = makeClient(ws: ws)

        let hookCalls = CaptureBox<Int>(value: 0)
        let stream = try client.executeSubscription(
            CookUpdatedSub.self, variables: .init(),
            onFrame: { _ in
                hookCalls.withLock { $0 += 1 }
                return .skip
            }
        )
        for try await _ in stream { break }

        XCTAssertEqual(hookCalls.value, 0, "hook must not run on an undecodable frame")
        XCTAssertEqual(
            client.graph.getField("Cook:c9", "id")?.string, "c9",
            "undecodable frame must fall back to .normalize (fail-open)"
        )
    }
}
