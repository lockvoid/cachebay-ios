import XCTest
@testable import Cachebay

/// Coverage for the **sync** (token-returning) typed overloads:
/// `execute(_:)` / `execute(mutation:)` / `executeSubscription(_:)`. They return
/// immediately, fire callbacks as the pipeline produces values, support cancel via
/// the returned `CachebayToken`, and deliver the cache portion synchronously on the
/// caller's thread (the SwiftUI same-tick invariant).

private final class Collector<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    private var counter: Int = 0
    func append(_ v: T) { lock.lock(); items.append(v); counter += 1; lock.unlock() }
    func snapshot() -> [T] { lock.lock(); defer { lock.unlock() }; return items }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return counter }
}

private let postQuerySource = "query PostQ($id: ID!) { post(id: $id) { __typename id title } }"

@CachebayData(typename: "")
private struct PostQData: Sendable, Hashable, CachebayValue {
    let post: Post?
    @CachebayData(typename: "Post")
    struct Post: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let title: String
    }
}
private struct PostQ: CachebayOperation {
    struct Variables: OperationVariables {
        let id: String
        var __cachebay: [String: JSONValue] { ["id": .string(id)] }
    }
    typealias Data = PostQData
    static let document: QueryDocument = .source(postQuerySource)
}

@CachebayData(typename: "")
private struct UpdatePostData: Sendable, Hashable, CachebayValue {
    let updatePost: UpdatePost?
    @CachebayData(typename: "Post")
    struct UpdatePost: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let title: String
    }
}
private struct UpdatePostM: CachebayOperation {
    struct Variables: OperationVariables {
        let id: String
        let title: String
        var __cachebay: [String: JSONValue] { ["id": .string(id), "title": .string(title)] }
    }
    typealias Data = UpdatePostData
    static let document: QueryDocument = .source(
        "mutation UpdatePostM($id: ID!, $title: String!) { updatePost(id: $id, title: $title) { __typename id title } }"
    )
}

@CachebayData(typename: "")
private struct PostUpdatedData: Sendable, Hashable, CachebayValue {
    let postUpdated: PostUpdated?
    @CachebayData(typename: "Post")
    struct PostUpdated: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let title: String
    }
}
private struct PostUpdatedSub: CachebayOperation {
    struct Variables: OperationVariables {
        let id: String
        var __cachebay: [String: JSONValue] { ["id": .string(id)] }
    }
    typealias Data = PostUpdatedData
    static let document: QueryDocument = .source(
        "subscription PostUpdatedSub($id: ID!) { postUpdated(id: $id) { __typename id title } }"
    )
}

@CachebayData(typename: "Post")
private struct PostFieldsData: Identifiable, Sendable, Hashable, CachebayValue {
    let __typename: String
    let id: String
    let title: String
}
private enum PostFields: CachebayFragment {
    typealias Data = PostFieldsData
    static let fragmentName = "PostFields"
    static let onTypename = "Post"
    static let document: QueryDocument = .source("fragment PostFields on Post { __typename id title }")
    static var __cachebayFieldNames: [AnyKeyPath: String] { PostFieldsData.__cachebayFieldNames }
}

final class SyncExecuteOverloadsTests: XCTestCase {
    private func makeClient(http: MockHTTPTransport? = nil, ws: MockWSTransport? = nil) -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: http ?? MockHTTPTransport(), ws: ws ?? MockWSTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    private func seedPostQ(_ client: CachebayClient, title: String) throws {
        try client.write(query: PostQ.self, variables: .init(id: "p1"), data: PostQData(_dataDict: [
            "post": .object(["__typename": .string("Post"), "id": .string("p1"), "title": .string(title)])
        ])!)
    }

