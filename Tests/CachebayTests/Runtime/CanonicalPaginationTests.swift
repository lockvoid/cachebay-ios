import XCTest
@testable import Cachebay

/// Web parity for `core/canonical.test.ts` Forward/Backward/Splice/Filter
/// blocks. Existing iOS suite covered prepend + after-splice-truncate + a
/// shallow extras merge — these tests fill the rest.
final class CanonicalPaginationTests: XCTestCase {

    private func makeStack() -> (Graph, Planner, Canonical, Documents) {
        let graph = Graph()
        let planner = Planner()
        let canonical = Canonical(graph: graph)
        let documents = Documents(graph: graph, planner: planner, canonical: canonical)
        return (graph, planner, canonical, documents)
    }

    private let postsQuery = """
    query Posts($first: Int, $last: Int, $after: String, $before: String) {
        posts(first: $first, last: $last, after: $after, before: $before) @connection(mode: "infinite") {
            __typename
            totalCount
            pageInfo { __typename startCursor endCursor hasPreviousPage hasNextPage }
            edges { __typename cursor node { __typename id title } }
        }
    }
    """

    private let usersQuery = """
    query Users($role: String, $first: Int, $after: String) {
        users(role: $role, first: $first, after: $after) @connection(mode: "infinite", filters: ["role"]) {
            __typename
            pageInfo { __typename startCursor endCursor hasPreviousPage hasNextPage }
            edges { __typename cursor node { __typename id name } }
        }
    }
    """

    private func buildPosts(
        ids: [String],
        startCursor: String? = nil,
        endCursor: String? = nil,
        hasPrev: Bool = false,
        hasNext: Bool = false,
        totalCount: Int? = nil
    ) -> JSONValue {
        let edges: [JSONValue] = ids.map { id in
            .object([
                "__typename": "PostEdge",
                "cursor": .string(id),
                "node": .object(["__typename": "Post", "id": .string(id), "title": .string(id)])
            ])
        }
        var conn: [String: JSONValue] = [
            "__typename": "PostConnection",
            "pageInfo": .object([
                "__typename": "PageInfo",
                "startCursor": startCursor.map(JSONValue.string) ?? (ids.first.map(JSONValue.string) ?? .null),
                "endCursor": endCursor.map(JSONValue.string) ?? (ids.last.map(JSONValue.string) ?? .null),
                "hasPreviousPage": .bool(hasPrev),
                "hasNextPage": .bool(hasNext),
            ]),
            "edges": .array(edges),
        ]
        if let totalCount {
            conn["totalCount"] = .int(Int64(totalCount))
        }
        return .object(["posts": .object(conn)])
    }

    private func buildUsers(
        ids: [String],
        startCursor: String? = nil,
        endCursor: String? = nil,
        hasPrev: Bool = false,
        hasNext: Bool = false
    ) -> JSONValue {
        let edges: [JSONValue] = ids.map { id in
            .object([
                "__typename": "UserEdge",
                "cursor": .string(id),
                "node": .object(["__typename": "User", "id": .string(id), "name": .string(id)])
            ])
        }
        return .object([
            "users": .object([
                "__typename": "UserConnection",
                "pageInfo": .object([
                    "__typename": "PageInfo",
                    "startCursor": startCursor.map(JSONValue.string) ?? (ids.first.map(JSONValue.string) ?? .null),
                    "endCursor": endCursor.map(JSONValue.string) ?? (ids.last.map(JSONValue.string) ?? .null),
                    "hasPreviousPage": .bool(hasPrev),
                    "hasNextPage": .bool(hasNext),
                ]),
                "edges": .array(edges),
            ])
        ])
    }

    private func canonicalNodeIds(_ graph: Graph, _ canonicalKey: CacheKey) -> [String] {
        let edges = graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        return edges.compactMap { ek in
            guard let nodeRef = graph.getField(ek, "node")?.ref else { return nil }
            return graph.getField(nodeRef, "id")?.string
        }
    }

    // MARK: - Forward pagination

