import XCTest
@testable import Cachebay

/// Typed coverage for `OptimisticBuilder.writeFragment(fragment:id:data:)` — the
/// layer-aware counterpart to `CachebayClient.writeFragment`. Normalizes nested
/// entities into separate records, captures baselines, and reverts the whole tree.

@CachebayData(typename: "Story")
private struct StoryFieldsData: Identifiable, Sendable, Hashable, CachebayValue {
    let __typename: String
    let id: String
    let title: String
    let comments: [Comment]

    @CachebayData(typename: "Comment")
    struct Comment: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let body: String
    }
}

private enum StoryFields: CachebayFragment {
    typealias Data = StoryFieldsData
    static let fragmentName = "StoryFields"
    static let onTypename = "Story"
    static let document: QueryDocument = .source(
        """
        fragment StoryFields on Story {
            __typename
            id
            title
            comments { __typename id body }
        }
        """)
    static var __cachebayFieldNames: [AnyKeyPath: String] { StoryFieldsData.__cachebayFieldNames }
}

final class OptimisticWriteFragmentTests: XCTestCase {
    private func makeClient() -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
    }

    private static func makeStoryData() -> StoryFields.Data {
        StoryFields.Data(
            id: "s1",
            title: "Hello",
            comments: [.init(id: "c1", body: "first"), .init(id: "c2", body: "second")]
        )
    }

    // 1. Nested entity list is normalized into its own records on write.
    func test_writeFragment_normalizesNestedEntityList() {
        let client = makeClient()
        let _tx = client.modifyOptimistic { b in
            b.writeFragment(fragment: StoryFields.self, id: "s1", data: Self.makeStoryData())
        }

        let story = client.graph.getRecord("Story:s1")
        XCTAssertEqual(story?["title"], .string("Hello"))
        XCTAssertEqual(
            story?["comments"], .refList(["Comment:c1", "Comment:c2"]),
            "nested entity-list field must be a refList of cache keys, not embedded objects")
        XCTAssertEqual(client.graph.getRecord("Comment:c1")?["body"], .string("first"))
        XCTAssertEqual(client.graph.getRecord("Comment:c1")?["__typename"], .string("Comment"))
        XCTAssertEqual(client.graph.getRecord("Comment:c2")?["body"], .string("second"))
        withExtendedLifetime(_tx) {}
    }

    // 2. Revert undoes the entire entity tree (parent + all fresh children).
    func test_writeFragment_revert_dropsParentAndAllNestedEntities() {
        let client = makeClient()
        let tx = client.modifyOptimistic { b in
            b.writeFragment(fragment: StoryFields.self, id: "s1", data: Self.makeStoryData())
        }
        XCTAssertNotNil(client.graph.getRecord("Story:s1"))
        XCTAssertNotNil(client.graph.getRecord("Comment:c1"))
        XCTAssertNotNil(client.graph.getRecord("Comment:c2"))

        tx.revert()

        XCTAssertNil(client.graph.getRecord("Story:s1"))
        XCTAssertNil(client.graph.getRecord("Comment:c1"))
        XCTAssertNil(client.graph.getRecord("Comment:c2"))
    }

    // 3. A pre-existing nested entity is restored to baseline (not dropped) on revert.
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

        let tx = client.modifyOptimistic { b in
            b.writeFragment(fragment: StoryFields.self, id: "s1", data: Self.makeStoryData())
        }
        XCTAssertEqual(client.graph.getField("Comment:c1", "body")?.string, "first")

        tx.revert()

        XCTAssertEqual(
            client.graph.getField("Comment:c1", "body")?.string, "ORIGINAL",
            "pre-existing record must restore to its baseline, not vanish")
        XCTAssertNotNil(client.graph.getRecord("Comment:c1"))
        XCTAssertNil(
            client.graph.getRecord("Comment:c2"),
            "fresh record introduced by the write must still be dropped")
    }
}