    // 1. execute(mutation:) sync — happy path.
    func test_executeMutation_sync_returnsToken_andFiresOnData() {
        let http = MockHTTPTransport()
        http.whenQueryContains("UpdatePostM", respondWith: .object([
            "updatePost": .object(["__typename": .string("Post"), "id": .string("p1"), "title": .string("renamed")])
        ]))
        let client = makeClient(http: http)
        let exp = expectation(description: "onData")
        let token = client.execute(mutation: UpdatePostM.self, variables: .init(id: "p1", title: "renamed"),
            onData: { data in
                XCTAssertEqual(data.updatePost?.title, "renamed")
                XCTAssertEqual(data.updatePost?.id, "p1")
                exp.fulfill()
            },
            onError: { err in XCTFail("unexpected onError: \(err)") })
        XCTAssertFalse(token.isCancelled)
        wait(for: [exp], timeout: 2.0)
    }

    // 2. execute(mutation:) sync — network error path.
    func test_executeMutation_sync_firesOnError_onNetworkError() {
        let http = MockHTTPTransport()
        http.whenQueryContains("UpdatePostM", respond: { _ in
            OperationResult(data: nil, error: CombinedError(networkMessage: "not connected"))
        })
        let client = makeClient(http: http)
        let exp = expectation(description: "onError")
        _ = client.execute(mutation: UpdatePostM.self, variables: .init(id: "p1", title: "renamed"),
            onData: { _ in XCTFail("onData must not fire on network error") },
            onError: { err in XCTAssertNotNil(err.networkError); exp.fulfill() })
        wait(for: [exp], timeout: 2.0)
    }

    // 3. cancel suppresses callbacks.
    func test_executeMutation_sync_cancel_suppressesFurtherCallbacks() {
        let http = MockHTTPTransport()
        http.whenQueryContains("UpdatePostM", respondWith: .object([
            "updatePost": .object(["__typename": .string("Post"), "id": .string("p1"), "title": .string("renamed")])
        ]))
        let client = makeClient(http: http)
        let onDataNotCalled = expectation(description: "no onData"); onDataNotCalled.isInverted = true
        let onErrorNotCalled = expectation(description: "no onError"); onErrorNotCalled.isInverted = true
        let token = client.execute(mutation: UpdatePostM.self, variables: .init(id: "p1", title: "renamed"),
            onData: { _ in onDataNotCalled.fulfill() }, onError: { _ in onErrorNotCalled.fulfill() })
        token.cancel()
        XCTAssertTrue(token.isCancelled)
        token.cancel()
        XCTAssertTrue(token.isCancelled)
        wait(for: [onDataNotCalled, onErrorNotCalled], timeout: 0.6)
    }

    // 4. The SwiftUI sync invariant: optimistic visible before return.
    func test_executeMutation_sync_optimistic_visibleBeforeReturn() throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("UpdatePostM", respondWith: .object([
            "updatePost": .object(["__typename": .string("Post"), "id": .string("p1"), "title": .string("server-confirmed")])
        ]))
        let client = makeClient(http: http)
        try client.writeFragment(fragment: PostFields.self, id: "p1", data: .init(id: "p1", title: "baseline"))

        let tx = client.modifyOptimistic { b in
            b.patch(fragment: PostFields.self, id: "p1") { $0.set(\.title, "optimistic") }
        }
        _ = client.execute(mutation: UpdatePostM.self, variables: .init(id: "p1", title: "server-confirmed"))