    func test_forward_appendsAtCursor() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        docs.normalize(plan: plan, variables: ["first": 3], data: buildPosts(
            ids: ["p1", "p2", "p3"], endCursor: "p3", hasNext: true
        ))
        docs.normalize(plan: plan, variables: ["first": 3, "after": "p3"], data: buildPosts(
            ids: ["p4", "p5", "p6"], endCursor: "p6", hasPrev: true, hasNext: false
        ))

        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["p1", "p2", "p3", "p4", "p5", "p6"])

        let pageInfoKey = "\(canonicalKey).pageInfo"
        XCTAssertEqual(graph.getField(pageInfoKey, "endCursor")?.string, "p6")
        XCTAssertEqual(graph.getField(pageInfoKey, "hasNextPage")?.bool, false)
    }

    func test_forward_pageInfo_endBoundaryUpdated() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        docs.normalize(plan: plan, variables: ["first": 3], data: buildPosts(
            ids: ["p1", "p2", "p3"], startCursor: "p1", endCursor: "p3", hasPrev: false, hasNext: true
        ))
        docs.normalize(plan: plan, variables: ["first": 3, "after": "p3"], data: buildPosts(
            ids: ["p4", "p5", "p6"], startCursor: "p4", endCursor: "p6", hasPrev: true, hasNext: false
        ))

        let pageInfoKey = "\(canonicalKey).pageInfo"
        XCTAssertEqual(graph.getField(pageInfoKey, "startCursor")?.string, "p1", "start stays at the leader's cursor")
        XCTAssertEqual(graph.getField(pageInfoKey, "endCursor")?.string, "p6", "end advances with appended page")
        XCTAssertEqual(graph.getField(pageInfoKey, "hasPreviousPage")?.bool, false)
        XCTAssertEqual(graph.getField(pageInfoKey, "hasNextPage")?.bool, false)
    }

    func test_forward_refetchSamePage_dedupAgainstKept() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        docs.normalize(plan: plan, variables: ["first": 3], data: buildPosts(
            ids: ["p1", "p2", "p3"], endCursor: "p3", hasNext: true
        ))
        docs.normalize(plan: plan, variables: ["first": 3, "after": "p3"], data: buildPosts(
            ids: ["p4", "p5", "p6"], endCursor: "p6", hasNext: true
        ))
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["p1", "p2", "p3", "p4", "p5", "p6"])

        // Refetch same page (same after cursor), but server now says hasNextPage=false.
        docs.normalize(plan: plan, variables: ["first": 3, "after": "p3"], data: buildPosts(
            ids: ["p4", "p5", "p6"], endCursor: "p6", hasNext: false
        ))

        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["p1", "p2", "p3", "p4", "p5", "p6"],
            "refetched page must dedup against kept p4/p5/p6 — no duplicates")
        XCTAssertEqual(graph.getField("\(canonicalKey).pageInfo", "hasNextPage")?.bool, false)
    }

    func test_forward_preservesExistingExtras() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        docs.normalize(plan: plan, variables: ["first": 3], data: buildPosts(
            ids: ["p1", "p2", "p3"], endCursor: "p3", hasNext: true, totalCount: 100
        ))
        XCTAssertEqual(graph.getField(canonicalKey, "totalCount")?.int, 100)

        // Second page does NOT include totalCount — existing must survive.
        docs.normalize(plan: plan, variables: ["first": 3, "after": "p3"], data: buildPosts(
            ids: ["p4", "p5", "p6"], endCursor: "p6", hasNext: false
        ))

        XCTAssertEqual(graph.getField(canonicalKey, "totalCount")?.int, 100,
            "existing totalCount must survive a paginated fetch that doesn't include it")
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["p1", "p2", "p3", "p4", "p5", "p6"])
    }

    func test_forward_updatesExtrasWhenIncomingProvidesNew() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        docs.normalize(plan: plan, variables: ["first": 3], data: buildPosts(
            ids: ["p1", "p2", "p3"], hasNext: true, totalCount: 100
        ))

        docs.normalize(plan: plan, variables: ["first": 3, "after": "p3"], data: buildPosts(
            ids: ["p4", "p5"], hasNext: false, totalCount: 105
        ))

        XCTAssertEqual(graph.getField(canonicalKey, "totalCount")?.int, 105,
            "incoming totalCount overrides existing")
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["p1", "p2", "p3", "p4", "p5"])
    }

    func test_forward_missingCursor_appendsAtEnd() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        docs.normalize(plan: plan, variables: ["first": 3], data: buildPosts(
            ids: ["p1", "p2", "p3"], endCursor: "p3", hasNext: true
        ))
        // Cursor "p99" doesn't exist in canonical — should append at end.
        docs.normalize(plan: plan, variables: ["first": 3, "after": "p99"], data: buildPosts(
            ids: ["p4", "p5", "p6"], endCursor: "p6", hasNext: false
        ))

        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["p1", "p2", "p3", "p4", "p5", "p6"])
    }

    // MARK: - Backward pagination

    func test_backward_pageInfo_startBoundaryUpdated() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        docs.normalize(plan: plan, variables: ["first": 3], data: buildPosts(
            ids: ["p4", "p5", "p6"], startCursor: "p4", endCursor: "p6", hasPrev: true, hasNext: true
        ))
        docs.normalize(plan: plan, variables: ["last": 3, "before": "p4"], data: buildPosts(
            ids: ["p1", "p2", "p3"], startCursor: "p1", endCursor: "p3", hasPrev: false, hasNext: true
        ))

        let pageInfoKey = "\(canonicalKey).pageInfo"
        XCTAssertEqual(graph.getField(pageInfoKey, "startCursor")?.string, "p1", "start advances with prepended page")
        XCTAssertEqual(graph.getField(pageInfoKey, "endCursor")?.string, "p6", "end stays from leader")
        XCTAssertEqual(graph.getField(pageInfoKey, "hasPreviousPage")?.bool, false)
        XCTAssertEqual(graph.getField(pageInfoKey, "hasNextPage")?.bool, true)
    }

    func test_backward_missingCursor_prependsAtStart() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        docs.normalize(plan: plan, variables: ["first": 3], data: buildPosts(
            ids: ["p4", "p5", "p6"], startCursor: "p4", endCursor: "p6", hasNext: false
        ))
        docs.normalize(plan: plan, variables: ["last": 3, "before": "p99"], data: buildPosts(
            ids: ["p1", "p2", "p3"], startCursor: "p1", endCursor: "p3", hasPrev: false
        ))

        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["p1", "p2", "p3", "p4", "p5", "p6"])
    }

    func test_backward_multiplePagesInSequence() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        docs.normalize(plan: plan, variables: ["first": 2], data: buildPosts(
            ids: ["p5", "p6"], startCursor: "p5", endCursor: "p6", hasPrev: true
        ))
        docs.normalize(plan: plan, variables: ["last": 2, "before": "p5"], data: buildPosts(
            ids: ["p3", "p4"], startCursor: "p3", endCursor: "p4", hasPrev: true
        ))
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["p3", "p4", "p5", "p6"])

        docs.normalize(plan: plan, variables: ["last": 2, "before": "p3"], data: buildPosts(
            ids: ["p1", "p2"], startCursor: "p1", endCursor: "p2", hasPrev: false
        ))
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["p1", "p2", "p3", "p4", "p5", "p6"])

        let pageInfoKey = "\(canonicalKey).pageInfo"
        XCTAssertEqual(graph.getField(pageInfoKey, "startCursor")?.string, "p1")
        XCTAssertEqual(graph.getField(pageInfoKey, "hasPreviousPage")?.bool, false)
    }

    // MARK: - Splice behavior

    func test_splice_refetchSameLeaderPage_replaces() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        docs.normalize(plan: plan, variables: ["first": 4], data: buildPosts(
            ids: ["p1", "p2", "p3", "p4"], endCursor: "p4", hasNext: true
        ))
        docs.normalize(plan: plan, variables: ["first": 4, "after": "p4"], data: buildPosts(
            ids: ["p5", "p6", "p7", "p8"], endCursor: "p8", hasNext: false
        ))
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8"])

        // Refetch leader (no cursor) — splices entire canonical with new leader edges.
        docs.normalize(plan: plan, variables: ["first": 4], data: buildPosts(
            ids: ["p1", "p2", "p3", "p4"], endCursor: "p4", hasNext: true
        ))
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey), ["p1", "p2", "p3", "p4"],
            "leader refetch must reset the canonical to leader-only edges")
    }

    // MARK: - Connection filters

    func test_filters_separateCanonicalKeys() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(usersQuery))

        docs.normalize(plan: plan, variables: ["role": "admin", "first": 2], data: buildUsers(
            ids: ["u1", "u2"], startCursor: "u1", endCursor: "u2", hasNext: false
        ))
        docs.normalize(plan: plan, variables: ["role": "user", "first": 2], data: buildUsers(
            ids: ["u3", "u4"], startCursor: "u3", endCursor: "u4", hasNext: false
        ))

        let adminKey: CacheKey = #"@connection.users({"role":"admin"})"#
        let userKey: CacheKey = #"@connection.users({"role":"user"})"#

        XCTAssertEqual(canonicalNodeIds(graph, adminKey), ["u1", "u2"])
        XCTAssertEqual(canonicalNodeIds(graph, userKey), ["u3", "u4"])
        // Both connections must have their own pageInfo refs.
        XCTAssertEqual(graph.getField(adminKey, CachebayConstants.connectionPageInfoField)?.ref, "\(adminKey).pageInfo")
        XCTAssertEqual(graph.getField(userKey, CachebayConstants.connectionPageInfoField)?.ref, "\(userKey).pageInfo")
    }

    func test_filters_paginateIndependently() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(usersQuery))
        let adminKey: CacheKey = #"@connection.users({"role":"admin"})"#
        let userKey: CacheKey = #"@connection.users({"role":"user"})"#

        docs.normalize(plan: plan, variables: ["role": "admin", "first": 2], data: buildUsers(
            ids: ["a1", "a2"], endCursor: "a2", hasNext: true
        ))
        docs.normalize(plan: plan, variables: ["role": "user", "first": 2], data: buildUsers(
            ids: ["u1", "u2"], endCursor: "u2", hasNext: true
        ))
        // Paginate only admin — user must not change.
        docs.normalize(plan: plan, variables: ["role": "admin", "first": 2, "after": "a2"], data: buildUsers(
            ids: ["a3"], endCursor: "a3", hasNext: false
        ))

        XCTAssertEqual(canonicalNodeIds(graph, adminKey), ["a1", "a2", "a3"])
        XCTAssertEqual(canonicalNodeIds(graph, userKey), ["u1", "u2"], "the other filter's connection must be unaffected")
    }

    // MARK: - splice discards stale pages on middle refetch

    /// Forward parity: refetching a middle page (e.g. `after: p3`) must
    /// reset the canonical to `prefix + middle` and DROP everything past
    /// the middle. Web parity: cursor-based splice replaces the entire
    /// post-cursor suffix.
    func test_forward_refetchMiddlePage_discardsFuturePages() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        docs.normalize(plan: plan, variables: ["first": 3], data: buildPosts(
            ids: ["p1", "p2", "p3"], startCursor: "p1", endCursor: "p3", hasNext: true
        ))
        docs.normalize(plan: plan, variables: ["first": 3, "after": "p3"], data: buildPosts(
            ids: ["p4", "p5", "p6"], startCursor: "p4", endCursor: "p6", hasNext: true
        ))
        docs.normalize(plan: plan, variables: ["first": 3, "after": "p6"], data: buildPosts(
            ids: ["p7", "p8", "p9"], startCursor: "p7", endCursor: "p9", hasNext: false
        ))
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey),
            ["p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8", "p9"])

        // Refetch middle page (after: p3) — must drop p7/p8/p9 (the splice replaces
        // everything past the cursor with the new middle page).
        docs.normalize(plan: plan, variables: ["first": 3, "after": "p3"], data: buildPosts(
            ids: ["p4", "p5", "p6"], startCursor: "p4", endCursor: "p6", hasNext: true
        ))

        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey),
            ["p1", "p2", "p3", "p4", "p5", "p6"],
            "refetching a middle page must truncate the post-cursor suffix to the new middle page")

        let pageInfoKey = "\(canonicalKey).pageInfo"
        XCTAssertEqual(graph.getField(pageInfoKey, "startCursor")?.string, "p1")
        XCTAssertEqual(graph.getField(pageInfoKey, "endCursor")?.string, "p6")
        XCTAssertEqual(graph.getField(pageInfoKey, "hasNextPage")?.bool, true)
    }

    /// Backward parity: refetching a backward middle page (e.g. `before:p7`)
    /// must reset the canonical to `middle + suffix` and DROP everything
    /// earlier than the middle.
    func test_backward_refetchMiddlePage_discardsEarlierPages() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(postsQuery))
        let canonicalKey: CacheKey = "@connection.posts({})"

        // Leader page in the middle of the stream.
        docs.normalize(plan: plan, variables: ["first": 3], data: buildPosts(
            ids: ["p7", "p8", "p9"], startCursor: "p7", endCursor: "p9", hasPrev: true, hasNext: false
        ))
        // Prepend page (before: p7).
        docs.normalize(plan: plan, variables: ["last": 3, "before": "p7"], data: buildPosts(
            ids: ["p4", "p5", "p6"], startCursor: "p4", endCursor: "p6", hasPrev: true, hasNext: true
        ))
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey),
            ["p4", "p5", "p6", "p7", "p8", "p9"])

        // Prepend earlier page (before: p4).
        docs.normalize(plan: plan, variables: ["last": 3, "before": "p4"], data: buildPosts(
            ids: ["p1", "p2", "p3"], startCursor: "p1", endCursor: "p3", hasPrev: false, hasNext: true
        ))
        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey),
            ["p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8", "p9"])

        // Refetch middle page (before: p7) — must drop p1/p2/p3 (everything earlier
        // than the new middle).
        docs.normalize(plan: plan, variables: ["last": 3, "before": "p7"], data: buildPosts(
            ids: ["p4", "p5", "p6"], startCursor: "p4", endCursor: "p6", hasPrev: true, hasNext: true
        ))

        XCTAssertEqual(canonicalNodeIds(graph, canonicalKey),
            ["p4", "p5", "p6", "p7", "p8", "p9"],
            "refetching a backward middle page must drop pages earlier than the new middle")

        let pageInfoKey = "\(canonicalKey).pageInfo"
        XCTAssertEqual(graph.getField(pageInfoKey, "startCursor")?.string, "p4")
        XCTAssertEqual(graph.getField(pageInfoKey, "endCursor")?.string, "p9")
        XCTAssertEqual(graph.getField(pageInfoKey, "hasPreviousPage")?.bool, true)
        XCTAssertEqual(graph.getField(pageInfoKey, "hasNextPage")?.bool, false)
    }

    func test_filters_leaderRefetch_isolated() throws {
        let (graph, planner, _, docs) = makeStack()
        let plan = try planner.getPlan(.source(usersQuery))
        let adminKey: CacheKey = #"@connection.users({"role":"admin"})"#

        docs.normalize(plan: plan, variables: ["role": "admin", "first": 2], data: buildUsers(
            ids: ["u1", "u2"], startCursor: "u1", endCursor: "u2", hasNext: true
        ))
        docs.normalize(plan: plan, variables: ["role": "admin", "first": 2, "after": "u2"], data: buildUsers(
            ids: ["u3", "u4"], startCursor: "u3", endCursor: "u4", hasNext: false
        ))
        XCTAssertEqual(canonicalNodeIds(graph, adminKey), ["u1", "u2", "u3", "u4"])

        // Leader refetch resets to leader.
        docs.normalize(plan: plan, variables: ["role": "admin", "first": 2], data: buildUsers(
            ids: ["u1", "u2"], startCursor: "u1", endCursor: "u2", hasNext: true
        ))
        XCTAssertEqual(canonicalNodeIds(graph, adminKey), ["u1", "u2"])
        let pageInfoKey = "\(adminKey).pageInfo"
        XCTAssertEqual(graph.getField(pageInfoKey, "startCursor")?.string, "u1")
        XCTAssertEqual(graph.getField(pageInfoKey, "endCursor")?.string, "u2")
    }
}
