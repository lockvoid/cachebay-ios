import XCTest
@testable import Cachebay

/// Coverage for the v1.0 **typed-struct** surface layered on top of the
/// JSON-shaped runtime: the `CachebayOperation` / `CachebayFragment`
/// protocols, the typed read/write/execute overloads for queries,
/// mutations and fragments, and the typed optimistic helpers
/// (`b.patch(fragment:id:) { $0.set(\.field, value) }`,
/// `b.connection(...).linkNode(node:)` / `linkNode(fragment:id:)` /
/// `unlinkNode(fragment:id:)`).
///
/// The fixtures below are hand-rolled to mirror what `cachebay-cli`
/// emits — `@CachebayData` structs (real `let`-only fields, eager decode
/// via `CachebayValue`) wrapped by `CachebayOperation` / `CachebayFragment`
/// — so the tests assert against the runtime contract the codegen relies
/// on rather than an actual generated file.
///
/// ## Retired dict-wrapper tests
/// The legacy (0.x) version of this file also covered mechanics that the
/// typed surface removes *by construction*; those tests were dropped here,
/// their coverage having moved to a typed home:
///   • `objectAccessorSetter_*` (mutable `var field { get set }` on the
///     dict wrapper) → typed structs are `let`-only; mutation goes through
///     the KeyPath patch builder, covered by the `test_typedPatch_*` cases
///     below.
///   • `operationData_as_fragment` / `sequenceNodes(as:)` / `nodes()` sugar
///     (`.as(F.self)` dict reinterpretation + `compactMap` over `__data`) →
///     typed nodes are concrete decoded values; consumers read
///     `edges.map(\.node)` directly, no projection seam to paper over.
///   • `fragmentDataFactory_*` (hand-rolled `Data.textNote(…)` dict
///     factories) → the `@CachebayData` memberwise init *is* the
///     compiler-enforced factory, and polymorphic subtype construction +
///     `.unknown` dispatch is covered by `CachebayInterfaceBehaviourTests`.

// MARK: - Fixtures (mirror cachebay-cli typed output)

/// Single-entity query with one required variable and an object-typed root
/// selection.
@CachebayData(typename: "")
private struct TestPostData: Sendable, Hashable, CachebayValue {
    let post: Post?
    @CachebayData(typename: "Post")
    struct Post: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let title: String
    }
}
private struct TestPost: CachebayOperation {
    struct Variables: OperationVariables {
        let id: String
        var __cachebay: [String: JSONValue] { ["id": .string(id)] }
    }
    typealias Data = TestPostData
    static let document: QueryDocument = .source(
        "query TestPost($id: ID!) { post(id: $id) { __typename id title } }"
    )
}

/// Variable-less query — `Variables` aliases to `EmptyVariables`.
@CachebayData(typename: "")
private struct TestMeData: Sendable, Hashable, CachebayValue {
    let me: Me?
    @CachebayData(typename: "User")
    struct Me: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let name: String
    }
}
private struct TestMe: CachebayOperation {
    typealias Variables = EmptyVariables
    typealias Data = TestMeData
    static let document: QueryDocument = .source("query TestMe { me { __typename id name } }")
}

/// Mutation fixture — same protocol, different cache-plan kind.
@CachebayData(typename: "")
private struct TestUpdatePostData: Sendable, Hashable, CachebayValue {
    let updatePost: UpdatePost?
    @CachebayData(typename: "Post")
    struct UpdatePost: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let title: String
    }
}
private struct TestUpdatePost: CachebayOperation {
    struct Variables: OperationVariables {
        let id: String
        let title: String
        var __cachebay: [String: JSONValue] { ["id": .string(id), "title": .string(title)] }
    }
    typealias Data = TestUpdatePostData
    static let document: QueryDocument = .source(
        "mutation TestUpdatePost($id: ID!, $title: String!) { updatePost(id: $id, title: $title) { __typename id title } }"
    )
}