        let read = client.readFragment(fragment: PostFields.self, id: "p1")
        XCTAssertEqual(read?.title, "optimistic",
            "optimistic patch must be observable immediately after execute(mutation:) returns")
        tx.dispose()
    }

    // 5. execute sync — onCacheData / onNetworkData.
    func test_executeQuery_sync_firesOnCacheData_andOnNetworkData() throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("PostQ", respondWith: .object([
            "post": .object(["__typename": .string("Post"), "id": .string("p1"), "title": .string("from network")])
        ]))
        let client = makeClient(http: http)
        try seedPostQ(client, title: "from cache")

        let cacheExp = expectation(description: "onCacheData")
        let netExp = expectation(description: "onNetworkData")
        _ = client.execute(PostQ.self, variables: .init(id: "p1"), cachePolicy: .cacheAndNetwork,
            onCacheData: { data, willFetch in
                XCTAssertEqual(data.post?.title, "from cache")
                XCTAssertTrue(willFetch)
                cacheExp.fulfill()
            },
            onNetworkData: { data in XCTAssertEqual(data.post?.title, "from network"); netExp.fulfill() },
            onError: { err in XCTFail("unexpected onError: \(err)") })
        wait(for: [cacheExp, netExp], timeout: 2.0)
    }

    // 6. execute sync — cancel suppresses network callback.
    func test_executeQuery_sync_cancel_suppressesNetworkCallback() {
        let http = MockHTTPTransport()
        http.whenQueryContains("PostQ", respondWith: .object([
            "post": .object(["__typename": .string("Post"), "id": .string("p1"), "title": .string("from network")])
        ]))
        let client = makeClient(http: http)
        let suppressed = expectation(description: "no onNetworkData"); suppressed.isInverted = true
        let token = client.execute(PostQ.self, variables: .init(id: "p1"), cachePolicy: .networkOnly,
            onNetworkData: { _ in suppressed.fulfill() }, onError: { _ in })
        token.cancel()
        wait(for: [suppressed], timeout: 0.6)
    }

    // 7. executeSubscription sync — onData per frame.
    func test_executeSubscription_sync_firesOnData_perFrame() {
        let ws = MockWSTransport(frames: [
            .object(["postUpdated": .object(["__typename": "Post", "id": "p1", "title": "v1"])]),
            .object(["postUpdated": .object(["__typename": "Post", "id": "p1", "title": "v2"])]),
            .object(["postUpdated": .object(["__typename": "Post", "id": "p1", "title": "v3"])]),
        ])
        let client = makeClient(ws: ws)
        let exp = expectation(description: "per frame"); exp.expectedFulfillmentCount = 3
        let collector = Collector<String>()
        let token = client.executeSubscription(PostUpdatedSub.self, variables: .init(id: "p1"),
            onData: { data in if let t = data.postUpdated?.title { collector.append(t) }; exp.fulfill() },
            onError: { err in XCTFail("unexpected onError: \(err)") })
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(collector.snapshot(), ["v1", "v2", "v3"])
        token.cancel()
    }

    // 8. executeSubscription sync — cancel suppresses.
    func test_executeSubscription_sync_cancel_suppressesAllCallbacks() {
        let ws = MockWSTransport(frames: [
            .object(["postUpdated": .object(["__typename": "Post", "id": "p1", "title": "v1"])]),
            .object(["postUpdated": .object(["__typename": "Post", "id": "p1", "title": "v2"])]),
        ])
        let client = makeClient(ws: ws)
        let suppressed = expectation(description: "no onData"); suppressed.isInverted = true
        let token = client.executeSubscription(PostUpdatedSub.self, variables: .init(id: "p1"),
            onData: { _ in suppressed.fulfill() })
        token.cancel()
        XCTAssertTrue(token.isCancelled)
        wait(for: [suppressed], timeout: 0.5)
        _ = token
    }

    // 9a. cache portion fires synchronously before return.
    func test_executeQuery_sync_cacheFirstHit_firesOnCacheDataSync_beforeReturn() throws {
        let client = makeClient()
        try seedPostQ(client, title: "from cache")
        let order = Collector<Int>()
        order.append(1)
        _ = client.execute(PostQ.self, variables: .init(id: "p1"), cachePolicy: .cacheFirst,
            onCacheData: { _, _ in order.append(2) })
        order.append(3)
        XCTAssertEqual(order.snapshot(), [1, 2, 3], "onCacheData must fire synchronously before return")
    }

    func test_executeQuery_sync_cacheFirstHit_firesOnCacheData_onCallingThread() throws {
        let client = makeClient()
        try seedPostQ(client, title: "t")
        let callerThread = Thread.current
        let callbackThread = Collector<ObjectIdentifier>()
        _ = client.execute(PostQ.self, variables: .init(id: "p1"), cachePolicy: .cacheFirst,
            onCacheData: { _, _ in callbackThread.append(ObjectIdentifier(Thread.current)) })
        XCTAssertEqual(callbackThread.snapshot(), [ObjectIdentifier(callerThread)],
            "cache delivery must run on the calling thread")
    }

    func test_executeQuery_sync_modifyOptimisticThenCacheFirst_seesOptimisticPatchSync() throws {
        let client = makeClient()
        try seedPostQ(client, title: "baseline")
        let tx = client.modifyOptimistic { b in
            b.patch(fragment: PostFields.self, id: "p1") { $0.set(\.title, "optimistic") }
        }
        let captured = Collector<String>()
        _ = client.execute(PostQ.self, variables: .init(id: "p1"), cachePolicy: .cacheFirst,
            onCacheData: { data, _ in captured.append(data.post?.title ?? "") })
        XCTAssertEqual(captured.snapshot(), ["optimistic"],
            "execute(.cacheFirst) must see the optimistic patch synchronously")
        tx.dispose()
    }

    func test_executeQuery_sync_cancelAfterCacheHit_doesNotPreventCacheDelivery() throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("PostQ", respondWith: .object([
            "post": .object(["__typename": .string("Post"), "id": .string("p1"), "title": .string("from network")])
        ]))
        let client = makeClient(http: http)
        try seedPostQ(client, title: "from cache")
        let cacheCount = Collector<Bool>()
        let networkSuppressed = expectation(description: "no onNetworkData"); networkSuppressed.isInverted = true
        let token = client.execute(PostQ.self, variables: .init(id: "p1"), cachePolicy: .cacheAndNetwork,
            onCacheData: { _, _ in cacheCount.append(true) },
            onNetworkData: { _ in networkSuppressed.fulfill() })
        token.cancel()
        XCTAssertEqual(cacheCount.count(), 1, "cache delivery happens synchronously, before cancel() can land")
        wait(for: [networkSuppressed], timeout: 0.6)
    }

    func test_executeQuery_sync_cacheMissOnCacheAndNetwork_doesNotFireOnCacheData() {
        let http = MockHTTPTransport()
        http.whenQueryContains("PostQ", respondWith: .object([
            "post": .object(["__typename": .string("Post"), "id": .string("p1"), "title": .string("from network")])
        ]))
        let client = makeClient(http: http)
        let cacheSuppressed = expectation(description: "no onCacheData on miss"); cacheSuppressed.isInverted = true
        let networkFired = expectation(description: "onNetworkData")
        _ = client.execute(PostQ.self, variables: .init(id: "p1"), cachePolicy: .cacheAndNetwork,
            onCacheData: { _, _ in cacheSuppressed.fulfill() },
            onNetworkData: { _ in networkFired.fulfill() })
        wait(for: [cacheSuppressed, networkFired], timeout: 2.0)
    }

    func test_executeQuery_sync_onCacheDataReentrancy_doesNotDeadlock() throws {
        let client = makeClient()
        try seedPostQ(client, title: "hello")
        let calls = Collector<String>()
        _ = client.execute(PostQ.self, variables: .init(id: "p1"), cachePolicy: .cacheFirst,
            onCacheData: { data, _ in
                calls.append(data.post?.title ?? "")
                // Re-entrant cache read via the raw string API — must not deadlock.
                let read = client.readQuery(query: postQuerySource, variables: ["id": .string("p1")])
                calls.append(read?["post"]?["title"]?.string ?? "missing")
            })
        XCTAssertEqual(calls.snapshot(), ["hello", "hello"], "re-entrant cache read must not deadlock")
    }

    // 9. CachebayToken contract.
    func test_token_isCancelled_flipsOnCancel() {
        let token = CachebayToken()
        XCTAssertFalse(token.isCancelled)
        token.cancel()
        XCTAssertTrue(token.isCancelled)
    }

    func test_token_cancel_isIdempotent() {
        let token = CachebayToken()
        token.cancel(); token.cancel(); token.cancel()
        XCTAssertTrue(token.isCancelled)
    }
}
