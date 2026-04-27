import XCTest
@testable import Cachebay

/// Plan-aware `addNode(fragment:)` — port of cachebay-web
/// `optimistic.test.ts` "Fragment Operations" section (lines
/// 844–1554). Locks the contract that providing a fragment plan to
/// `addNode` causes the runtime to:
///   1. initialize empty `@connection` canonicals for every connection
///      field in the fragment plan (idempotent — existing canonicals
///      are preserved),
///   2. populate inline edges + `pageInfo` when the node data carries
///      them,
///   3. strip selection-set fields from the entity-record patch so
///      existing ref/refList links survive a merge.
///
/// Without this capability, calling `addNode(node: typedEntity)` with
/// a typed mutation result whose `__data` carries connection-shaped
/// fields (e.g. `clips: []`, `elements: []`) overwrites the
/// server-cycle ref/refList links with raw arrays. The watcher then
/// hard-misses on those fields and silences the optimistic cycle —
/// the exact failure mode that surfaced in the create-project smoke.
final class OptimisticAddNodeFragmentTests: XCTestCase {

    // MARK: - Fragment fixtures

    /// Simple Post fragment with no nested @connection — used for
    /// "fragment without nested connections" tests.
    private static let postFragmentDoc: QueryDocument = .source("""
    fragment PostFields on Post {
      id
      title
      flags
    }
    """)

    /// Post fragment with a nested `comments(...) @connection(key: "PostComments")`.
    /// Mirrors web's `POST_COMMENTS_FRAGMENT` (`test/helpers/operations.ts:126`).
    private static let postCommentsFragmentDoc: QueryDocument = .source("""
    fragment PostComments on Post {
      id
      comments(first: $commentsFirst, after: $commentsAfter) @connection(key: "PostComments") {
        pageInfo { startCursor endCursor hasNextPage hasPreviousPage }
        edges {
          cursor
          node {
            id
            text
          }
        }
      }
    }
    """)

    /// User fragment with TWO nested @connection fields — locks
    /// behavior for the multi-connection case (Project has clips +
    /// elements, ferment-cuts smoke).
    private static let userMultiConnDoc: QueryDocument = .source("""
    fragment UserMulti on User {
      id
      posts @connection(key: "UserPosts") {
        pageInfo { startCursor endCursor hasNextPage hasPreviousPage }
        edges { cursor node { id title } }
      }
      comments @connection(key: "UserComments") {
        pageInfo { startCursor endCursor hasNextPage hasPreviousPage }
        edges { cursor node { id text } }
      }
    }
    """)

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    // MARK: - Tests