/// Fragment fixture — `onTypename` keys typed id-based reads/writes,
/// `fragmentName` disambiguates the plan, `Data` is a `@CachebayData`
/// struct so `__cachebayFieldNames` powers the KeyPath patch builder.
@CachebayData(typename: "Post")
private struct TestPostFieldsData: Identifiable, Sendable, Hashable, CachebayValue {
    let __typename: String
    let id: String
    let title: String
}
private enum TestPostFields: CachebayFragment {
    typealias Data = TestPostFieldsData
    static let fragmentName = "TestPostFields"
    static let onTypename = "Post"
    static let document: QueryDocument = .source("fragment TestPostFields on Post { __typename id title }")
    static var __cachebayFieldNames: [AnyKeyPath: String] { TestPostFieldsData.__cachebayFieldNames }
}

/// Variant fragment rooted on a concrete impl (`SpeechClip`) of an
/// interface (`TimelineClip`). Patching it must route through the
/// interface canonical key. Only the mutable fields are selected.
@CachebayData(typename: "SpeechClip")
private struct SpeechClipMutablesData: Sendable, Hashable, CachebayValue {
    let muted: Bool
    let volume: Double
}
private enum SpeechClipMutables: CachebayFragment {
    typealias Data = SpeechClipMutablesData
    static let fragmentName = "SpeechClipMutables"
    static let onTypename = "SpeechClip"
    static let document: QueryDocument = .source("fragment SpeechClipMutables on SpeechClip { id muted volume }")
    static var __cachebayFieldNames: [AnyKeyPath: String] { SpeechClipMutablesData.__cachebayFieldNames }
}

final class TypedAPITests: XCTestCase {

    // MARK: - Helpers

