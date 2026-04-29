import XCTest
@testable import Cachebay

/// Coverage for the typed surface layered on top of the JSON-shaped
/// runtime: `Operation` / `Fragment` protocols, `OperationData` accessor
/// setters (get + set on every field), typed read/write/watch/execute
/// overloads for queries/mutations/subscriptions/fragments, and the
/// typed optimistic helpers (`b.patch(fragment:target:_:)`,
/// `b.connection(...).addNode(node:options:)` /
/// `addNode(fragment:options:_:)`).
///
/// The fixtures below are hand-rolled to mirror what `cachebay-cli`
/// emits — same shape, same accessor pattern — so the tests assert
/// against the *runtime contract* the codegen relies on rather than
/// against an actual generated file. That keeps the suite independent
/// of the codegen build step.
final class TypedAPITests: XCTestCase {

    // MARK: - Fixtures

    /// Single-entity query. Mirrors the codegen pattern for ops with one
    /// required variable and an object-typed root selection.
    struct TestPost: Cachebay.Operation {
        static let networkQuery = """
        query TestPost($id: ID!) {
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
            var post: Post? {
                get { (__data["post"]?.object).map { Post(__data: $0) } }
                set { __data["post"] = newValue.map { .object($0.__data) } ?? .null }
            }
            struct Post: Sendable, Cachebay.OperationData {
                var __data: [String: JSONValue]
                init(__data: [String: JSONValue]) { self.__data = __data }
                var id: String { (__data["id"]?.string) ?? "" }
                var title: String {
                    get { (__data["title"]?.string) ?? "" }
                    set { __data["title"] = .string(newValue) }
                }
                var __typename: String { (__data["__typename"]?.string) ?? "" }
            }
        }
    }

    /// Variable-less query — `Variables` aliases to `EmptyVariables`,
    /// callers pass `.init()`.
    struct TestMe: Cachebay.Operation {
        static let networkQuery = "query TestMe { me { __typename id name } }"
        static let document: QueryDocument = .source(networkQuery)
        typealias Variables = Cachebay.EmptyVariables
        struct Data: Sendable, Cachebay.OperationData {
            var __data: [String: JSONValue]
            init(__data: [String: JSONValue]) { self.__data = __data }
            var me: Me? {
                get { (__data["me"]?.object).map { Me(__data: $0) } }
                set { __data["me"] = newValue.map { .object($0.__data) } ?? .null }
            }
            struct Me: Sendable, Cachebay.OperationData {
                var __data: [String: JSONValue]
                init(__data: [String: JSONValue]) { self.__data = __data }
                var id: String { (__data["id"]?.string) ?? "" }
                var name: String { (__data["name"]?.string) ?? "" }
            }
        }
    }

    /// Mutation fixture — same protocol, different cache plan kind.
    struct TestUpdatePost: Cachebay.Operation {
        static let networkQuery = """
        mutation TestUpdatePost($id: ID!, $title: String!) {
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
            var updatePost: UpdatePost? {
                get { (__data["updatePost"]?.object).map { UpdatePost(__data: $0) } }
                set { __data["updatePost"] = newValue.map { .object($0.__data) } ?? .null }
            }
            struct UpdatePost: Sendable, Cachebay.OperationData {
                var __data: [String: JSONValue]
                init(__data: [String: JSONValue]) { self.__data = __data }
                var id: String { (__data["id"]?.string) ?? "" }
                var title: String { (__data["title"]?.string) ?? "" }
            }
        }
    }

