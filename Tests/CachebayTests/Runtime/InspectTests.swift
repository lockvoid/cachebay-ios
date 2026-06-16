import XCTest
@testable import Cachebay

/// Port of `cachebay-web/test/unit/core/inspect.test.ts`.
///
/// Inspect's iOS surface is intentionally narrower than the JS version
/// (no `queries()` / `fragments()` rollups — those live on the
/// subsystems directly via `Queries.inspect()` / `Fragments.inspect()`).
/// The tests below cover the three load-bearing public methods on iOS:
/// `getRecord`, `getEntityKeys(typename:)`, and `getConnectionKeys(...)`.
final class InspectTests: XCTestCase {

    private func makeStack() -> (Graph, Inspect) {
        let graph = Graph(
            options: GraphOptions(keys: [
                "User": { _, obj in obj["id"]?.string }
            ]))
        return (graph, Inspect(graph: graph))
    }

    /// Minimal helper: write a "page record" in the same shape the
    /// normalizer produces — `@.parent.field({...})` with an `edges`
    /// refList. The web fixture emits this through a `documents`-level
    /// helper; on iOS we go straight to `graph.putRecord` because
    /// `Inspect.getConnectionKeys` only inspects record key shapes,
    /// not the contents.
    private func writePage(_ graph: Graph, key: CacheKey, edgeRefs: [CacheKey] = []) {
        graph.putRecord(
            key,
            [
                "__typename": .string("PostConnection"),
                CachebayConstants.connectionEdgesField: .refList(edgeRefs),
            ])
        graph.flush()
    }

    // MARK: - getEntityKeys

    func test_getEntityKeys_emptyGraph_returnsEmpty() {
        let (_, inspect) = makeStack()
        XCTAssertEqual(inspect.getEntityKeys(), [])
    }

