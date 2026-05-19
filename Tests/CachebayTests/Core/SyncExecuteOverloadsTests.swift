import XCTest
@testable import Cachebay

/// Coverage for the **sync** (callback-returning) overloads of
/// `executeMutation` / `executeQuery` / `executeSubscription`.
///
/// The async forms exist already and are the right shape for code that
/// can `try await`. The sync overloads exist for SwiftUI view actions
/// that need to fire an operation **without** wrapping in `Task { }` —
/// that wrapping defers any synchronous work in the same tick (e.g. a
/// `modifyOptimistic` patch sequenced right before the call) past the
/// next render frame, causing a class of flicker / stale-state bugs.
///
/// Contract the sync overloads commit to:
///
/// 1. The call returns immediately. No blocking on the network.
/// 2. `onData` / `onNetworkData` / `onCacheData` fire as the underlying
///    pipeline produces values (same hook points as the async form).
/// 3. `onError` fires for network / GraphQL errors AND for plan-compile
///    failures that the async form would have thrown.
/// 4. The returned `CachebayToken` can `cancel()` the in-flight work.
///    Callbacks must NOT fire after `cancel()` has flipped `isCancelled`.
/// 5. Internal task is **detached** from the caller's lifecycle —
///    cancelling the caller's enclosing Task does NOT cancel the
///    operation. (Survives view teardown.)

/// Reference-typed thread-safe collector for capturing values from
/// `@Sendable` callbacks under Swift 6 strict concurrency (closures
/// can't capture mutable `var`s).
private final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    private var counter: Int = 0
    func append(_ v: T) { lock.lock(); items.append(v); counter += 1; lock.unlock() }
    func snapshot() -> [T] { lock.lock(); defer { lock.unlock() }; return items }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return counter }
}

final class SyncExecuteOverloadsTests: XCTestCase {

    // MARK: - Fixtures

    struct PostQ: Cachebay.Operation {
        static let networkQuery = """
        query PostQ($id: ID!) {
          post(id: $id) { __typename id title }
        }
        """
        static let document: QueryDocument = .source(networkQuery)
        struct Variables: Cachebay.OperationVariables {
            var id: String
            init(id: String) { self.id = id }
            var __cachebay: [String: JSONValue] { ["id": .string(id)] }
        }
        struct Data: Sendable, Cachebay.OperationData {
            var __data: [String: JSONValue]
            init(__data: [String: JSONValue]) { self.__data = __data }
            var post: Post? { (__data["post"]?.object).map { Post(__data: $0) } }
            struct Post: Sendable, Cachebay.OperationData {
                var __data: [String: JSONValue]
                init(__data: [String: JSONValue]) { self.__data = __data }
                var id: String { (__data["id"]?.string) ?? "" }
                var title: String { (__data["title"]?.string) ?? "" }
            }
        }
    }

    struct UpdatePostM: Cachebay.Operation {
        static let networkQuery = """
        mutation UpdatePostM($id: ID!, $title: String!) {
          updatePost(id: $id, title: $title) { __typename id title }
        }
        """
        static let document: QueryDocument = .source(networkQuery)
        struct Variables: Cachebay.OperationVariables {
            var id: String
            var title: String
            init(id: String, title: String) { self.id = id; self.title = title }
            var __cachebay: [String: JSONValue] {
                ["id": .string(id), "title": .string(title)]
            }
        }
        struct Data: Sendable, Cachebay.OperationData {
            var __data: [String: JSONValue]
            init(__data: [String: JSONValue]) { self.__data = __data }
            var updatePost: UpdatePost? { (__data["updatePost"]?.object).map { UpdatePost(__data: $0) } }
            struct UpdatePost: Sendable, Cachebay.OperationData {
                var __data: [String: JSONValue]
                init(__data: [String: JSONValue]) { self.__data = __data }
                var id: String { (__data["id"]?.string) ?? "" }
                var title: String { (__data["title"]?.string) ?? "" }
            }
        }
    }

