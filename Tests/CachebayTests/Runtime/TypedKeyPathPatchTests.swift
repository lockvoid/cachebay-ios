import XCTest
import Foundation
import CachebayMacros
@testable import Cachebay

// WS5 / Gate wk9 — KeyPath patch builder over the existing patchFragment path.

@CachebayData(typename: "Cook")
private struct CookFieldsData: Identifiable, Sendable, Hashable, CachebayValue {
    let __typename: String
    let id: String
    let title: String
    let likes: Int
}

private enum CookFields: CachebayFragment {
    typealias Data = CookFieldsData
    static let fragmentName = "CookFields"
    static let onTypename = "Cook"
    static let document: QueryDocument = .source("fragment CookFields on Cook { __typename id title likes }")
    static var __cachebayFieldNames: [AnyKeyPath: String] { CookFieldsData.__cachebayFieldNames }
}

final class TypedKeyPathPatchTests: XCTestCase {
    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(transport: Transport(http: MockHTTPTransport())))
    }

    // set(\.field, value) builds exactly the [String: JSONValue] patch the dict API builds.
    func test_keyPathPatch_buildsSameDictPatch() {
        var patch = CachebayPatch<CookFields>()
        patch.set(\.title, "Renamed")
        patch.set(\.likes, 42)
        XCTAssertEqual(patch.fields, ["title": .string("Renamed"), "likes": .int(42)])
    }

    // The patch routes through patchFragment -> the optimistic layer and lands on the record.
    func test_keyPathPatch_writesThroughOptimisticLayer() {
        let client = makeClient()
        client.graph.putRecord("Cook:c1", [
            "__typename": .string("Cook"), "id": .string("c1"),
            "title": .string("Old"), "likes": .int(1),
        ])

        client.modifyOptimistic { b in
            b.patch(fragment: CookFields.self, id: "c1") { patch in
                patch.set(\.title, "Renamed")
                patch.set(\.likes, 42)
            }
        }

        let rec = client.graph.getRecord("Cook:c1")
        XCTAssertEqual(rec?["title"], .string("Renamed"))   // merged
        XCTAssertEqual(rec?["likes"], .int(42))
        XCTAssertEqual(rec?["id"], .string("c1"))           // untouched fields preserved
    }

    // An empty patch (no set calls) is a no-op — record unchanged.
    func test_keyPathPatch_emptyIsNoOp() {
        let client = makeClient()
        client.graph.putRecord("Cook:c1", [
            "__typename": .string("Cook"), "id": .string("c1"), "title": .string("Old"), "likes": .int(1),
        ])
        client.modifyOptimistic { b in
            b.patch(fragment: CookFields.self, id: "c1") { _ in }
        }
        XCTAssertEqual(client.graph.getRecord("Cook:c1")?["title"], .string("Old"))
    }
}