    /// Subscription fixture.
    struct TestPostUpdated: Cachebay.Operation {
        static let networkQuery = """
        subscription TestPostUpdated($id: ID!) {
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
                get { (__data["postUpdated"]?.object).map { PostUpdated(__data: $0) } }
                set { __data["postUpdated"] = newValue.map { .object($0.__data) } ?? .null }
            }
            struct PostUpdated: Sendable, Cachebay.OperationData {
                var __data: [String: JSONValue]
                init(__data: [String: JSONValue]) { self.__data = __data }
                var id: String { (__data["id"]?.string) ?? "" }
                var title: String { (__data["title"]?.string) ?? "" }
            }
        }
    }

    /// Connection-shaped query — used to assert the layered optimistic
    /// `addNode<N: OperationData>` / `removeNode` flow on a Relay-style
    /// canonical record. The `@connection` directive registers the
    /// canonical so `b.connection(ConnectionSelector(key: "posts"))`
    /// resolves it. No pagination args so the read materialises the
    /// full canonical (no window slicing on cursors that optimistic
    /// edges don't carry).
    struct TestPosts: Cachebay.Operation {
        static let networkQuery = """
        query TestPosts {
          posts @connection(mode: "infinite") {
            __typename
            pageInfo { __typename hasNextPage }
            edges { __typename cursor node { __typename id title } }
          }
        }
        """
        static let document: QueryDocument = .source(networkQuery)
        typealias Variables = Cachebay.EmptyVariables
        struct Data: Sendable, Cachebay.OperationData {
            var __data: [String: JSONValue]
            init(__data: [String: JSONValue]) { self.__data = __data }
            var posts: Posts? {
                get { (__data["posts"]?.object).map { Posts(__data: $0) } }
                set { __data["posts"] = newValue.map { .object($0.__data) } ?? .null }
            }
            struct Posts: Sendable, Cachebay.OperationData {
                var __data: [String: JSONValue]
                init(__data: [String: JSONValue]) { self.__data = __data }
                var pageInfo: PageInfo {
                    get { ((__data["pageInfo"]?.object).map { PageInfo(__data: $0) })! }
                    set { __data["pageInfo"] = .object(newValue.__data) }
                }
                var edges: [Edges]? {
                    get { (__data["edges"]?.array)?.compactMap {
                        if case .object(let o) = $0 { return Edges(__data: o) } else { return nil }
                    } }
                    set { __data["edges"] = newValue.map { .array($0.map { .object($0.__data) }) } ?? .null }
                }
                struct PageInfo: Sendable, Cachebay.OperationData {
                    var __data: [String: JSONValue]
                    init(__data: [String: JSONValue]) { self.__data = __data }
                    var hasNextPage: Bool { (__data["hasNextPage"]?.bool) ?? false }
                }
                struct Edges: Sendable, Cachebay.OperationData, Cachebay.ConnectionEdge {
                    var __data: [String: JSONValue]
                    init(__data: [String: JSONValue]) { self.__data = __data }
                    var cursor: String { (__data["cursor"]?.string) ?? "" }
                    var node: Node? {
                        get { (__data["node"]?.object).map { Node(__data: $0) } }
                        set { __data["node"] = newValue.map { .object($0.__data) } ?? .null }
                    }
                    struct Node: Sendable, Cachebay.OperationData {
                        var __data: [String: JSONValue]
                        init(__data: [String: JSONValue]) { self.__data = __data }
                        var id: String { (__data["id"]?.string) ?? "" }
                        var title: String { (__data["title"]?.string) ?? "" }
                    }
                }
            }
        }
    }

    /// Fragment fixture. Mirrors codegen output: `onTypename` for typed
    /// id-keyed reads/writes, `fragmentName` for plan disambiguation, all
    /// scalar accessors emit `get`/`set` so a closure-built draft can
    /// write through.
    struct TestPostFields: Cachebay.Fragment {
        static let networkQuery = "fragment TestPostFields on Post { __typename id title }"
        static let document: QueryDocument = .source(networkQuery)
        static let fragmentName = "TestPostFields"
        static let onTypename = "Post"
        typealias Variables = Cachebay.EmptyVariables
        struct Data: Sendable, Cachebay.OperationData {
            var __data: [String: JSONValue]
            init(__data: [String: JSONValue]) { self.__data = __data }
            var __typename: String {
                get { (__data["__typename"]?.string) ?? "" }
                set { __data["__typename"] = .string(newValue) }
            }
            var id: String {
                get { (__data["id"]?.string) ?? "" }
                set { __data["id"] = .string(newValue) }
            }
            var title: String {
                get { (__data["title"]?.string) ?? "" }
                set { __data["title"] = .string(newValue) }
            }
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

    // MARK: - readQuery / writeQuery typed

    func test_typedReadQuery_writeQuery_roundtrip() throws {
        let (client, _, _) = makeClient()
        let payload = TestPost.Data(__data: [
            "post": .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("Hello typed"),
            ])
        ])
        try client.writeQuery(query: TestPost.self, variables: .init(id: "p1"), data: payload)

        let read = client.readQuery(query: TestPost.self, variables: .init(id: "p1"))
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.post?.id, "p1")
        XCTAssertEqual(read?.post?.title, "Hello typed")
        XCTAssertEqual(read?.post?.__typename, "Post")
    }

    func test_typedReadQuery_returnsNil_onCacheMiss() {
        let (client, _, _) = makeClient()
        XCTAssertNil(client.readQuery(query: TestPost.self, variables: .init(id: "missing")))
    }

    func test_typedReadQuery_emptyVariables_compiles() throws {
        let (client, _, _) = makeClient()
        let payload = TestMe.Data(__data: [
            "me": .object([
                "__typename": .string("User"),
                "id": .string("u1"),
                "name": .string("Alice"),
            ])
        ])
        try client.writeQuery(query: TestMe.self, variables: .init(), data: payload)
        let read = client.readQuery(query: TestMe.self, variables: .init())
        XCTAssertEqual(read?.me?.name, "Alice")
    }

    // MARK: - Object accessor setters

    func test_objectAccessorSetter_writesBackToData() {
        var data = TestPost.Data(__data: [
            "post": .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("old"),
            ])
        ])
        XCTAssertEqual(data.post?.title, "old")

        // Optional-chained mutation through computed property — only
        // works when the accessor exposes a setter.
        data.post?.title = "new"
        XCTAssertEqual(data.post?.title, "new")

        // Underlying __data dict reflects the write.
        XCTAssertEqual(data.__data["post"]?["title"]?.string, "new")
    }

    func test_objectAccessorSetter_assignNil_setsNullJson() {
        var data = TestPost.Data(__data: [
            "post": .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("hi"),
            ])
        ])
        data.post = nil
        XCTAssertNil(data.post)
        XCTAssertEqual(data.__data["post"], .null)
    }

    func test_objectListAccessorSetter_roundTrips() {
        var posts = TestPosts.Data.Posts(__data: [
            "__typename": .string("PostConnection"),
            "pageInfo": .object(["__typename": .string("PageInfo"), "hasNextPage": .bool(false)]),
            "edges": .array([]),
        ])
        let edge = TestPosts.Data.Posts.Edges(__data: [
            "__typename": .string("PostEdge"),
            "cursor": .string("c1"),
            "node": .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("first"),
            ]),
        ])
        posts.edges = [edge]
        XCTAssertEqual(posts.edges?.count, 1)
        XCTAssertEqual(posts.edges?.first?.node?.id, "p1")
    }

    // MARK: - Typed optimistic patch (b.patch<F>)

    func test_typedPatch_writesOnlyTouchedFields() throws {
        let (client, _, _) = makeClient()
        // Seed the entity record with a known baseline.
        try client.writeFragment(
            fragment: TestPostFields.self,
            id: "p1",
            variables: .init(),
            data: TestPostFields.Data(__data: [
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("v1"),
            ])
        )

        let tx = client.modifyOptimistic { b, _ in
            b.patch(fragment: TestPostFields.self, id: "p1") { draft in
                draft.title = "v2"
            }
        }
        let after = client.readFragment(fragment: TestPostFields.self, id: "p1", variables: .init())
        XCTAssertEqual(after?.title, "v2")

        // Revert restores the baseline.
        tx.revert()
        let reverted = client.readFragment(fragment: TestPostFields.self, id: "p1", variables: .init())
        XCTAssertEqual(reverted?.title, "v1")
    }

    func test_typedPatch_commit_replaysWithServerData() throws {
        let (client, _, _) = makeClient()
        try client.writeFragment(
            fragment: TestPostFields.self,
            id: "p1",
            variables: .init(),
            data: TestPostFields.Data(__data: [
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("v1"),
            ])
        )

        // Two-cycle pattern: optimistic phase patches "Drafting…",
        // commit phase replays the same builder with the server payload
        // so the canonical title becomes whatever the server returned.
        let tx = client.modifyOptimistic { b, ctx in
            b.patch(fragment: TestPostFields.self, id: "p1") { draft in
                draft.title = ctx.data?["title"]?.string ?? "Drafting…"
            }
        }
        XCTAssertEqual(client.readFragment(fragment: TestPostFields.self, id: "p1", variables: .init())?.title, "Drafting…")

        tx.commit(.object(["title": .string("Server confirmed")]))
        XCTAssertEqual(client.readFragment(fragment: TestPostFields.self, id: "p1", variables: .init())?.title, "Server confirmed")
    }

    func test_typedPatch_acceptsIntId() throws {
        // `LosslessStringConvertible` accepts both String and Int for id —
        // the cache key is built as `"\(onTypename):\(id)"`.
        let (client, _, _) = makeClient()
        try client.writeFragment(
            fragment: TestPostFields.self,
            id: 42,
            variables: .init(),
            data: TestPostFields.Data(__data: [
                "__typename": .string("Post"),
                "id": .string("42"),
                "title": .string("v1"),
            ])
        )

        client.modifyOptimistic { b, _ in
            b.patch(fragment: TestPostFields.self, id: 42) { draft in
                draft.title = "via int id"
            }
        }
        XCTAssertEqual(client.readFragment(fragment: TestPostFields.self, id: 42, variables: .init())?.title, "via int id")
    }

    func test_typedPatch_variantFragment_routesViaInterfaceCanonicalKey() throws {
        // Configure interfaces: SpeechClip implements TimelineClip.
        let transport = MockHTTPTransport()
        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: transport, ws: nil),
            cachePolicy: .cacheFirst,
            interfaces: ["TimelineClip": ["SpeechClip", "VideoClip", "MusicClip"]],
            suspensionTimeout: 0
        ))

        // Define a variant fragment rooted on the concrete impl.
        struct SpeechClipMutables: Cachebay.Fragment {
            static let networkQuery = "fragment SpeechClipMutables on SpeechClip { id muted volume }"
            static let document: QueryDocument = .source(networkQuery)
            static let fragmentName = "SpeechClipMutables"
            static let onTypename = "SpeechClip"
            typealias Variables = Cachebay.EmptyVariables
            struct Data: Sendable, Cachebay.OperationData {
                var __data: [String: JSONValue]
                init(__data: [String: JSONValue]) { self.__data = __data }
                var muted: Bool {
                    get { (__data["muted"]?.bool) ?? false }
                    set { __data["muted"] = .bool(newValue) }
                }
                var volume: Double {
                    get { (__data["volume"]?.double) ?? 0.0 }
                    set { __data["volume"] = .double(newValue) }
                }
            }
        }

        // Seed the canonical record under the interface key.
        let seed: [String: JSONValue] = [
            "__typename": .string("SpeechClip"),
            "id": .string("c1"),
            "muted": .bool(false),
            "volume": .double(1.0),
        ]
        client.graph.putRecord("TimelineClip:c1", seed)

        let tx = client.modifyOptimistic { b, _ in
            b.patch(fragment: SpeechClipMutables.self, id: "c1") { d in
                d.muted = true
                d.volume = 0.5
            }
        }
        _ = tx

        // Patch must have landed on the canonical interface key, not on
        // a separate `SpeechClip:c1` record.
        let canonical = client.graph.getRecord("TimelineClip:c1")
        XCTAssertEqual(canonical?["muted"]?.bool, true)
        XCTAssertEqual(canonical?["volume"]?.double, 0.5)
        XCTAssertNil(client.graph.getRecord("SpeechClip:c1"), "variant fragment must NOT create a parallel record at the concrete typename key")
    }

    func test_typedDelete_removesEntity() throws {
        let (client, _, _) = makeClient()
        try client.writeFragment(
            fragment: TestPostFields.self,
            id: "p1",
            variables: .init(),
            data: TestPostFields.Data(__data: [
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("v1"),
            ])
        )
        XCTAssertNotNil(client.readFragment(fragment: TestPostFields.self, id: "p1", variables: .init()))

        let tx = client.modifyOptimistic { b, _ in
            b.delete(fragment: TestPostFields.self, id: "p1")
        }
        tx.commit(nil)
        XCTAssertNil(client.readFragment(fragment: TestPostFields.self, id: "p1", variables: .init()))
    }

    // MARK: - Typed connection addNode / removeNode

    func test_typedConnectionAddNode_typedNode_insertsAtHead() throws {
        let (client, _, _) = makeClient()

        // Two typed nodes — same shape that comes back from a mutation.
        let p2 = TestPosts.Data.Posts.Edges.Node(__data: [
            "__typename": .string("Post"),
            "id": .string("p2"),
            "title": .string("second"),
        ])
        let p1 = TestPosts.Data.Posts.Edges.Node(__data: [
            "__typename": .string("Post"),
            "id": .string("p1"),
            "title": .string("first"),
        ])

        let tx = client.modifyOptimistic { b, _ in
            let c = b.connection(ConnectionSelector(key: "posts"))
            c.addNode(node: p2, options: AddNodeOptions(position: .end))
            c.addNode(node: p1, options: AddNodeOptions(position: .start))
        }
        tx.commit(nil)

        // Verify the canonical's ordered edge list directly — `readQuery`
        // would need a paginated window to surface optimistic edges.
        let canonicalKey: CacheKey = "@connection.posts({})"
        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        let ids: [String] = edges.compactMap { ek in
            guard let nref = client.graph.getField(ek, "node")?.ref else { return nil }
            return client.graph.getField(nref, "id")?.string
        }
        XCTAssertEqual(ids, ["p1", "p2"])
    }

    func test_typedConnectionAddNode_fragmentClosure_buildsOptimisticNode() throws {
        let (client, _, _) = makeClient()

        // Closure-built optimistic node — `__typename` is seeded from
        // `F.onTypename` so the closure only sets domain fields.
        // Asserting on the canonical record directly (`graph.getField`)
        // mirrors how `OptimisticTests.test_addNode_start_and_end`
        // verifies the optimistic engine — readQuery materialise of an
        // optimistic-only canonical needs a populated page window.
        let tx = client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(key: "posts"))
             .addNode(fragment: TestPostFields.self, options: AddNodeOptions(position: .start)) { draft in
                draft.id = "tmp:1"
                draft.title = "Drafting…"
            }
        }
        _ = tx

        let canonicalKey: CacheKey = "@connection.posts({})"
        let edgeRefs = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edgeRefs.count, 1, "optimistic addNode should have produced one edge")
        let nodeRef = edgeRefs.first.flatMap { client.graph.getField($0, "node")?.ref }
        XCTAssertEqual(nodeRef, "Post:tmp:1")
        XCTAssertEqual(client.graph.getField(nodeRef ?? "", "title")?.string, "Drafting…")
        XCTAssertEqual(client.graph.getField(nodeRef ?? "", "__typename")?.string, "Post")
    }

    func test_typedConnectionRemoveNode_byBareId() throws {
        let (client, _, _) = makeClient()

        // Seed two optimistic nodes, then drop one by typed bare id.
        let tx = client.modifyOptimistic { b, _ in
            let c = b.connection(ConnectionSelector(key: "posts"))
            c.addNode(["__typename": "Post", "id": "p1", "title": "a"], options: AddNodeOptions(position: .end))
            c.addNode(["__typename": "Post", "id": "p2", "title": "b"], options: AddNodeOptions(position: .end))
            c.removeNode(fragment: TestPostFields.self, id: "p1")
        }
        tx.commit(nil)

        let canonicalKey: CacheKey = "@connection.posts({})"
        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        let ids: [String] = edges.compactMap { ek in
            guard let nref = client.graph.getField(ek, "node")?.ref else { return nil }
            return client.graph.getField(nref, "id")?.string
        }
        XCTAssertEqual(ids, ["p2"])
    }

    func test_typedAddNode_revert_restoresBaseline() throws {
        let (client, _, _) = makeClient()

        // Baseline: one committed node already in the canonical (added
        // via a previous, committed layer — same path the runtime would
        // build during a network response normalisation).
        let baseline = client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(key: "posts"))
             .addNode(["__typename": "Post", "id": "p2", "title": "b"], options: AddNodeOptions(position: .end))
        }
        baseline.commit(nil)

        let canonicalKey: CacheKey = "@connection.posts({})"
        XCTAssertEqual(client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList?.count, 1)

        // Optimistic add via fragment closure — applies immediately.
        let tx = client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(key: "posts"))
             .addNode(fragment: TestPostFields.self, options: AddNodeOptions(position: .start)) { draft in
                draft.id = "tmp:rollback"
                draft.title = "won't survive"
            }
        }
        XCTAssertEqual(client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList?.count, 2)

        // Revert restores the canonical to the baseline (just `p2`).
        tx.revert()
        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        let ids: [String] = edges.compactMap { ek in
            guard let nref = client.graph.getField(ek, "node")?.ref else { return nil }
            return client.graph.getField(nref, "id")?.string
        }
        XCTAssertEqual(ids, ["p2"], "revert must restore the pre-layer edge list exactly")
    }

    // MARK: - executeQuery / executeMutation typed

    func test_typedExecuteQuery_decodesNetworkResponse() async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("TestPost", respondWith: .object([
            "post": .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("from network"),
            ])
        ]))
        let (client, _, _) = makeClient(http: http)

        let result = try await client.executeQuery(query: TestPost.self, variables: .init(id: "p1"))
        XCTAssertEqual(result.data?.post?.title, "from network")
        XCTAssertEqual(result.meta?.source, .network)
    }

    func test_typedExecuteMutation_decodesNetworkResponse() async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains("TestUpdatePost", respondWith: .object([
            "updatePost": .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("renamed"),
            ])
        ]))
        let (client, _, _) = makeClient(http: http)

        let result = try await client.executeMutation(
            mutation: TestUpdatePost.self,
            variables: .init(id: "p1", title: "renamed")
        )
        XCTAssertEqual(result.data?.updatePost?.title, "renamed")
        XCTAssertEqual(result.data?.updatePost?.id, "p1")
    }

    // MARK: - Fragment typed API

    func test_typedWriteFragment_then_readFragment_byBareId() throws {
        let (client, _, _) = makeClient()
        let payload = TestPostFields.Data(__data: [
            "__typename": .string("Post"),
            "id": .string("p1"),
            "title": .string("via fragment"),
        ])
        // Bare id — typed API constructs cache key as "Post:p1" via
        // `F.onTypename`. No `Post:` prefix in the call.
        try client.writeFragment(
            fragment: TestPostFields.self,
            id: "p1",
            variables: .init(),
            data: payload
        )
        let read = client.readFragment(fragment: TestPostFields.self, id: "p1", variables: .init())
        XCTAssertEqual(read?.id, "p1")
        XCTAssertEqual(read?.title, "via fragment")
    }

    func test_typedReadFragment_returnsNil_onCacheMiss() {
        let (client, _, _) = makeClient()
        XCTAssertNil(client.readFragment(
            fragment: TestPostFields.self,
            id: "missing",
            variables: .init()
        ))
    }

    func test_operationData_as_fragment_reinterpretsViaSharedData() {
        // A subscription's typed nested struct shares its selection with
        // a fragment's `Data` shape — `.as(F.self)` lifts the underlying
        // `__data` into the fragment without any callsite-level
        // dictionary access.
        struct MockSubscriptionRow: Cachebay.OperationData {
            var __data: [String: JSONValue]
            init(__data: [String: JSONValue]) { self.__data = __data }
        }
        let row = MockSubscriptionRow(__data: [
            "__typename": .string("Post"),
            "id": .string("p1"),
            "title": .string("via .as()"),
        ])
        let fragment = row.as(TestPostFields.self)
        XCTAssertEqual(fragment.id, "p1")
        XCTAssertEqual(fragment.title, "via .as()")
    }

    func test_typedFragment_acceptsIntId() throws {
        let (client, _, _) = makeClient()
        try client.writeFragment(
            fragment: TestPostFields.self,
            id: 99,
            variables: .init(),
            data: TestPostFields.Data(__data: [
                "__typename": .string("Post"),
                "id": .string("99"),
                "title": .string("int-keyed"),
            ])
        )
        XCTAssertEqual(
            client.readFragment(fragment: TestPostFields.self, id: 99, variables: .init())?.title,
            "int-keyed"
        )
    }

    func test_typedWatchFragment_emitsInitial_andUpdates() throws {
        let (client, _, _) = makeClient()
        try client.writeFragment(
            fragment: TestPostFields.self,
            id: "p1",
            variables: .init(),
            data: TestPostFields.Data(__data: [
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("initial"),
            ])
        )

        let received = ReceivedTitles()
        let exp = expectation(description: "fragment update fires")
        exp.expectedFulfillmentCount = 2
        let handle = try client.watchFragment(
            fragment: TestPostFields.self,
            id: "p1",
            variables: .init(),
            immediate: true,
            onData: { data in
                received.append(data.title)
                exp.fulfill()
            }
        )

        // Mutate via fragment write — should re-fire the watcher.
        try client.writeFragment(
            fragment: TestPostFields.self,
            id: "p1",
            variables: .init(),
            data: TestPostFields.Data(__data: [
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("updated"),
            ])
        )

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received.snapshot(), ["initial", "updated"])
        handle.unsubscribe()
    }

    // MARK: - ConnectionEdge sugar
    //
    // Generated edge structs always have the same shape: `node: Node?`
    // where `Node: OperationData`. The `ConnectionEdge` protocol surfaces
    // that shape so consumers can replace the rote
    //
    //     edges.compactMap { $0.node?.as(F.self) }
    //
    // with `edges.nodes(as: F.self)`. The cast stays explicit (`as: F.self`),
    // only the compactMap boilerplate disappears.

    func test_sequenceNodesAs_returnsFragmentDataAcrossEdges() {
        // Build two edges, both pointing at Post-shaped nodes.
        let edges: [TestPosts.Data.Posts.Edges] = [
            .init(__data: [
                "cursor": .string("c1"),
                "node": .object([
                    "__typename": .string("Post"),
                    "id": .string("p1"),
                    "title": .string("First"),
                ])
            ]),
            .init(__data: [
                "cursor": .string("c2"),
                "node": .object([
                    "__typename": .string("Post"),
                    "id": .string("p2"),
                    "title": .string("Second"),
                ])
            ]),
        ]

        let posts = edges.nodes(as: TestPostFields.self)
        XCTAssertEqual(posts.map { $0.id }, ["p1", "p2"])
        XCTAssertEqual(posts.map { $0.title }, ["First", "Second"])
    }

    /// Counterpart to `nodes(as:)` — when the consumer wants the
    /// operation-projection node type (e.g. `Projects.Data.Projects.Edges.Node`)
    /// rather than a fragment cast, `.nodes()` unwraps the optional `node`
    /// without crossing the projection seam. Useful when the call site
    /// keeps operation-typed helpers downstream.
    func test_sequenceNodes_unwrapsOperationNodeWithoutFragmentCast() {
        let edges: [TestPosts.Data.Posts.Edges] = [
            .init(__data: ["cursor": .string("c1")]),  // missing node
            .init(__data: [
                "cursor": .string("c2"),
                "node": .object([
                    "__typename": .string("Post"),
                    "id": .string("p2"),
                    "title": .string("Has node"),
                ])
            ]),
        ]
        let nodes = edges.nodes()
        XCTAssertEqual(nodes.count, 1, "missing-node edges must be skipped")
        XCTAssertEqual(nodes[0].id, "p2")
        // Type-check at compile: nodes is `[Edges.Node]`, not a fragment shape.
        let _: TestPosts.Data.Posts.Edges.Node = nodes[0]
    }

    // MARK: - Compile-time fragment data factories
    //
    // The bug we're solving: `F.Data(__data: [...])` accepts any dict —
    // miss a field and the materializer silently silences a watching
    // query at runtime. The fix: codegen-emitted static factories on
    // `F.Data` (and on each `AsX` subtype) that take every selected
    // non-optional field as a named parameter. The compiler enforces
    // coverage; nullable selections get `= nil` defaults.
    //
    // These tests pin the *API shape* with a hand-rolled fixture that
    // mirrors what `cachebay-cli` will emit. The codegen change lands
    // in a follow-up — tests here document the contract the emitter
    // must satisfy.

    /// Polymorphic fragment fixture: `Note` (parent) with two
    /// `... on X` branches (`TextNote`, `ImageNote`). Mirrors the
    /// `ProjectMessageFields` / `ElementFields` shape from FermentCuts
    /// — shared scalars on the parent, subtype-specific fields under
    /// `AsX` accessors. The *desired* additions are static factories
    /// per subtype on `Data` itself.
    struct TestNoteFields: Cachebay.Fragment {
        static let networkQuery = """
        fragment TestNoteFields on Note {
          __typename
          id
          author
          ... on TextNote { body wordCount summary }
          ... on ImageNote { url width height caption }
        }
        """
        static let document: QueryDocument = .source(networkQuery)
        static let fragmentName = "TestNoteFields"
        static let onTypename = "Note"
        typealias Variables = Cachebay.EmptyVariables

        struct Data: Sendable, Cachebay.OperationData {
            var __data: [String: JSONValue]
            init(__data: [String: JSONValue]) { self.__data = __data }
            // Factories — what codegen will emit. Hand-rolled to pin
            // the contract.
            //
            // Required (non-null) fields are positional-named params;
            // nullable selections get `= nil` defaults. The factory
            // stamps `__typename` from the type-condition the call
            // selected — caller never threads a typename string.
            static func textNote(
                id: String,
                author: String,
                body: String,
                wordCount: Int,
                summary: String? = nil
            ) -> Data {
                Data(__data: [
                    "__typename": .string("TextNote"),
                    "id": .string(id),
                    "author": .string(author),
                    "body": .string(body),
                    "wordCount": .int(Int64(wordCount)),
                    "summary": summary.map { .string($0) } ?? .null,
                ])
            }
            static func imageNote(
                id: String,
                author: String,
                url: String,
                width: Int,
                height: Int,
                caption: String? = nil
            ) -> Data {
                Data(__data: [
                    "__typename": .string("ImageNote"),
                    "id": .string(id),
                    "author": .string(author),
                    "url": .string(url),
                    "width": .int(Int64(width)),
                    "height": .int(Int64(height)),
                    "caption": caption.map { .string($0) } ?? .null,
                ])
            }
        }
    }

    /// Each subtype factory must produce a `__data` dict with every
    /// shared + subtype-specific field, `__typename` stamped, and
    /// nullable selections present as `.null` (not absent). The
    /// `.null` is critical: the materializer treats `.none` as "no
    /// field" (warning) and `.null` as "explicit absent" (allowed).
    func test_fragmentDataFactory_textNoteSubtype_buildsFullDict() {
        let data = TestNoteFields.Data.textNote(
            id: "n1", author: "alice",
            body: "hello world", wordCount: 2
        )
        XCTAssertEqual(data.__data["__typename"], .string("TextNote"),
            "factory stamps __typename from the subtype it represents")
        XCTAssertEqual(data.__data["id"], .string("n1"))
        XCTAssertEqual(data.__data["author"], .string("alice"),
            "shared (parent-level) fields land alongside subtype-specific")
        XCTAssertEqual(data.__data["body"], .string("hello world"))
        XCTAssertEqual(data.__data["wordCount"], .int(2))
        XCTAssertEqual(data.__data["summary"], .null,
            "nullable fields the caller omitted must be present as .null — materializer treats .none as 'no field' and warns")
    }

    func test_fragmentDataFactory_imageNoteSubtype_buildsFullDict() {
        let data = TestNoteFields.Data.imageNote(
            id: "n2", author: "bob",
            url: "https://x", width: 800, height: 600,
            caption: "hi"
        )
        XCTAssertEqual(data.__data["__typename"], .string("ImageNote"))
        XCTAssertEqual(data.__data["author"], .string("bob"))
        XCTAssertEqual(data.__data["width"], .int(800))
        XCTAssertEqual(data.__data["caption"], .string("hi"),
            "nullable fields the caller passed must round-trip")
    }

    /// The factory's typed output must round-trip through
    /// `b.writeFragment` cleanly — that's the entire point of compile-
    /// time enforcement: building the data correctly is enough.
    func test_fragmentDataFactory_writeFragment_roundtrip() {
        let (client, _, _) = makeClient()
        let data = TestNoteFields.Data.textNote(
            id: "n1", author: "alice",
            body: "round trip", wordCount: 2,
            summary: "S"
        )
        client.modifyOptimistic { b, _ in
            b.writeFragment(fragment: TestNoteFields.self, id: "n1", data: data)
        }
        // Cache record matches the factory dict — proves writeFragment
        // accepts the factory's wire shape with no transformations.
        let record = client.graph.getRecord("Note:n1")
        XCTAssertEqual(record?["__typename"], .string("TextNote"))
        XCTAssertEqual(record?["body"], .string("round trip"))
        XCTAssertEqual(record?["wordCount"], .int(2))
        XCTAssertEqual(record?["summary"], .string("S"))
    }

    /// `Optional<[Edge]>.nodes()` mirrors `nodes(as:)` — nil → `[]`.
    func test_optionalSequenceNodes_handlesNilAsEmpty() {
        let nilEdges: [TestPosts.Data.Posts.Edges]? = nil
        XCTAssertEqual(nilEdges.nodes().count, 0)

        let some: [TestPosts.Data.Posts.Edges]? = [
            .init(__data: [
                "cursor": .string("c1"),
                "node": .object([
                    "__typename": .string("Post"),
                    "id": .string("p1"),
                    "title": .string("First"),
                ])
            ]),
        ]
        XCTAssertEqual(some.nodes().map { $0.id }, ["p1"])
    }

    func test_optionalSequenceNodesAs_handlesNilAsEmpty_andSkipsMissingNodes() {
        // The `data.jobs?.edges` shape: `[Edges]?` — should support
        // `nodes(as:)` directly without unwrapping.
        let nilEdges: [TestPosts.Data.Posts.Edges]? = nil
        XCTAssertEqual(nilEdges.nodes(as: TestPostFields.self).count, 0,
            ".nodes(as:) on nil sequence must return []")

        // Edge with missing `node` field is skipped (matches the
        // compactMap semantics of the underlying call).
        let mixed: [TestPosts.Data.Posts.Edges]? = [
            .init(__data: ["cursor": .string("c1")]),  // no node
            .init(__data: [
                "cursor": .string("c2"),
                "node": .object([
                    "__typename": .string("Post"),
                    "id": .string("p2"),
                    "title": .string("Has node"),
                ])
            ]),
        ]
        let posts = mixed.nodes(as: TestPostFields.self)
        XCTAssertEqual(posts.map { $0.id }, ["p2"])
    }
}

// MARK: - Test-side state holder
//
// XCTest closures need a `Sendable`-safe place to record values without
// triggering "captured var in concurrently-executing code" warnings.

private final class ReceivedTitles: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return items }
}