    struct PostUpdatedSub: Cachebay.Operation {
        static let networkQuery = """
        subscription PostUpdatedSub($id: ID!) {
          postUpdated(id: $id) { __typename id title }
        }
        """
        static let document: QueryDocument = .source(networkQuery)
        struct Variables: Cachebay.OperationVariables {
            var id: String
            init(id: String) { self.id = id }
            var __cachebay: [String: JSONValue] { ["id": .string(id)] }
        }
        struct Data: Sendable, Cachebay.OperationData {
            var __data: [String: JSONValue]
            init(__data: [String: JSONValue]) { self.__data = __data }
            var postUpdated: PostUpdated? {
                (__data["postUpdated"]?.object).map { PostUpdated(__data: $0) }
            }
            struct PostUpdated: Sendable, Cachebay.OperationData {
                var __data: [String: JSONValue]
                init(__data: [String: JSONValue]) { self.__data = __data }
                var id: String { (__data["id"]?.string) ?? "" }
                var title: String { (__data["title"]?.string) ?? "" }
            }
        }
    }

    struct PostFields: Cachebay.Fragment {
        static let networkQuery = """
        fragment PostFields on Post { __typename id title }
        """
        static let document: QueryDocument = .source(networkQuery)
        static let fragmentName = "PostFields"
        static let onTypename = "Post"
        typealias Variables = Cachebay.EmptyVariables
        struct Data: Sendable, Cachebay.OperationData {
            var __data: [String: JSONValue]
            init(__data: [String: JSONValue]) { self.__data = __data }
            var title: String { (__data["title"]?.string) ?? "" }
        }
    }

    // MARK: - Helpers

