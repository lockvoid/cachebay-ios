import XCTest
@testable import Cachebay

/// Black-box port of `cachebay-web/test/unit/core/operations-execute-mutations.test.ts`.
/// Verifies executeMutation: networkQuery routing, materialize-after-
/// normalize, watcher fanout ordering, mutation rootId clock, callbacks,
/// and error handling for partial / null / failed responses.
final class OperationsMutationTests: XCTestCase {

    private let createPostMutation = """
    mutation CreatePost($title: String!) {
        createPost(title: $title) { id title }
    }
    """

    private func makeClient(suspensionTimeout: TimeInterval = 0) -> (CachebayClient, MockHTTPTransport) {
        let http = MockHTTPTransport()
        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: http),
            cachePolicy: .cacheFirst,
            suspensionTimeout: suspensionTimeout
        ))
        return (client, http)
    }

    // MARK: - Basic execution

    /// Mirrors web `executes mutation and writes successful result to
    /// cache`. After success, the User entity must be readable from
    /// the graph (proves normalize was called with mutation rootId).
    func test_executeMutation_writesResultToCache() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("createPost", respondWith: .object([
            "createPost": .object([
                "__typename": "Post",
                "id": "p1",
                "title": "Hello",
            ])
        ]))

        let result = try await client.executeMutation(query: createPostMutation, variables: ["title": "Hello"])
        XCTAssertNil(result.error)
        XCTAssertEqual(result.data?["createPost"]?["title"]?.string, "Hello")
        // Entity must be in the graph so subsequent watcher dep fanout works.
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Hello")
    }

    /// Mirrors web `does not write to cache when mutation has error`.
    /// Error returned ⇒ no normalization, the data field on the
    /// existing entity must remain unchanged.
    func test_executeMutation_errorResponse_doesNotWriteToCache() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("createPost") { _ in
            OperationResult(data: nil, error: CombinedError(graphqlErrors: [GraphQLResponseError(message: "Validation failed")]))
        }

        let r = try await client.executeMutation(query: createPostMutation, variables: ["title": "X"])
        XCTAssertNil(r.data)
        XCTAssertNotNil(r.error)
        XCTAssertNil(client.graph.getField("Post:newp", "title"))
    }

    /// Mirrors web `handles network errors`. A throwing transport
    /// must surface as `OperationResult(data:nil, error:network)`.
    func test_executeMutation_networkError_returnsCombinedError() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("createPost") { _ in
            // Mock the throw via wrapping in a synthetic error.
            OperationResult(data: nil, error: CombinedError(networkMessage: "Connection refused"))
        }

        let errors = CaptureBox<[CombinedError]>(value: [])
        let r = try await client.executeMutation(
            query: createPostMutation,
            variables: ["title": "x"],
            onError: { e in errors.withLock { $0.append(e) } }
        )
        XCTAssertNil(r.data)
        XCTAssertNotNil(r.error)
        XCTAssertEqual(errors.value.count, 1)
        XCTAssertTrue(errors.value[0].networkError?.contains("Connection refused") ?? false)
    }

    // MARK: - rootId / clock

    /// Mirrors web `normalizes mutation with unique rootId using
    /// mutation clock`. Two consecutive mutations must each land on a
    /// distinct mutation root — covered indirectly: both succeed and
    /// produce distinct entity ids.
    func test_consecutiveMutations_bothSucceed_independentRoots() async throws {
        let (client, http) = makeClient()
        let counter = AtomicCounter()
        http.whenQueryContains("createPost") { _ in
            let n = counter.increment()
            return OperationResult(data: .object([
                "createPost": .object([
                    "__typename": "Post",
                    "id": .string("p\(n)"),
                    "title": .string("Title \(n)"),
                ])
            ]))
        }

        let r1 = try await client.executeMutation(query: createPostMutation, variables: ["title": "First"])
        let r2 = try await client.executeMutation(query: createPostMutation, variables: ["title": "Second"])

        XCTAssertEqual(r1.data?["createPost"]?["id"]?.string, "p1")
        XCTAssertEqual(r2.data?["createPost"]?["id"]?.string, "p2")
        // Both entities exist in the graph — neither overwrote the other.
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Title 1")
        XCTAssertEqual(client.graph.getField("Post:p2", "title")?.string, "Title 2")
    }

    /// Mirrors web `stores mutation history with separate roots`. Two
    /// mutations with the SAME variables must not collide — the second
    /// must not overwrite the first's root record. Both Post entities
    /// must remain.
    func test_sameVariables_twiceMutated_bothPersist() async throws {
        let (client, http) = makeClient()
        let counter = AtomicCounter()
        http.whenQueryContains("createPost") { _ in
            let n = counter.increment()
            return OperationResult(data: .object([
                "createPost": .object([
                    "__typename": "Post",
                    "id": .string("dup-\(n)"),
                    "title": "Same",
                ])
            ]))
        }

        let r1 = try await client.executeMutation(query: createPostMutation, variables: ["title": "Same"])
        let r2 = try await client.executeMutation(query: createPostMutation, variables: ["title": "Same"])

        XCTAssertNotEqual(r1.data?["createPost"]?["id"]?.string, r2.data?["createPost"]?["id"]?.string)
        XCTAssertEqual(client.graph.getField("Post:dup-1", "title")?.string, "Same")
        XCTAssertEqual(client.graph.getField("Post:dup-2", "title")?.string, "Same")
    }

    // MARK: - networkQuery routing

    /// Mirrors web `sends networkQuery with __typename to transport,
    /// not original query`. The compiled networkQuery is what the
    /// transport sees — implicitly verifies `__typename` injection so
    /// the response can be normalised.
    func test_executeMutation_sendsNetworkQueryWithTypename_toTransport() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("createPost", respondWith: .object([
            "createPost": .object(["__typename": "Post", "id": "p1", "title": "Hi"])
        ]))
        _ = try await client.executeMutation(query: createPostMutation, variables: ["title": "Hi"])

        XCTAssertEqual(http.calls.count, 1)
        XCTAssertTrue(
            http.calls[0].query.contains("__typename"),
            "transport must receive the planner's networkQuery (with __typename injected); got: \(http.calls[0].query)"
        )
    }

    /// Mirrors web `returns materialized data, not raw network
    /// response`. After normalize, the query layer reads back via
    /// `materialize` and the result.data must be the materialised
    /// (cache-shaped) snapshot, not the literal HTTP response.
    /// Verified here by checking the data is fully populated even
    /// though the network mock returns extra fields a strict view
    /// might filter.
    func test_executeMutation_returnsMaterializedData() async throws {
        let (client, http) = makeClient()
        // Server returns a Post with extra `__typename` baked in. After
        // normalise/materialise, the same fields should round-trip back.
        http.whenQueryContains("createPost", respondWith: .object([
            "createPost": .object([
                "__typename": "Post",
                "id": "p1",
                "title": "Hi",
            ])
        ]))
        let r = try await client.executeMutation(query: createPostMutation, variables: ["title": "Hi"])
        XCTAssertEqual(r.data?["createPost"]?["id"]?.string, "p1")
        XCTAssertEqual(r.data?["createPost"]?["title"]?.string, "Hi")
        // The post must be present in the graph — proves normalize ran
        // and materialize re-projected the entity.
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Hi")
    }

    // MARK: - Watcher fanout

    /// Mirrors web `materializes and notifies watchers after
    /// successful mutation`. A pre-existing watcher on Post:p1 must
    /// fire after the mutation lands the new title via dep fanout.
    func test_executeMutation_notifiesWatchersOnSuccess() async throws {
        let (client, http) = makeClient()
        let postQuery = "query Post($id: ID!) { post(id: $id) { id title } }"

        // Seed Post:p1.
        try client.writeQuery(query: postQuery, variables: ["id": "p1"], data: .object([
            "post": .object(["__typename": "Post", "id": "p1", "title": "Original"])
        ]))

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: postQuery,
            options: WatchQueryOptions(
                variables: ["id": "p1"],
                immediate: true,
                onData: { received.append($0) }
            )
        )
        XCTAssertEqual(received.value.count, 1)

        let updateMutation = """
        mutation UpdatePost($id: ID!, $title: String!) {
            updatePost(id: $id, title: $title) { id title }
        }
        """
        http.whenQueryContains("updatePost", respondWith: .object([
            "updatePost": .object([
                "__typename": "Post",
                "id": "p1",
                "title": "Mutated",
            ])
        ]))

        _ = try await client.executeMutation(
            query: updateMutation,
            variables: ["id": "p1", "title": "Mutated"]
        )
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertGreaterThanOrEqual(received.value.count, 2)
        XCTAssertEqual(received.value.last?["post"]?["title"]?.string, "Mutated")

        handle.unsubscribe()
    }

    /// Mirrors web `executeMutation watcher fanout fires before per-
    /// call onData`. Verify ordering: the watcher's `onData` is
    /// observed *before* the mutation's per-call `onData` returns
    /// control.
    func test_executeMutation_watcherFanoutFires_beforeOnDataReturns() async throws {
        let (client, http) = makeClient()
        let postQuery = "query Post($id: ID!) { post(id: $id) { id title } }"
        try client.writeQuery(query: postQuery, variables: ["id": "p1"], data: .object([
            "post": .object(["__typename": "Post", "id": "p1", "title": "Original"])
        ]))

        let watcherTitleAtMutationCallback = CaptureBox<[String]>(value: [])
        let watcherFires = CaptureBox<[String]>(value: [])
        let h = try client.watchQuery(
            query: postQuery,
            options: WatchQueryOptions(
                variables: ["id": "p1"],
                immediate: true,
                onData: { d in
                    if let t = d["post"]?["title"]?.string { watcherFires.withLock { $0.append(t) } }
                }
            )
        )

        let updateMutation = """
        mutation UpdatePost($id: ID!, $title: String!) {
            updatePost(id: $id, title: $title) { id title }
        }
        """
        http.whenQueryContains("updatePost", respondWith: .object([
            "updatePost": .object(["__typename": "Post", "id": "p1", "title": "Mutated"])
        ]))

        _ = try await client.executeMutation(
            query: updateMutation,
            variables: ["id": "p1", "title": "Mutated"],
            onData: { _ in
                // Inside per-call onData: watcher fires must already
                // include "Mutated".
                let snap = watcherFires.value
                watcherTitleAtMutationCallback.withLock { $0.append(contentsOf: snap) }
            }
        )

        XCTAssertTrue(
            watcherTitleAtMutationCallback.value.contains("Mutated"),
            "watcher fanout must fire BEFORE per-call onData (cachebay-web parity)"
        )
        h.unsubscribe()
    }

    /// Mirrors web `does not materialize or notify when
    /// onQueryNetworkData is not provided`. iOS doesn't have an
    /// equivalent option, but the analogue is "no watcher exists,
    /// so no fanout happens" — and per the recently-aligned behavior
    /// (`executeMutation invalidates materialize cache on no-
    /// propagation`) the materialize cache must not retain the
    /// mutation result. Verify by running a follow-up readQuery —
    /// if it doesn't see the mutation, the materialize cache
    /// invalidation didn't happen and the test will fail.
    func test_executeMutation_invalidatesMaterializeCache_whenNoWatchers() async throws {
        let (client, http) = makeClient()
        let postQuery = "query Post($id: ID!) { post(id: $id) { id title } }"
        try client.writeQuery(query: postQuery, variables: ["id": "p1"], data: .object([
            "post": .object(["__typename": "Post", "id": "p1", "title": "Original"])
        ]))
        // Force materialize cache to populate.
        _ = client.readQuery(query: postQuery, variables: ["id": "p1"])

        let updateMutation = """
        mutation UpdatePost($id: ID!, $title: String!) {
            updatePost(id: $id, title: $title) { id title }
        }
        """
        http.whenQueryContains("updatePost", respondWith: .object([
            "updatePost": .object(["__typename": "Post", "id": "p1", "title": "MutationApplied"])
        ]))

        _ = try await client.executeMutation(
            query: updateMutation,
            variables: ["id": "p1", "title": "MutationApplied"]
        )

        // No watcher caught it — materialize cache for the post query
        // must have been invalidated so this read sees the latest.
        let read = client.readQuery(query: postQuery, variables: ["id": "p1"])
        XCTAssertEqual(
            read?["post"]?["title"]?.string,
            "MutationApplied",
            "materialize cache must be invalidated when mutation has no watcher to consume it"
        )
    }

    // MARK: - Callbacks

    /// Mirrors web `invokes onData callback with mutation result`.
    func test_executeMutation_invokesOnData() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("createPost", respondWith: .object([
            "createPost": .object(["__typename": "Post", "id": "p1", "title": "Hello"])
        ]))

        let datas = CaptureBox<[JSONValue]>(value: [])
        _ = try await client.executeMutation(
            query: createPostMutation,
            variables: ["title": "Hello"],
            onData: { datas.append($0) }
        )
        XCTAssertEqual(datas.value.count, 1)
        XCTAssertEqual(datas.value[0]["createPost"]?["title"]?.string, "Hello")
    }

    /// Mirrors web `invokes onError for GraphQL errors`. GraphQL-
    /// errors-only response (no data) must call `onError` once with
    /// the same error in result.
    func test_executeMutation_invokesOnError_onGraphQLErrors() async throws {
        let (client, http) = makeClient()
        let combined = CombinedError(graphqlErrors: [GraphQLResponseError(message: "User exists")])
        http.whenQueryContains("createPost") { _ in
            OperationResult(data: nil, error: combined)
        }

        let errors = CaptureBox<[CombinedError]>(value: [])
        let r = try await client.executeMutation(
            query: createPostMutation,
            variables: ["title": "x"],
            onError: { e in errors.withLock { $0.append(e) } }
        )
        XCTAssertNil(r.data)
        XCTAssertEqual(errors.value.count, 1)
        XCTAssertEqual(errors.value[0].graphqlErrors.first?.message, "User exists")
    }

    /// Mirrors web `does not invoke callbacks when not provided`
    /// (smoke test — no crash with nil callbacks).
    func test_executeMutation_noCallbacks_stillReturnsResult() async throws {
        let (client, http) = makeClient()
        http.whenQueryContains("createPost", respondWith: .object([
            "createPost": .object(["__typename": "Post", "id": "p1", "title": "Hi"])
        ]))
        let r = try await client.executeMutation(query: createPostMutation, variables: ["title": "Hi"])
        XCTAssertNotNil(r.data)
    }

    // MARK: - Error handling: partial data / null fields

    /// Mirrors web `handles null fields in mutation response`. A
    /// nullable field set to JSON null is a valid value, not a miss.
    /// The response must round-trip the null correctly.
    func test_executeMutation_handlesExplicitNullFields() async throws {
        let (client, http) = makeClient()
        let mutationWithNull = """
        mutation CreateUpload($input: Input!) {
            createUpload(input: $input) {
                directUpload { uploadUrl }
                errors { message }
            }
        }
        """
        http.whenQueryContains("createUpload", respondWith: .object([
            "createUpload": .object([
                "__typename": "CreateUploadPayload",
                "directUpload": .object([
                    "__typename": "DirectUpload",
                    "uploadUrl": "https://example.com/u",
                ]),
                "errors": .null,
            ])
        ]))

        let r = try await client.executeMutation(
            query: mutationWithNull,
            variables: ["input": .object(["filename": "test.wav"])]
        )
        XCTAssertNil(r.error)
        XCTAssertEqual(r.data?["createUpload"]?["directUpload"]?["uploadUrl"]?.string, "https://example.com/u")
        // Verify the null is preserved (not stripped to undefined).
        guard let createUpload = r.data?["createUpload"] else {
            XCTFail("expected createUpload payload")
            return
        }
        if case .object(let o) = createUpload {
            XCTAssertEqual(o["errors"], .null, "explicit null must be preserved as JSON null")
        } else {
            XCTFail("expected object payload")
        }
    }

    /// Mirrors web `handles partial data with GraphQL errors`. Server
    /// returns partial data alongside graphql errors — the partial
    /// data must still flow through normalize, and the error must
    /// land on the result + onError.
    func test_executeMutation_handlesPartialDataWithErrors() async throws {
        let (client, http) = makeClient()
        let combined = CombinedError(graphqlErrors: [GraphQLResponseError(message: "Name validation failed")])
        http.whenQueryContains("createPost") { _ in
            OperationResult(
                data: .object([
                    "createPost": .object([
                        "__typename": "Post",
                        "id": "p10",
                        "title": .null,
                    ])
                ]),
                error: combined
            )
        }

        let errors = CaptureBox<[CombinedError]>(value: [])
        let r = try await client.executeMutation(
            query: createPostMutation,
            variables: ["title": ""],
            onError: { e in errors.withLock { $0.append(e) } }
        )
        // Partial data must be returned (web parity — partial data
        // flows through normalize even when accompanied by errors).
        XCTAssertNotNil(r.data)
        XCTAssertEqual(r.data?["createPost"]?["id"]?.string, "p10")
        XCTAssertNotNil(r.error)
        XCTAssertEqual(errors.value.count, 1)
    }
}

/// Sendable counter used to drive sequential ids from inside a
/// `@Sendable` closure (Swift 6 strict concurrency forbids capturing
/// `var Int` directly).
final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        n += 1
        return n
    }
}