    func test_getEntityKeys_excludesRoot_pages_andEdges() {
        let (graph, inspect) = makeStack()

        // Root sentinel — must be excluded by the entity filter.
        graph.putRecord(CachebayConstants.rootID, ["__typename": .string("@")])
        graph.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "email": .string("a@b.c")])
        graph.putRecord("Post:p1", ["__typename": .string("Post"), "id": .string("p1"), "title": .string("P1")])
        graph.putRecord("Post:p2", ["__typename": .string("Post"), "id": .string("p2"), "title": .string("P2")])

        // Page record under `@.User:u1.posts(...)` — must be excluded.
        let pageKey: CacheKey = "@.User:u1.posts({\"first\":1})"
        writePage(graph, key: pageKey, edgeRefs: ["@.User:u1.posts({\"first\":1}).edges.0"])

        let keys = inspect.getEntityKeys().sorted()
        XCTAssertTrue(keys.contains("User:u1"))
        XCTAssertTrue(keys.contains("Post:p1"))
        XCTAssertTrue(keys.contains("Post:p2"))
        XCTAssertFalse(keys.contains(CachebayConstants.rootID))
        XCTAssertFalse(keys.contains(pageKey))
        // No edge records leak through.
        XCTAssertFalse(keys.contains { $0.contains(".edges.") })
    }

    func test_getEntityKeys_filterByTypename() {
        let (graph, inspect) = makeStack()
        graph.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1")])
        graph.putRecord("User:u2", ["__typename": .string("User"), "id": .string("u2")])
        graph.putRecord("Post:p1", ["__typename": .string("Post"), "id": .string("p1")])

        XCTAssertEqual(inspect.getEntityKeys(typename: "User").sorted(), ["User:u1", "User:u2"])
        XCTAssertEqual(inspect.getEntityKeys(typename: "Post"), ["Post:p1"])
        XCTAssertEqual(inspect.getEntityKeys(typename: "Comment"), [])
    }

    // MARK: - getConnectionKeys

    func test_getConnectionKeys_emptyGraph_returnsEmpty() {
        let (_, inspect) = makeStack()
        XCTAssertEqual(inspect.getConnectionKeys(), [])
    }

    func test_getConnectionKeys_root_mapsToCanonical_andStripsPagination() {
        let (graph, inspect) = makeStack()

        // Three pages on the root posts(): two share `category=tech`,
        // one is `category=lifestyle`. Canonical normalisation must
        // dedupe by filter args and strip pagination.
        let pageA: CacheKey = "@.posts({\"category\":\"tech\",\"first\":1})"
        let pageB: CacheKey = "@.posts({\"after\":\"p1\",\"category\":\"tech\",\"first\":1})"
        let pageC: CacheKey = "@.posts({\"category\":\"lifestyle\",\"first\":1})"

        writePage(graph, key: pageA)
        writePage(graph, key: pageB)
        writePage(graph, key: pageC)

        let keys = inspect.getConnectionKeys(parent: .root, key: "posts").sorted()
        XCTAssertEqual(
            keys,
            [
                "@connection.posts({\"category\":\"lifestyle\"})",
                "@connection.posts({\"category\":\"tech\"})",
            ])
    }

    func test_getConnectionKeys_scopedByEntityParent() {
        let (graph, inspect) = makeStack()

        graph.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1")])
        graph.putRecord("User:u2", ["__typename": .string("User"), "id": .string("u2")])

        let u1A: CacheKey = "@.User:u1.posts({\"category\":\"tech\",\"first\":1})"
        let u1B: CacheKey = "@.User:u1.posts({\"after\":\"p2\",\"category\":\"tech\",\"first\":1})"
        let u2A: CacheKey = "@.User:u2.posts({\"category\":\"tech\",\"first\":1})"

        writePage(graph, key: u1A)
        writePage(graph, key: u1B)
        writePage(graph, key: u2A)

        let user1 = inspect.getConnectionKeys(parent: .entity("User:u1"), key: "posts")
        let user2 = inspect.getConnectionKeys(parent: .entity("User:u2"), key: "posts")

        XCTAssertEqual(user1, ["@connection.User:u1.posts({\"category\":\"tech\"})"])
        XCTAssertEqual(user2, ["@connection.User:u2.posts({\"category\":\"tech\"})"])
    }

    func test_getConnectionKeys_paginationOnly_emitsEmptyArgs() {
        let (graph, inspect) = makeStack()

        let pageKey: CacheKey = "@.posts({\"after\":\"c1\",\"first\":10})"
        writePage(graph, key: pageKey)

        XCTAssertEqual(
            inspect.getConnectionKeys(parent: .root, key: "posts"),
            ["@connection.posts({})"]
        )
    }

    func test_getConnectionKeys_argsFilter() {
        let (graph, inspect) = makeStack()

        let tech: CacheKey = "@.posts({\"category\":\"tech\",\"first\":1})"
        let life: CacheKey = "@.posts({\"category\":\"lifestyle\",\"first\":1})"
        writePage(graph, key: tech)
        writePage(graph, key: life)

        let onlyTech = inspect.getConnectionKeys(
            parent: .root,
            key: "posts",
            argsFilter: { raw in raw.contains("\"category\":\"tech\"") }
        )
        XCTAssertEqual(onlyTech, ["@connection.posts({\"category\":\"tech\"})"])
    }

    func test_getConnectionKeys_entityObjectParent() {
        // Web suite passes `parent: { __typename: "User", id: "u1" }`;
        // iOS exposes the same selector via `.entityObject(typename:id:)`.
        let (graph, inspect) = makeStack()
        let u1: CacheKey = "@.User:u1.posts({\"category\":\"tech\",\"first\":1})"
        writePage(graph, key: u1)

        let keys = inspect.getConnectionKeys(
            parent: .entityObject(typename: "User", id: "u1"),
            key: "posts"
        )
        XCTAssertEqual(keys, ["@connection.User:u1.posts({\"category\":\"tech\"})"])
    }

    // MARK: - getRecord

    func test_getRecord_nonExistent_returnsNil() {
        let (_, inspect) = makeStack()
        XCTAssertNil(inspect.getRecord("User:nonexistent"))
    }

    func test_getRecord_returnsRawSnapshot() {
        let (graph, inspect) = makeStack()
        graph.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "email": .string("a@b.c")])
        let raw = inspect.getRecord("User:u1")
        XCTAssertEqual(raw?["__typename"]?.string, "User")
        XCTAssertEqual(raw?["id"]?.string, "u1")
        XCTAssertEqual(raw?["email"]?.string, "a@b.c")
    }
}
