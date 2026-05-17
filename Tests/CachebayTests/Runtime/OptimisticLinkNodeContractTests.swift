import XCTest
@testable import Cachebay

/// Contract tests for the connection-link primitive: it inserts an
/// edge into the connection. **It does NOT write entity-record fields.**
/// Entity records are owned exclusively by `documents.normalize` (auto
/// from queries / mutations / subscriptions, or explicit via
/// `writeFragment`). The link primitive only touches:
///
///   • the canonical connection record (`edges` refList, `pageInfo` ref)
///   • the synthesised edge record (`__typename`, `node` ref, meta)
///   • aux records (`::nodeIndex`, `::cursorIndex`)
///   • nested `@connection` canonicals reachable through the fragment
///     plan (idempotently — never destroys existing pagination state)
///
/// What this kills: the chat-pipeline race where a deferred `Created`
/// handler holding a stale message payload would call the link primitive
/// AFTER the subscription's `Updated` auto-normalize had already landed,
/// and the link primitive's entity write would silently revert
/// `status: complete, toolCalls: [...]` back to `status: streaming,
/// toolCalls: null`. With the link primitive purely structural, the
/// stale-replay path has nothing to clobber with.
final class OptimisticLinkNodeContractTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    private static let projectMessageFragmentDoc: QueryDocument = .source("""
    fragment ProjectMessageFields on ProjectMessage {
      id
      status
      toolCalls
    }
    """)

    // MARK: - Repro of the chat-race bug

    /// The exact production sequence:
    ///   1. `Created` event lands → `documents.normalize` writes
    ///      `{status: "streaming", toolCalls: null}` for the message.
    ///   2. `Updated` event lands ~6ms later → `documents.normalize`
    ///      shallow-merges `{status: "complete", toolCalls: [...]}`.
    ///   3. The user's deferred `Created`-handler runs, calling
    ///      `connection(...).linkNode(stale_msg, fragment:)` with the
    ///      ORIGINAL Created payload.
    ///
    /// The link primitive must NOT undo step (2). After step (3) the
    /// entity must still hold `status: complete, toolCalls: [...]`.
    /// Pre-fix this test fails because linkNode's plan-aware path calls
    /// `graph.putRecord(entityKey, entityPatch)` and shallow-merges the
    /// stale Created scalars over the Updated state.
    func test_linkNode_planAware_doesNotClobberEntityScalarsWithStaleData() throws {
        let client = makeClient()
        let key: CacheKey = "@connection.projectMessages({})"

        // Step 1+2: simulate the subscription pipeline's
        // `documents.normalize` calls collapsed to their final state —
        // entity holds the Updated payload.
        client.graph.replaceRecord("ProjectMessage:m1", [
            CachebayConstants.typenameField: .string("ProjectMessage"),
            "id": .string("m1"),
            "status": .string("complete"),
            "toolCalls": .array([.string("ask_user_to_pick")]),
        ])

        // Step 3: deferred user handler calls the link primitive with
        // the STALE Created payload (status=streaming, toolCalls=null).
        let staleCreatedNode: [String: JSONValue] = [
            CachebayConstants.typenameField: .string("ProjectMessage"),
            "id": .string("m1"),
            "status": .string("streaming"),
            "toolCalls": .null,
        ]

        client.modifyOptimistic { b in
            b.connection(ConnectionSelector(key: "projectMessages"))
                .linkNode(.object(staleCreatedNode), options: LinkNodeOptions(position: .start))
        }.dispose()

        // The connection now has the edge linking ProjectMessage:m1.
        let edges = client.graph.getField(key, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edges.count, 1, "edge must be inserted")

        // The entity record MUST still reflect the Updated state — no
        // clobber by stale Created data routed through the link primitive.
        let entity = try XCTUnwrap(client.graph.getRecord("ProjectMessage:m1"))
        XCTAssertEqual(entity["status"]?.string, "complete",
            "link primitive must not overwrite `status` with stale data; got \(String(describing: entity["status"]))")
        if case .array(let tc) = entity["toolCalls"] ?? .null {
            XCTAssertEqual(tc.first?.string, "ask_user_to_pick",
                "link primitive must not overwrite `toolCalls` with stale data")
        } else {
            XCTFail("link primitive nulled out `toolCalls` (expected the populated array): \(String(describing: entity["toolCalls"]))")
        }
    }

    /// Same race, raw-dict (no fragment) entry point. The raw path
    /// must obey the same contract — no entity scalar writes.
    func test_linkNode_raw_doesNotClobberEntityScalarsWithStaleData() throws {
        let client = makeClient()

        client.graph.replaceRecord("ProjectMessage:m1", [
            CachebayConstants.typenameField: .string("ProjectMessage"),
            "id": .string("m1"),
            "status": .string("complete"),
            "toolCalls": .array([.string("ask_user_to_pick")]),
        ])

        let staleCreatedNode: [String: JSONValue] = [
            CachebayConstants.typenameField: .string("ProjectMessage"),
            "id": .string("m1"),
            "status": .string("streaming"),
            "toolCalls": .null,
        ]

        client.modifyOptimistic { b in
            b.connection(ConnectionSelector(key: "projectMessages"))
                .linkNode(.object(staleCreatedNode), options: LinkNodeOptions(position: .start))
        }.dispose()

        let entity = try XCTUnwrap(client.graph.getRecord("ProjectMessage:m1"))
        XCTAssertEqual(entity["status"]?.string, "complete",
            "raw link primitive must not write entity scalars")
        if case .array = entity["toolCalls"] ?? .null { /* ok */ } else {
            XCTFail("raw link primitive overwrote `toolCalls` with null: \(String(describing: entity["toolCalls"]))")
        }
    }

    // MARK: - Empty-cache contract

    /// Linking a node into a connection when no entity record exists
    /// in the graph yet must NOT synthesise scalar fields onto the
    /// (newly-created) entity record. The edge ref is allowed to dangle
    /// — the caller is responsible for ensuring the entity exists via
    /// `writeFragment` / a server-cycle normalize. `__typename` + `id`
    /// stub-record creation is fine (it's identity, not data); scalar
    /// fields like `title` / `status` must NOT appear.
    func test_linkNode_intoEmptyCache_doesNotMaterialiseScalarFields() throws {
        let client = makeClient()
        let key: CacheKey = "@connection.posts({})"

        client.modifyOptimistic { b in
            b.connection(ConnectionSelector(key: "posts"))
                .linkNode(
                    .object([
                        CachebayConstants.typenameField: .string("Post"),
                        "id": .string("p1"),
                        "title": .string("Should NOT be written"),
                        "body": .string("Should NOT be written either"),
                    ]),
                    options: LinkNodeOptions(position: .start)
                )
        }.dispose()

        // Edge inserted.
        let edges = client.graph.getField(key, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edges.count, 1)

        // Entity record either absent OR contains only identity fields.
        if let post = client.graph.getRecord("Post:p1") {
            XCTAssertNil(post["title"],
                "link primitive must not write scalar `title`; got \(String(describing: post["title"]))")
            XCTAssertNil(post["body"],
                "link primitive must not write scalar `body`; got \(String(describing: post["body"]))")
        }
    }

    // MARK: - Idempotent re-link is still no-op on entity

    /// Calling the link primitive twice for the same entity into the
    /// same connection is idempotent (dedup at the edge level). The
    /// second call must not write entity scalars even if the second
    /// call carries a different scalar payload.
    func test_linkNode_repeatedInsert_neverWritesEntityScalars() throws {
        let client = makeClient()

        // Pre-seed the canonical entity from a normalize-shaped write.
        client.graph.replaceRecord("Post:p1", [
            CachebayConstants.typenameField: .string("Post"),
            "id": .string("p1"),
            "title": .string("Authoritative"),
        ])

        client.modifyOptimistic { b in
            b.connection(ConnectionSelector(key: "posts"))
                .linkNode(.object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p1"),
                    "title": .string("First-call attempt"),
                ]), options: LinkNodeOptions(position: .start))
        }.dispose()

        client.modifyOptimistic { b in
            b.connection(ConnectionSelector(key: "posts"))
                .linkNode(.object([
                    CachebayConstants.typenameField: .string("Post"),
                    "id": .string("p1"),
                    "title": .string("Second-call attempt"),
                ]), options: LinkNodeOptions(position: .start))
        }.dispose()

        let post = try XCTUnwrap(client.graph.getRecord("Post:p1"))
        XCTAssertEqual(post["title"]?.string, "Authoritative",
            "neither the first nor the second link call may overwrite the normalize-written title")
    }
}