    private func makeClient(http: MockHTTPTransport? = nil, ws: MockWSTransport? = nil) -> (CachebayClient, MockHTTPTransport, MockWSTransport) {
        let httpT = http ?? MockHTTPTransport()
        let wsT = ws ?? MockWSTransport()
        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: httpT, ws: wsT),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
        return (client, httpT, wsT)
    }

    // MARK: - 1. executeMutation (sync) — happy path

    func test_executeMutation_sync_returnsToken_andFiresOnData() {
        let http = MockHTTPTransport()
        http.whenQueryContains("UpdatePostM", respondWith: .object([
            "updatePost": .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("renamed"),
            ])
        ]))
        let (client, _, _) = makeClient(http: http)

        let exp = expectation(description: "onData fires after network completes")
        let token = client.executeMutation(
            mutation: UpdatePostM.self,
            variables: .init(id: "p1", title: "renamed"),
            onData: { data in
                XCTAssertEqual(data.updatePost?.title, "renamed")
                XCTAssertEqual(data.updatePost?.id, "p1")
                exp.fulfill()
            },
            onError: { err in XCTFail("unexpected onError: \(err)") }
        )
        // Token is non-nil and the call must NOT have blocked.
        XCTAssertFalse(token.isCancelled, "fresh token should not be cancelled")
        wait(for: [exp], timeout: 2.0)
    }

    // MARK: - 2. executeMutation (sync) — network error path

    func test_executeMutation_sync_firesOnError_onNetworkError() {
        let http = MockHTTPTransport()
        http.whenQueryContains("UpdatePostM", respond: { _ in
            OperationResult(data: nil, error: CombinedError(networkMessage: "not connected"))
        })
        let (client, _, _) = makeClient(http: http)

        let exp = expectation(description: "onError fires on network failure")
        _ = client.executeMutation(
            mutation: UpdatePostM.self,
            variables: .init(id: "p1", title: "renamed"),
            onData: { _ in XCTFail("onData must not fire on network error") },
            onError: { err in
                XCTAssertNotNil(err.networkError, "CombinedError.networkError must be populated for transport errors")
                exp.fulfill()
            }
        )
        wait(for: [exp], timeout: 2.0)
    }

    // MARK: - 3. executeMutation (sync) — cancel suppresses callbacks

    /// Cancel-suppression works at the wrapped-callback layer, not at
    /// the network layer. Whether the underlying request actually
    /// reaches the wire or not depends on `Task.cancel()` propagation —
    /// what we guarantee is that wrapped callbacks check `isCancelled`
    /// before invoking the consumer's handler, so cancel() flipping the
    /// flag synchronously is sufficient to suppress further fires
    /// regardless of when the underlying response arrives.
    func test_executeMutation_sync_cancel_suppressesFurtherCallbacks() {
        let http = MockHTTPTransport()
        http.whenQueryContains("UpdatePostM", respondWith: .object([
            "updatePost": .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("renamed"),
            ])
        ]))
        let (client, _, _) = makeClient(http: http)

        let onDataNotCalled = expectation(description: "onData not called after cancel")
        onDataNotCalled.isInverted = true
        let onErrorNotCalled = expectation(description: "onError not called after cancel")
        onErrorNotCalled.isInverted = true

        let token = client.executeMutation(
            mutation: UpdatePostM.self,
            variables: .init(id: "p1", title: "renamed"),
            onData: { _ in onDataNotCalled.fulfill() },
            onError: { _ in onErrorNotCalled.fulfill() }
        )
        // Synchronous cancel before any scheduled task body has run.
        token.cancel()
        XCTAssertTrue(token.isCancelled, "cancel() must flip isCancelled")
        // Idempotent.
        token.cancel()
        XCTAssertTrue(token.isCancelled)

        wait(for: [onDataNotCalled, onErrorNotCalled], timeout: 0.6)
    }

    // MARK: - 4. executeMutation (sync) — the SwiftUI sync invariant

    /// The whole point of the sync overload: `modifyOptimistic` followed
    /// by `executeMutation` on the same tick observably commits the
    /// optimistic patch before the call returns. Wrapping in
    /// `Task { await ... }` defers this past the next render frame.
    func test_executeMutation_sync_optimistic_visibleBeforeReturn() throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("UpdatePostM", respondWith: .object([
            "updatePost": .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("server-confirmed"),
            ])
        ]))
        let (client, _, _) = makeClient(http: http)

        // Seed cache with a baseline.
        try client.writeFragment(
            fragment: PostFields.self,
            id: "p1",
            variables: .init(),
            data: PostFields.Data(__data: [
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("baseline"),
            ])
        )

        // Sync section: optimistic, then mutate. No `await`, no `Task`.
        let tx = client.modifyOptimistic { b in
            b.patch(fragment: PostFields.self, id: "p1") { draft in
                draft.__data["title"] = .string("optimistic")
            }
        }
        _ = client.executeMutation(
            mutation: UpdatePostM.self,
            variables: .init(id: "p1", title: "server-confirmed")
        )

        // SYNCHRONOUS read — no run-loop spin. Optimistic must be live.
        let read = client.readFragment(fragment: PostFields.self, id: "p1", variables: .init())
        XCTAssertEqual(read?.title, "optimistic",
            "optimistic patch must be observable in the cache immediately after executeMutation returns — that's the whole point of the sync overload")
        tx.dispose()
    }

    // MARK: - 5. executeQuery (sync) — onCacheData / onNetworkData

    func test_executeQuery_sync_firesOnCacheData_andOnNetworkData() throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("PostQ", respondWith: .object([
            "post": .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("from network"),
            ])
        ]))
        let (client, _, _) = makeClient(http: http)

        // Seed cache with the QUERY's shape so the cache-side path
        // satisfies. Writing only the underlying entity via
        // writeFragment isn't enough — the query signature lookup
        // misses if the cache doesn't know it has this query satisfied.
        try client.writeQuery(
            query: PostQ.self,
            variables: .init(id: "p1"),
            data: PostQ.Data(__data: [
                "post": .object([
                    "__typename": .string("Post"),
                    "id": .string("p1"),
                    "title": .string("from cache"),
                ])
            ])
        )

        let cacheExp = expectation(description: "onCacheData fires from the seeded cache")
        let netExp = expectation(description: "onNetworkData fires from the mock transport")
        _ = client.executeQuery(
            query: PostQ.self,
            variables: .init(id: "p1"),
            cachePolicy: .cacheAndNetwork,
            onCacheData: { data, willFetch in
                XCTAssertEqual(data.post?.title, "from cache")
                XCTAssertTrue(willFetch, ".cacheAndNetwork must indicate a follow-up network fetch")
                cacheExp.fulfill()
            },
            onNetworkData: { data in
                XCTAssertEqual(data.post?.title, "from network")
                netExp.fulfill()
            },
            onError: { err in XCTFail("unexpected onError: \(err)") }
        )
        wait(for: [cacheExp, netExp], timeout: 2.0)
    }

    // MARK: - 6. executeQuery (sync) — cancel

    func test_executeQuery_sync_cancel_suppressesNetworkCallback() {
        let http = MockHTTPTransport()
        http.whenQueryContains("PostQ", respondWith: .object([
            "post": .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("from network"),
            ])
        ]))
        let (client, _, _) = makeClient(http: http)

        let suppressed = expectation(description: "onNetworkData must not fire after cancel")
        suppressed.isInverted = true

        let token = client.executeQuery(
            query: PostQ.self,
            variables: .init(id: "p1"),
            cachePolicy: .networkOnly,
            onNetworkData: { _ in suppressed.fulfill() },
            onError: { _ in /* cancel may surface as error; ignore */ }
        )
        token.cancel()
        wait(for: [suppressed], timeout: 0.6)
    }

    // MARK: - 7. executeSubscription (sync) — onData per frame

    func test_executeSubscription_sync_firesOnData_perFrame() {
        let ws = MockWSTransport(frames: [
            .object(["postUpdated": .object(["__typename": "Post", "id": "p1", "title": "v1"])]),
            .object(["postUpdated": .object(["__typename": "Post", "id": "p1", "title": "v2"])]),
            .object(["postUpdated": .object(["__typename": "Post", "id": "p1", "title": "v3"])]),
        ])
        let (client, _, _) = makeClient(ws: ws)

        let exp = expectation(description: "onData fires once per frame")
        exp.expectedFulfillmentCount = 3

        let collector = Collector<String>()

        let token = client.executeSubscription(
            subscription: PostUpdatedSub.self,
            variables: .init(id: "p1"),
            onData: { data in
                if let t = data.postUpdated?.title {
                    collector.append(t)
                }
                exp.fulfill()
            },
            onError: { err in XCTFail("unexpected onError: \(err)") }
        )

        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(collector.snapshot(), ["v1", "v2", "v3"], "every frame must surface as an onData fire")
        token.cancel()
    }

    // MARK: - 8. executeSubscription (sync) — cancel suppresses

    /// Wrapped-callback cancel-suppression: after `cancel()` flips the
    /// flag, subsequent onData wrapped invocations no-op even if the
    /// underlying stream continues to yield. Exact frame count past
    /// cancel depends on scheduling — we assert "0 fires after cancel"
    /// via an inverted expectation, not exact frame count before.
    func test_executeSubscription_sync_cancel_suppressesAllCallbacks() {
        let ws = MockWSTransport(frames: [
            .object(["postUpdated": .object(["__typename": "Post", "id": "p1", "title": "v1"])]),
            .object(["postUpdated": .object(["__typename": "Post", "id": "p1", "title": "v2"])]),
        ])
        let (client, _, _) = makeClient(ws: ws)

        let suppressed = expectation(description: "no onData after cancel")
        suppressed.isInverted = true

        let token = client.executeSubscription(
            subscription: PostUpdatedSub.self,
            variables: .init(id: "p1"),
            onData: { _ in suppressed.fulfill() }
        )
        // Cancel synchronously, before any scheduled stream-consumer task
        // body has had a chance to start firing wrapped callbacks.
        token.cancel()
        XCTAssertTrue(token.isCancelled)

        wait(for: [suppressed], timeout: 0.5)
        _ = token  // keep alive across the wait
    }

    // MARK: - 9. CachebayToken contract

    func test_token_isCancelled_flipsOnCancel() {
        let token = CachebayToken()
        XCTAssertFalse(token.isCancelled)
        token.cancel()
        XCTAssertTrue(token.isCancelled)
    }

    func test_token_cancel_isIdempotent() {
        let token = CachebayToken()
        token.cancel()
        token.cancel()
        token.cancel()
        XCTAssertTrue(token.isCancelled, "repeated cancels stay cancelled and never crash")
    }
}