    /// Web `optimistic.test.ts:846` — "adds node using fragment without
    /// nested connections". Plain Post fragment: addNode writes the
    /// entity scalars and adds it to the connection. No nested
    /// connections to init.
    func test_addNode_fragmentWithoutNestedConnections_writesEntityAndEdge() {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        let tx = client.modifyOptimistic { b, _ in
            let c = b.connection(ConnectionSelector(key: "posts"))
            c.addNode(
                ["id": .string("p1"), "title": .string("Post 1"), "flags": .array([.string("draft")])],
                options: AddNodeOptions(
                    position: .end,
                    fragmentDocument: Self.postFragmentDoc,
                    fragmentName: "PostFields"
                )
            )
        }
        tx.commit(nil)

        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edges.count, 1)
        let post = client.graph.getRecord("Post:p1") ?? [:]
        XCTAssertEqual(post[CachebayConstants.typenameField]?.string, "Post")
        XCTAssertEqual(post["id"]?.string, "p1")
        XCTAssertEqual(post["title"]?.string, "Post 1")
        if case .array(let flags) = post["flags"] ?? .undefined {
            XCTAssertEqual(flags.count, 1)
            XCTAssertEqual(flags.first?.string, "draft")
        } else {
            XCTFail("flags missing or wrong shape: \(String(describing: post["flags"]))")
        }
    }

    /// Web `optimistic.test.ts:873` — "auto-initializes nested
    /// connections from fragment". The smoke-bug test: addNode with a
    /// fragment that has a nested `@connection` field MUST create an
    /// empty canonical record for it (with empty edges, default
    /// pageInfo, refList shape) so a watcher reading that connection
    /// can materialize without hitting a "missing field" hard miss.
    func test_addNode_autoInitializesNestedConnectionsFromFragment() throws {
        let client = makeClient()
        let postsKey: CacheKey = "@connection.posts({})"

        let tx = client.modifyOptimistic { b, _ in
            let c = b.connection(ConnectionSelector(key: "posts"))
            c.addNode(
                ["id": .string("p1"), "title": .string("Post with Comments")],
                options: AddNodeOptions(
                    position: .end,
                    fragmentDocument: Self.postCommentsFragmentDoc,
                    fragmentName: "PostComments"
                )
            )
        }
        tx.commit(nil)

        // Top-level posts connection has the new edge.
        let edges = client.graph.getField(postsKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Post with Comments")

        // Nested comments connection canonical was auto-initialized.
        // Web key shape: `@connection.Post:p1.PostComments({})`. iOS
        // builds via `Keys.buildConnectionCanonicalKey`; for a
        // connection with `@connection(key: "PostComments")` and no
        // filters the canonical args bucket is `{}`.
        let commentsKey: CacheKey = "@connection.Post:p1.PostComments({})"
        let connRecord = try XCTUnwrap(client.graph.getRecord(commentsKey),
                                       "expected canonical record at \(commentsKey); got keys: \(client.graph.keysList().filter { $0.contains("PostComments") })")
        XCTAssertEqual(connRecord[CachebayConstants.typenameField]?.string, CachebayConstants.connectionTypename)
        let initialEdges: [CacheKey] = connRecord[CachebayConstants.connectionEdgesField]?.refList ?? []
        XCTAssertEqual(initialEdges, [],
                       "auto-initialized nested connection must have empty edges refList")

        // pageInfo record was created with default empty values.
        let pageInfoKey = "\(commentsKey).pageInfo"
        let pageInfo = try XCTUnwrap(client.graph.getRecord(pageInfoKey))
        XCTAssertEqual(pageInfo[CachebayConstants.typenameField]?.string, CachebayConstants.connectionPageInfoTypename)
        XCTAssertEqual(pageInfo["hasNextPage"]?.bool, false)
        XCTAssertEqual(pageInfo["hasPreviousPage"]?.bool, false)
    }

    /// Web `optimistic.test.ts:911` — "uses fragment typename when not
    /// provided in node data". Stamping `__typename` from the
    /// fragment's `on Post` clause when the node dict omits it.
    func test_addNode_usesFragmentTypenameWhenNotProvided() {
        let client = makeClient()
        _ = client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(key: "posts"))
             .addNode(
                ["id": .string("p1"), "title": .string("Auto Typename")],
                options: AddNodeOptions(
                    position: .end,
                    fragmentDocument: Self.postFragmentDoc,
                    fragmentName: "PostFields"
                )
             )
        }.commit(nil)

        XCTAssertEqual(client.graph.getRecord("Post:p1")?[CachebayConstants.typenameField]?.string, "Post")
    }

    /// Web `optimistic.test.ts:931` — "respects provided typename over
    /// fragment typename". Caller's explicit `__typename` (e.g. a
    /// concrete impl of an interface) wins over the fragment's
    /// `onTypename`.
    func test_addNode_respectsExplicitTypenameOverFragment() {
        let client = makeClient()
        _ = client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(key: "posts"))
             .addNode(
                [
                    CachebayConstants.typenameField: .string("VideoPost"),
                    "id": .string("p1"),
                    "title": .string("Video Post"),
                ],
                options: AddNodeOptions(
                    position: .end,
                    fragmentDocument: Self.postFragmentDoc,
                    fragmentName: "PostFields"
                )
             )
        }.commit(nil)

        XCTAssertEqual(client.graph.getRecord("VideoPost:p1")?[CachebayConstants.typenameField]?.string, "VideoPost")
    }

    /// Web `optimistic.test.ts:976` — "works without fragment
    /// (backward compatibility)". The raw addNode path (no fragment in
    /// options) still works: writes the typed dict directly. Locks
    /// the no-regression invariant for callers that aren't on the
    /// fragment path yet.
    func test_addNode_withoutFragment_backwardCompatible() {
        let client = makeClient()
        let canonicalKey: CacheKey = "@connection.posts({})"

        _ = client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(key: "posts"))
             .addNode(
                [
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p1"),
                    "title": .string("No Fragment"),
                ],
                options: AddNodeOptions(position: .end)
             )
        }.commit(nil)

        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "No Fragment")
    }

    /// Web `optimistic.test.ts:994` — "initializes nested connection
    /// with inline edges data". When the node dict carries inline
    /// `comments: { edges: [...], pageInfo: {...} }`, the runtime
    /// uses those values to populate the nested canonical instead of
    /// initializing it empty.
    func test_addNode_nestedConnectionFromInlineEdges() throws {
        let client = makeClient()

        _ = client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(key: "posts"))
             .addNode(
                [
                    "id": .string("p1"),
                    "title": .string("Post with Inline Comments"),
                    "comments": .object([
                        "pageInfo": .object([
                            "startCursor": .string("c1"),
                            "endCursor": .string("c2"),
                            "hasNextPage": .bool(true),
                            "hasPreviousPage": .bool(false),
                        ]),
                        "edges": .array([
                            .object([
                                "cursor": .string("c1"),
                                "node": .object([
                                    CachebayConstants.typenameField: .string("Comment"),
                                    "id": .string("cm1"),
                                    "text": .string("First comment"),
                                ]),
                            ]),
                            .object([
                                "cursor": .string("c2"),
                                "node": .object([
                                    CachebayConstants.typenameField: .string("Comment"),
                                    "id": .string("cm2"),
                                    "text": .string("Second comment"),
                                ]),
                            ]),
                        ]),
                    ]),
                ],
                options: AddNodeOptions(
                    position: .end,
                    fragmentDocument: Self.postCommentsFragmentDoc,
                    fragmentName: "PostComments"
                )
             )
        }.commit(nil)

        let commentsKey: CacheKey = "@connection.Post:p1.PostComments({})"
        let connRecord = try XCTUnwrap(client.graph.getRecord(commentsKey),
                                       "expected canonical record at \(commentsKey)")
        let edgeRefs: [CacheKey] = connRecord[CachebayConstants.connectionEdgesField]?.refList ?? []
        XCTAssertEqual(edgeRefs.count, 2)
        XCTAssertEqual(client.graph.getRecord("Comment:cm1")?["text"]?.string, "First comment")
        XCTAssertEqual(client.graph.getRecord("Comment:cm2")?["text"]?.string, "Second comment")

        let pageInfo = try XCTUnwrap(client.graph.getRecord("\(commentsKey).pageInfo"))
        XCTAssertEqual(pageInfo["startCursor"]?.string, "c1")
        XCTAssertEqual(pageInfo["endCursor"]?.string, "c2")
        XCTAssertEqual(pageInfo["hasNextPage"]?.bool, true)
        XCTAssertEqual(pageInfo["hasPreviousPage"]?.bool, false)
    }

    /// Web `optimistic.test.ts:1171` — "handles multiple nested
    /// connections in same fragment". The fragment plan walks every
    /// `@connection` field, not just the first. iOS app analogue:
    /// Project has `clips` + `elements`, both are connection-shaped
    /// in the schema; both must be initialised so neither hard-misses
    /// during materialize.
    func test_addNode_multipleNestedConnectionsInSameFragment() {
        let client = makeClient()

        _ = client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(key: "users"))
             .addNode(
                ["id": .string("u1"), "name": .string("Alice")],
                options: AddNodeOptions(
                    position: .end,
                    fragmentDocument: Self.userMultiConnDoc,
                    fragmentName: "UserMulti"
                )
             )
        }.commit(nil)

        // Both nested connections were initialised on User:u1.
        let postsCanonical: CacheKey = "@connection.User:u1.UserPosts({})"
        let commentsCanonical: CacheKey = "@connection.User:u1.UserComments({})"
        XCTAssertNotNil(client.graph.getRecord(postsCanonical),
                        "UserPosts canonical missing — multi-connection plan walk dropped it; keys: \(client.graph.keysList().filter { $0.contains("@connection.User") })")
        XCTAssertNotNil(client.graph.getRecord(commentsCanonical),
                        "UserComments canonical missing — multi-connection plan walk dropped it")
    }

    // MARK: - Revert / layering / two-cycle commit

    /// Web `optimistic.test.ts:1062` — "reverts nested connection
    /// initialization on revert". Revert must clean up not just the
    /// entity record + edge, but also the auto-initialized nested
    /// connection canonical and its pageInfo record.
    func test_addNode_revertCleansUpNestedConnectionAndPageInfo() {
        let client = makeClient()
        let postsKey: CacheKey = "@connection.posts({})"
        let commentsKey: CacheKey = "@connection.Post:p1.PostComments({})"

        let tx = client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(key: "posts"))
             .addNode(
                ["id": .string("p1"), "title": .string("Post 1")],
                options: AddNodeOptions(
                    position: .end,
                    fragmentDocument: Self.postCommentsFragmentDoc,
                    fragmentName: "PostComments"
                )
             )
        }
        // Confirm nested connection exists during optimistic phase.
        XCTAssertNotNil(client.graph.getRecord(commentsKey),
                        "nested connection should exist during optimistic")

        tx.revert()

        // Main edge gone, entity gone.
        let edges = client.graph.getField(postsKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edges.count, 0)
        XCTAssertNil(client.graph.getRecord("Post:p1"))

        // Nested connection + pageInfo cleaned up.
        XCTAssertNil(client.graph.getRecord(commentsKey),
                     "nested connection canonical must be removed on revert")
        XCTAssertNil(client.graph.getRecord("\(commentsKey).pageInfo"),
                     "nested connection pageInfo record must be removed on revert")
    }

    /// Web `optimistic.test.ts:1092` — "preserves nested connections
    /// across layers". Two layered transactions; reverting the first
    /// must NOT touch the second's auto-initialized nested
    /// connection.
    func test_addNode_revertOneLayer_preservesOtherLayersNestedConnections() {
        let client = makeClient()

        let tx1 = client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(key: "posts"))
             .addNode(
                ["id": .string("p1"), "title": .string("Layer 1")],
                options: AddNodeOptions(
                    position: .end,
                    fragmentDocument: Self.postCommentsFragmentDoc,
                    fragmentName: "PostComments"
                )
             )
        }
        let tx2 = client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(key: "posts"))
             .addNode(
                ["id": .string("p2"), "title": .string("Layer 2")],
                options: AddNodeOptions(
                    position: .end,
                    fragmentDocument: Self.postCommentsFragmentDoc,
                    fragmentName: "PostComments"
                )
             )
        }

        XCTAssertNotNil(client.graph.getRecord("@connection.Post:p1.PostComments({})"))
        XCTAssertNotNil(client.graph.getRecord("@connection.Post:p2.PostComments({})"))

        tx1.revert()

        XCTAssertNil(client.graph.getRecord("Post:p1"))
        XCTAssertNil(client.graph.getRecord("@connection.Post:p1.PostComments({})"))
        XCTAssertNotNil(client.graph.getRecord("Post:p2"),
                        "layer-2 entity must survive layer-1 revert")
        XCTAssertNotNil(client.graph.getRecord("@connection.Post:p2.PostComments({})"),
                        "layer-2 nested connection must survive layer-1 revert")

        tx2.commit(nil)
        XCTAssertNotNil(client.graph.getRecord("Post:p2"))
        XCTAssertNotNil(client.graph.getRecord("@connection.Post:p2.PostComments({})"))
    }

    /// Web `optimistic.test.ts:1228` — "ignores fragment if node
    /// cannot be identified". When the dict lacks both `id` and a
    /// custom keyer, addNode short-circuits to a no-op (no record,
    /// no edge, no nested-connection init).
    func test_addNode_ignoresFragment_whenNodeCannotBeIdentified() {
        let client = makeClient()
        let postsKey: CacheKey = "@connection.posts({})"

        _ = client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(key: "posts"))
             .addNode(
                // No `id` — graph.identify returns nil → addNode no-op.
                ["title": .string("No ID")],
                options: AddNodeOptions(
                    position: .end,
                    fragmentDocument: Self.postFragmentDoc,
                    fragmentName: "PostFields"
                )
             )
        }.commit(nil)

        let edges = client.graph.getField(postsKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edges.count, 0)
    }

    /// Web `optimistic.test.ts:1248` — "combines fragment with edge
    /// metadata". The `edge` field of `AddNodeOptions` carries
    /// per-edge meta that lands on the synthesized edge record. Must
    /// work alongside the fragment-driven plan walk.
    func test_addNode_combinesFragmentWithEdgeMetadata() throws {
        let client = makeClient()
        let postsKey: CacheKey = "@connection.posts({})"

        _ = client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(key: "posts"))
             .addNode(
                ["id": .string("p1"), "title": .string("Post 1")],
                options: AddNodeOptions(
                    position: .end,
                    edge: ["cursor": .string("custom-cursor"), "score": .int(42)],
                    fragmentDocument: Self.postFragmentDoc,
                    fragmentName: "PostFields"
                )
             )
        }.commit(nil)

        let edges = client.graph.getField(postsKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edges.count, 1)
        let edgeKey = try XCTUnwrap(edges.first)
        let edgeRecord = try XCTUnwrap(client.graph.getRecord(edgeKey))
        XCTAssertEqual(edgeRecord["score"]?.int, 42)
        XCTAssertEqual(edgeRecord["cursor"]?.string, "custom-cursor")
    }

    /// Web `optimistic.test.ts:1271` — "supports anchored positioning
    /// with fragment". Anchored insert (`position: .after, anchor:`)
    /// must work alongside the fragment-driven plan walk so the new
    /// edge lands at the right index AND the nested connections get
    /// initialized.
    func test_addNode_supportsAnchoredPositioningWithFragment() {
        let client = makeClient()
        let postsKey: CacheKey = "@connection.posts({})"

        let tx1 = client.modifyOptimistic { b, _ in
            let c = b.connection(ConnectionSelector(key: "posts"))
            c.addNode(
                [
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p1"),
                    "title": .string("Post 1"),
                ],
                options: AddNodeOptions(position: .end)
            )
            c.addNode(
                [
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p3"),
                    "title": .string("Post 3"),
                ],
                options: AddNodeOptions(position: .end)
            )
        }
        tx1.commit(nil)

        let tx2 = client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(key: "posts"))
             .addNode(
                ["id": .string("p2"), "title": .string("Post 2")],
                options: AddNodeOptions(
                    position: .after,
                    anchor: .key("Post:p1"),
                    fragmentDocument: Self.postFragmentDoc,
                    fragmentName: "PostFields"
                )
             )
        }
        tx2.commit(nil)

        // Resolve edge order → entity ids.
        let edgeRefs = client.graph.getField(postsKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        let ids: [String] = edgeRefs.compactMap { ref in
            client.graph.getField(ref, "node")?.ref?.replacingOccurrences(of: "Post:", with: "")
        }
        XCTAssertEqual(ids, ["p1", "p2", "p3"], "anchored insert with fragment must land between p1 and p3")
    }

    /// Web `optimistic.test.ts:1303` — "is idempotent when called
    /// multiple times with same fragment". Calling addNode twice for
    /// the same entity must not duplicate the edge or recreate the
    /// nested-connection record (idempotency on connectionKey
    /// existence check).
    func test_addNode_idempotentForRepeatedFragmentAdds() {
        let client = makeClient()
        let postsKey: CacheKey = "@connection.posts({})"
        let commentsKey: CacheKey = "@connection.Post:p1.PostComments({})"

        _ = client.modifyOptimistic { b, _ in
            let c = b.connection(ConnectionSelector(key: "posts"))
            // First call initializes nested connection.
            c.addNode(
                ["id": .string("p1"), "title": .string("First")],
                options: AddNodeOptions(
                    position: .end,
                    fragmentDocument: Self.postCommentsFragmentDoc,
                    fragmentName: "PostComments"
                )
            )
            // Second call must dedup edge (by entityKey) and skip
            // re-init of the existing nested connection.
            c.addNode(
                ["id": .string("p1"), "title": .string("Second")],
                options: AddNodeOptions(
                    position: .end,
                    fragmentDocument: Self.postCommentsFragmentDoc,
                    fragmentName: "PostComments"
                )
            )
        }.commit(nil)

        let edges = client.graph.getField(postsKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edges.count, 1, "addNode dedup by entityKey must keep only one edge for Post:p1")
        XCTAssertNotNil(client.graph.getRecord(commentsKey),
                        "nested connection canonical should be intact after idempotent re-add")
    }

    // MARK: - Operation extras + smoke regression

    /// Operation-level extras (fields selected on the mutation
    /// OUTSIDE the spread fragment) must also be stripped from the
    /// entity patch when their value has entity shape. This is the
    /// remaining issue from the create-project smoke: `CreateProject`
    /// selects `...ProjectFields` plus `elements { ...ElementFields }`
    /// — `elements` isn't in the `ProjectFields` plan, so plan-aware
    /// strip alone misses it. Shape-aware strip catches it via the
    /// `__typename` heuristic on array elements.
    func test_addNode_stripsEntityShapedExtrasOutsideFragmentPlan() {
        let client = makeClient()

        // Pre-seed Project:p1 with a refList for `elements` as if the
        // server-cycle normalize had already written it.
        client.graph.putRecord("Project:p1", [
            CachebayConstants.typenameField: .string("Project"),
            "id": .string("p1"),
            "name": .string("Server name"),
            "elements": .refList(["VideoElement:v1"]),
        ])

        // Optimistic addNode with the typed mutation result's raw
        // __data carrying `elements: [.object({__typename: ..., ...})]`
        // — entity-shaped, but NOT a field of ProjectFields fragment.
        _ = client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(key: "projects"))
             .addNode(
                [
                    CachebayConstants.typenameField: .string("Project"),
                    "id": .string("p1"),
                    "name": .string("Optimistic name"),
                    // elements is NOT in postFragmentDoc / there's no
                    // matching plan field — must be stripped via
                    // shape-aware fallback because its values carry
                    // __typename.
                    "elements": .array([
                        .object([
                            CachebayConstants.typenameField: .string("VideoElement"),
                            "id": .string("v2"),
                            "name": .string("New video"),
                        ]),
                    ]),
                ],
                options: AddNodeOptions(
                    position: .end,
                    fragmentDocument: Self.postFragmentDoc, // doesn't have `elements`
                    fragmentName: "PostFields"
                )
             )
        }.commit(nil)

        // Scalar overwritten — that's the optimistic write working.
        XCTAssertEqual(client.graph.getField("Project:p1", "name")?.string, "Optimistic name")
        // `elements` field on Project:p1 must NOT have been overwritten
        // with `.array([.object(...)])`. Either the original refList
        // survives, or the field was stripped from the patch (so
        // existing refList stays intact).
        let elementsField = client.graph.getField("Project:p1", "elements")
        switch elementsField {
        case .some(.refList(let refs)):
            XCTAssertEqual(refs, ["VideoElement:v1"], "expected pre-seeded refList to survive")
        case .none:
            XCTFail("pre-seeded refList disappeared — strip went too far")
        case .some(let other):
            XCTFail("addNode overwrote 'elements' with non-refList shape: \(other) — shape-aware strip failed")
        }
    }

    /// Plan-aware addNode must NOT overwrite existing ref/refList
    /// links on the entity record. This is the exact regression that
    /// surfaced in the create-project smoke: server-cycle normalize
    /// wrote `Project:114` with `clips: .refList(...)`, then a
    /// subsequent optimistic addNode with the typed mutation result
    /// overwrote `clips` with `.array([])`, hard-missing the watcher.
    /// With plan-aware addNode, selection-set fields are stripped
    /// from the entity patch, so existing refs survive.
    func test_addNode_preservesExistingRefsOnEntityRecord() {
        let client = makeClient()

        // Pre-seed Post:p1 as if the server response had already
        // normalized it: scalar `title` plus an entity ref-link to a
        // related Author entity through the `comments` selection-set
        // field's container.
        client.graph.putRecord("Post:p1", [
            CachebayConstants.typenameField: .string("Post"),
            "id": .string("p1"),
            "title": .string("Server title"),
            // comments is a selection-set field in PostComments
            // fragment — pretend the server already wrote a refList.
            "comments(first:null,after:null)": .refList(["@connection.Post:p1.PostComments({})"]),
        ])

        // Now an optimistic addNode arrives with the typed entity's
        // raw __data carrying `comments: { edges: [], pageInfo: {} }`
        // — the EXACT shape that broke the smoke test.
        _ = client.modifyOptimistic { b, _ in
            b.connection(ConnectionSelector(key: "posts"))
             .addNode(
                [
                    "id": .string("p1"),
                    "title": .string("Optimistic title"),
                    "comments": .object([
                        "edges": .array([]),
                        "pageInfo": .object([:]),
                    ]),
                ],
                options: AddNodeOptions(
                    position: .end,
                    fragmentDocument: Self.postCommentsFragmentDoc,
                    fragmentName: "PostComments"
                )
             )
        }.commit(nil)

        // Scalar overwritten — that's the optimistic write working.
        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Optimistic title")
        // BUT `comments` field on Post:p1 is a selection-set field,
        // so it must NOT have been overwritten with `.array(...)` /
        // `.object(...)` by the addNode patch. Either intact as a
        // refList, or absent (the strip-selection-fields path).
        let commentsField = client.graph.getField("Post:p1", "comments(first:null,after:null)")
        switch commentsField {
        case .some(.refList):
            // Original server-cycle ref preserved.
            break
        case .none:
            // Stripped from the patch; merge didn't touch the field.
            // The pre-seeded refList should still be there because we
            // didn't pass `comments` as part of the patch.
            XCTFail("expected the pre-seeded refList to survive — found neither array overwrite nor original refList")
        case .some(let other):
            XCTFail("addNode overwrote selection-set field 'comments' with non-refList shape: \(other) — this is the smoke-bug regression")
        }
    }
}