    private func makeClient(http: MockHTTPTransport? = nil, ws: MockWSTransport? = nil) -> (CachebayClient, MockHTTPTransport, MockWSTransport) {
        let httpT = http ?? MockHTTPTransport()
        let wsT = ws ?? MockWSTransport()
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: httpT, ws: wsT),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
        return (client, httpT, wsT)
    }

    // MARK: - read / write (typed)

    func test_typedReadQuery_writeQuery_roundtrip() throws {
        let (client, _, _) = makeClient()
        let payload = TestPost.Data(post: .init(id: "p1", title: "Hello typed"))
        try client.write(query: TestPost.self, variables: .init(id: "p1"), data: payload)

        let read = client.read(TestPost.self, variables: .init(id: "p1"))
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.post?.id, "p1")
        XCTAssertEqual(read?.post?.title, "Hello typed")
        XCTAssertEqual(read?.post?.__typename, "Post")
    }

    func test_typedReadQuery_returnsNil_onCacheMiss() {
        let (client, _, _) = makeClient()
        XCTAssertNil(client.read(TestPost.self, variables: .init(id: "missing")))
    }

    func test_typedReadQuery_emptyVariables_compiles() throws {
        let (client, _, _) = makeClient()
        let payload = TestMe.Data(me: .init(id: "u1", name: "Alice"))
        try client.write(query: TestMe.self, variables: .init(), data: payload)
        let read = client.read(TestMe.self, variables: .init())
        XCTAssertEqual(read?.me?.name, "Alice")
    }

    // MARK: - Typed optimistic patch (b.patch<F>)

    func test_typedPatch_writesOnlyTouchedFields() throws {
        let (client, _, _) = makeClient()
        // Seed the entity record with a known baseline.
        try client.writeFragment(fragment: TestPostFields.self, id: "p1", data: .init(id: "p1", title: "v1"))

        let tx = client.modifyOptimistic { b in
            b.patch(fragment: TestPostFields.self, id: "p1") { $0.set(\.title, "v2") }
        }
        let after = client.readFragment(fragment: TestPostFields.self, id: "p1")
        XCTAssertEqual(after?.title, "v2")

        // Revert restores the baseline.
        tx.revert()
        let reverted = client.readFragment(fragment: TestPostFields.self, id: "p1")
        XCTAssertEqual(reverted?.title, "v1")
    }

    func test_typedPatch_commit_replaysWithServerData() throws {
        let (client, _, _) = makeClient()
        try client.writeFragment(fragment: TestPostFields.self, id: "p1", data: .init(id: "p1", title: "v1"))

        // Split-closure pattern: optimistic closure patches "Drafting…",
        // commit closure writes the (simulated) server-confirmed title.
        let tx = client.modifyOptimistic { b in
            b.patch(fragment: TestPostFields.self, id: "p1") { $0.set(\.title, "Drafting…") }
        }
        XCTAssertEqual(client.readFragment(fragment: TestPostFields.self, id: "p1")?.title, "Drafting…")

        let serverTitle = "Server confirmed"
        tx.commit { b in
            b.patch(fragment: TestPostFields.self, id: "p1") { $0.set(\.title, serverTitle) }
        }
        XCTAssertEqual(client.readFragment(fragment: TestPostFields.self, id: "p1")?.title, "Server confirmed")
    }

    func test_typedPatch_acceptsIntId() throws {
        // `LosslessStringConvertible` accepts both String and Int for id —
        // the cache key is built as `"\(onTypename):\(id)"`.
        let (client, _, _) = makeClient()
        try client.writeFragment(fragment: TestPostFields.self, id: 42, data: .init(id: "42", title: "v1"))

        client.modifyOptimistic { b in
            b.patch(fragment: TestPostFields.self, id: 42) { $0.set(\.title, "via int id") }
        }
        XCTAssertEqual(client.readFragment(fragment: TestPostFields.self, id: 42)?.title, "via int id")
    }

    func test_typedPatch_variantFragment_routesViaInterfaceCanonicalKey() throws {
        // Configure interfaces: SpeechClip implements TimelineClip.
        let transport = MockHTTPTransport()
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: transport, ws: nil),
                cachePolicy: .cacheFirst,
                interfaces: ["TimelineClip": ["SpeechClip", "VideoClip", "MusicClip"]],
                suspensionTimeout: 0
            ))

        // Seed the canonical record under the interface key.
        let seed: [String: JSONValue] = [
            "__typename": .string("SpeechClip"),
            "id": .string("c1"),
            "muted": .bool(false),
            "volume": .double(1.0),
        ]
        client.graph.putRecord("TimelineClip:c1", seed)

        let tx = client.modifyOptimistic { b in
            b.patch(fragment: SpeechClipMutables.self, id: "c1") {
                $0.set(\.muted, true)
                $0.set(\.volume, 0.5)
            }
        }
        _ = tx

        // Patch must have landed on the canonical interface key, not on a
        // separate `SpeechClip:c1` record.
        let canonical = client.graph.getRecord("TimelineClip:c1")
        XCTAssertEqual(canonical?["muted"]?.bool, true)
        XCTAssertEqual(canonical?["volume"]?.double, 0.5)
        XCTAssertNil(
            client.graph.getRecord("SpeechClip:c1"),
            "variant fragment must NOT create a parallel record at the concrete typename key")
    }

    func test_typedDelete_removesEntity() throws {
        let (client, _, _) = makeClient()
        try client.writeFragment(fragment: TestPostFields.self, id: "p1", data: .init(id: "p1", title: "v1"))
        XCTAssertNotNil(client.readFragment(fragment: TestPostFields.self, id: "p1"))

        let tx = client.modifyOptimistic { b in
            b.delete(fragment: TestPostFields.self, id: "p1")
        }
        tx.dispose()
        XCTAssertNil(client.readFragment(fragment: TestPostFields.self, id: "p1"))
    }

    // MARK: - Typed connection linkNode / unlinkNode

    func test_typedConnectionAddNode_typedNode_insertsAtHead() throws {
        let (client, _, _) = makeClient()

        // Two typed node payloads — same shape a mutation response carries.
        // `linkNode(node:)` extracts `__typename` + `id` from the typed
        // value; it is purely structural and writes no entity scalars.
        let p2 = TestPostFields.Data(id: "p2", title: "second")
        let p1 = TestPostFields.Data(id: "p1", title: "first")

        let tx = client.modifyOptimistic { b in
            let c = b.connection(ConnectionSelector(key: "posts"))
            c.linkNode(node: p2, options: LinkNodeOptions(position: .end))
            c.linkNode(node: p1, options: LinkNodeOptions(position: .start))
        }
        tx.dispose()

        // Read the canonical's ordered edge list directly — linkNode keys
        // the edge node refs (the entity cache keys) without writing scalars.
        let canonicalKey: CacheKey = "@connection.posts({})"
        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        let nodeRefs: [String] = edges.compactMap { client.graph.getField($0, "node")?.ref }
        XCTAssertEqual(nodeRefs, ["Post:p1", "Post:p2"])
    }

    func test_typedConnectionAddNode_fragmentClosure_buildsOptimisticNode() throws {
        let (client, _, _) = makeClient()

        // Optimistic write of the entity scalars via `b.writeFragment`,
        // then a structural `linkNode(fragment:id:)` keys the new edge at
        // the just-seeded entity. linkNode itself is purely structural —
        // the entity scalars come from the writeFragment.
        let tx = client.modifyOptimistic { b in
            b.writeFragment(fragment: TestPostFields.self, id: "tmp:1", data: .init(id: "tmp:1", title: "Drafting…"))
            b.connection(ConnectionSelector(key: "posts"))
                .linkNode(fragment: TestPostFields.self, id: "tmp:1", options: LinkNodeOptions(position: .start))
        }
        _ = tx

        let canonicalKey: CacheKey = "@connection.posts({})"
        let edgeRefs = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edgeRefs.count, 1, "optimistic linkNode should have produced one edge")
        let nodeRef = edgeRefs.first.flatMap { client.graph.getField($0, "node")?.ref }
        XCTAssertEqual(nodeRef, "Post:tmp:1")
        XCTAssertEqual(client.graph.getField(nodeRef ?? "", "title")?.string, "Drafting…")
        XCTAssertEqual(client.graph.getField(nodeRef ?? "", "__typename")?.string, "Post")
    }

    func test_typedConnectionRemoveNode_byBareId() throws {
        let (client, _, _) = makeClient()

        // Seed two structural nodes, then drop one by typed bare id.
        let tx = client.modifyOptimistic { b in
            let c = b.connection(ConnectionSelector(key: "posts"))
            c.linkNode(.object(["__typename": "Post", "id": "p1"]), options: LinkNodeOptions(position: .end))
            c.linkNode(.object(["__typename": "Post", "id": "p2"]), options: LinkNodeOptions(position: .end))
            c.unlinkNode(fragment: TestPostFields.self, id: "p1")
        }
        tx.dispose()

        let canonicalKey: CacheKey = "@connection.posts({})"
        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        let nodeRefs: [String] = edges.compactMap { client.graph.getField($0, "node")?.ref }
        XCTAssertEqual(nodeRefs, ["Post:p2"])
    }

    func test_typedAddNode_revert_restoresBaseline() throws {
        let (client, _, _) = makeClient()

        // Baseline: one committed node already in the canonical.
        let baseline = client.modifyOptimistic { b in
            b.connection(ConnectionSelector(key: "posts"))
                .linkNode(.object(["__typename": "Post", "id": "p2"]), options: LinkNodeOptions(position: .end))
        }
        baseline.dispose()

        let canonicalKey: CacheKey = "@connection.posts({})"
        XCTAssertEqual(client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList?.count, 1)

        // Optimistic add via writeFragment + typed linkNode — the entity is
        // seeded into the optimistic layer, then linked into the connection.
        let tx = client.modifyOptimistic { b in
            b.writeFragment(fragment: TestPostFields.self, id: "tmp:rollback", data: .init(id: "tmp:rollback", title: "won't survive"))
            b.connection(ConnectionSelector(key: "posts"))
                .linkNode(fragment: TestPostFields.self, id: "tmp:rollback", options: LinkNodeOptions(position: .start))
        }
        XCTAssertEqual(client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList?.count, 2)

        // Revert restores the canonical to the baseline (just `p2`).
        tx.revert()
        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        let nodeRefs: [String] = edges.compactMap { client.graph.getField($0, "node")?.ref }
        XCTAssertEqual(nodeRefs, ["Post:p2"], "revert must restore the pre-layer edge list exactly")
    }

    // MARK: - execute query / mutation (async, typed)

    func test_typedExecuteQuery_decodesNetworkResponse() async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains(
            "TestPost",
            respondWith: .object([
                "post": .object([
                    "__typename": .string("Post"),
                    "id": .string("p1"),
                    "title": .string("from network"),
                ])
            ]))
        let (client, _, _) = makeClient(http: http)

        let result = try await client.execute(TestPost.self, variables: .init(id: "p1"))
        XCTAssertEqual(result.data?.post?.title, "from network")
        XCTAssertEqual(result.meta?.source, .network)
    }

    func test_typedExecuteMutation_decodesNetworkResponse() async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains(
            "TestUpdatePost",
            respondWith: .object([
                "updatePost": .object([
                    "__typename": .string("Post"),
                    "id": .string("p1"),
                    "title": .string("renamed"),
                ])
            ]))
        let (client, _, _) = makeClient(http: http)

        let result = try await client.execute(mutation: TestUpdatePost.self, variables: .init(id: "p1", title: "renamed"))
        XCTAssertEqual(result.data?.updatePost?.title, "renamed")
        XCTAssertEqual(result.data?.updatePost?.id, "p1")
    }

    // MARK: - Fragment typed API

    func test_typedWriteFragment_then_readFragment_byBareId() throws {
        let (client, _, _) = makeClient()
        // Bare id — typed API constructs the cache key as "Post:p1" via
        // `F.onTypename`. No `Post:` prefix at the call site.
        try client.writeFragment(fragment: TestPostFields.self, id: "p1", data: .init(id: "p1", title: "via fragment"))
        let read = client.readFragment(fragment: TestPostFields.self, id: "p1")
        XCTAssertEqual(read?.id, "p1")
        XCTAssertEqual(read?.title, "via fragment")
    }

    func test_typedReadFragment_returnsNil_onCacheMiss() {
        let (client, _, _) = makeClient()
        XCTAssertNil(client.readFragment(fragment: TestPostFields.self, id: "missing"))
    }

    func test_typedFragment_acceptsIntId() throws {
        let (client, _, _) = makeClient()
        try client.writeFragment(fragment: TestPostFields.self, id: 99, data: .init(id: "99", title: "int-keyed"))
        XCTAssertEqual(client.readFragment(fragment: TestPostFields.self, id: 99)?.title, "int-keyed")
    }

    func test_typedWatchFragment_emitsInitial_andUpdates() throws {
        let (client, _, _) = makeClient()
        try client.writeFragment(fragment: TestPostFields.self, id: "p1", data: .init(id: "p1", title: "initial"))

        let received = ReceivedTitles()
        let exp = expectation(description: "fragment update fires")
        exp.expectedFulfillmentCount = 2
        let handle = try client.watchFragment(
            fragment: TestPostFields.self,
            id: "p1",
            immediate: true,
            onData: { data in
                received.append(data.title)
                exp.fulfill()
            }
        )

        // Mutate via fragment write — should re-fire the watcher.
        try client.writeFragment(fragment: TestPostFields.self, id: "p1", data: .init(id: "p1", title: "updated"))

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received.snapshot(), ["initial", "updated"])
        handle.unsubscribe()
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
