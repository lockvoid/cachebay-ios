import XCTest
@testable import Cachebay

/// Coverage for `OptimisticBuilder.writeFragment(...)` — a layer-aware
/// counterpart to `CachebayClient.writeFragment`. Walks the fragment plan
/// + data, captures baselines for every record it touches, normalizes
/// nested entities into separate records, and writes link refs into
/// parents. Use for OPTIMISTIC CREATE flows where a fresh entity tree is
/// built client-side (e.g. an outbound chat message + its attachments) —
/// `client.writeFragment` writes directly to the graph (no baseline
/// capture, no revert), which is wrong for optimistic UX.
///
/// Two key contracts:
///
/// 1. Nested entity lists become normalized records — the parent
///    record's selection-set field is `.refList([key])` and each item
///    exists at its own cache key. Strict materializer (which requires
///    `.ref/.refList/.null` for selection-set fields) accepts the
///    result.
/// 2. Revert undoes everything — parent and every child entity
///    introduced by the write are dropped (or restored to baseline if
///    they pre-existed).
final class OptimisticWriteFragmentTests: XCTestCase {

    // MARK: - Fixtures

    /// Story-with-comments shape mirrors the `ProjectUserMessage`-with-
    /// `attachments` case from FermentCuts: a parent entity with a
    /// nested entity-list selection-set field. The materializer requires
    /// `.refList` for `comments` (selection-set list of entities), so
    /// the optimistic write MUST normalize.
    struct StoryFields: Cachebay.Fragment {
        static let networkQuery = """
        fragment StoryFields on Story {
            __typename
            id
            title
            comments {
                __typename
                id
                body
            }
        }
        """
        static let document: QueryDocument = .source(networkQuery)
        static let fragmentName = "StoryFields"
        static let onTypename = "Story"
        typealias Variables = Cachebay.EmptyVariables

        struct Data: Sendable, Cachebay.OperationData {
            var __data: [String: JSONValue]
            init(__data: [String: JSONValue]) { self.__data = __data }
        }
    }

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    private static func makeStoryData() -> StoryFields.Data {
        StoryFields.Data(__data: [
            "__typename": .string("Story"),
            "id": .string("s1"),
            "title": .string("Hello"),
            "comments": .array([
                .object([
                    "__typename": .string("Comment"),
                    "id": .string("c1"),
                    "body": .string("first"),
                ]),
                .object([
                    "__typename": .string("Comment"),
                    "id": .string("c2"),
                    "body": .string("second"),
                ]),
            ]),
        ])
    }

    // MARK: - 1. Normalize nested entity list on write

    /// `b.writeFragment(...)` on a fresh story+comments tree must:
    ///   - Write `Story:s1` with `comments: .refList(["Comment:c1", "Comment:c2"])`
    ///   - Write `Comment:c1` and `Comment:c2` as their own records
    /// Strict materializer's expectation (`Documents.swift:638-685`) is
    /// `.refList` for selection-set list-of-entities — embedded objects
    /// fall through to "unexpected link shape" and silence the watcher.
    func test_writeFragment_normalizesNestedEntityList() {
        let client = makeClient()

        client.modifyOptimistic { b, _ in
            b.writeFragment(fragment: StoryFields.self, id: "s1", data: Self.makeStoryData())
        }

        let story = client.graph.getRecord("Story:s1")
        XCTAssertEqual(story?["title"], .string("Hello"),
            "scalar fields must land on the parent record")
        XCTAssertEqual(story?["comments"], .refList(["Comment:c1", "Comment:c2"]),
            "nested entity-list field must be a refList of cache keys, not embedded objects")

        let c1 = client.graph.getRecord("Comment:c1")
        XCTAssertEqual(c1?["body"], .string("first"),
            "each nested entity must exist as its own normalized record")
        XCTAssertEqual(c1?["__typename"], .string("Comment"))
        XCTAssertEqual(client.graph.getRecord("Comment:c2")?["body"], .string("second"))
    }

    // MARK: - 2. Revert undoes the entire entity tree

    /// Revert must restore the graph as if the optimistic write never
    /// happened — both the parent and every child record introduced by
    /// the write must be dropped. Without baseline capture for nested
    /// children, only the parent would be reverted and orphan
    /// `Comment:*` records would leak into the cache.
    func test_writeFragment_revert_dropsParentAndAllNestedEntities() {
        let client = makeClient()

        let tx = client.modifyOptimistic { b, _ in
            b.writeFragment(fragment: StoryFields.self, id: "s1", data: Self.makeStoryData())
        }
        XCTAssertNotNil(client.graph.getRecord("Story:s1"))
        XCTAssertNotNil(client.graph.getRecord("Comment:c1"))
        XCTAssertNotNil(client.graph.getRecord("Comment:c2"))

        tx.revert()

        XCTAssertNil(client.graph.getRecord("Story:s1"),
            "revert must drop the parent record")
        XCTAssertNil(client.graph.getRecord("Comment:c1"),
            "revert must drop nested entity records introduced by the write — otherwise they orphan")
        XCTAssertNil(client.graph.getRecord("Comment:c2"))
    }

    // MARK: - 3. Pre-existing nested entity is restored to baseline on revert

    /// If a nested entity already exists in the cache before the
    /// optimistic write (e.g. an Element seeded by a prior upload),
    /// the optimistic write merges into it. Revert must restore the
    /// pre-write snapshot, NOT drop the record.
    func test_writeFragment_revert_restoresPreExistingNestedEntityToBaseline() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "Comment:c1",
            fragment: "fragment C on Comment { id body }",
            data: .object([
                "__typename": .string("Comment"),
                "id": .string("c1"),
                "body": .string("ORIGINAL"),
            ])
        )

        let tx = client.modifyOptimistic { b, _ in
            b.writeFragment(fragment: StoryFields.self, id: "s1", data: Self.makeStoryData())
        }
        XCTAssertEqual(client.graph.getField("Comment:c1", "body")?.string, "first",
            "optimistic write must override the pre-existing body")

        tx.revert()

        XCTAssertEqual(client.graph.getField("Comment:c1", "body")?.string, "ORIGINAL",
            "pre-existing record must restore to its baseline body, not vanish")
        XCTAssertNotNil(client.graph.getRecord("Comment:c1"),
            "pre-existing record must NOT be dropped on revert (would orphan other watchers)")
        XCTAssertNil(client.graph.getRecord("Comment:c2"),
            "fresh record introduced by the write must still be dropped")
    }
}
