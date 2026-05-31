import XCTest
import Foundation
import Cachebay
@testable import CachebayMacros

/// WS2 — `@CachebayUnion`: same mechanics as interface, but the only lifted shared
/// field is `__typename` (unions have no other schema-level shared fields).
final class CachebayUnionBehaviourTests: XCTestCase {

    func test_decode_members_and_unknown() {
        // Video member.
        guard let v = SearchResult(_dataDict: [
            "__typename": .string("Video"), "id": .string("v1"),
            "url": .string("https://x.com/v1.mp4"),
        ]) else { return XCTFail() }
        guard case .video(let video) = v else { return XCTFail("expected .video") }
        XCTAssertEqual(video.url.absoluteString, "https://x.com/v1.mp4")

        // Article member.
        guard let a = SearchResult(_dataDict: [
            "__typename": .string("Article"), "id": .string("a1"),
            "title": .string("Hello"),
        ]) else { return XCTFail() }
        guard case .article(let article) = a else { return XCTFail("expected .article") }
        XCTAssertEqual(article.title, "Hello")

        // Unknown member (schema evolution) — only __typename is carried.
        guard let u = SearchResult(_dataDict: ["__typename": .string("Podcast")]) else { return XCTFail() }
        guard case .unknown(let s) = u else { return XCTFail("expected .unknown") }
        XCTAssertEqual(s.__typename, "Podcast")
    }

    // The lifted accessor for a union is __typename only, working on every variant.
    func test_lifted_typename_acrossVariants() {
        XCTAssertEqual(SearchResult(_dataDict: [
            "__typename": .string("Video"), "id": .string("v1"), "url": .string("https://x.com/v.mp4"),
        ])?.__typename, "Video")
        XCTAssertEqual(SearchResult(_dataDict: ["__typename": .string("Podcast")])?.__typename, "Podcast")
    }
}
