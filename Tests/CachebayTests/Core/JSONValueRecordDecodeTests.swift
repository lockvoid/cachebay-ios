import XCTest
import Foundation
@testable import Cachebay

/// Phase 1: `parseYYJSONRecord` — the one-pass store-blob decoder that fuses
/// `__ref`/`__refs` sentinel restoration into the yyjson walk (replacing the
/// old JSONSerialization + `from(any:)` + `restoreRefs` three-pass path).
final class JSONValueRecordDecodeTests: XCTestCase {

    private func decode(_ s: String) throws -> [String: JSONValue] {
        try JSONValue.parseYYJSONRecord(Data(s.utf8))
    }

    func test_restoresTopLevelRef() throws {
        let r = try decode(#"{"id":"1","author":{"__ref":"User:1"}}"#)
        XCTAssertEqual(r["id"], .string("1"))
        XCTAssertEqual(r["author"], .ref("User:1"))
    }

    func test_restoresRefList() throws {
        let r = try decode(#"{"edges":{"__refs":["A","B","C"]}}"#)
        XCTAssertEqual(r["edges"], .refList(["A", "B", "C"]))
    }

    func test_restoresNestedRef() throws {
        let r = try decode(#"{"a":{"b":{"c":{"__ref":"X:9"}}}}"#)
        XCTAssertEqual(r["a"], .object(["b": .object(["c": .ref("X:9")])]))
    }

    func test_restoresRefsInsideArrays() throws {
        let r = try decode(#"{"items":[{"__ref":"P:1"},{"__ref":"P:2"}]}"#)
        XCTAssertEqual(r["items"], .array([.ref("P:1"), .ref("P:2")]))
    }

    func test_nonSentinelSingleKeyObjectStaysObject() throws {
        // A single-key object whose key isn't __ref/__refs is a normal object.
        XCTAssertEqual(try decode(#"{"data":{"only":"field"}}"#),
                       ["data": .object(["only": .string("field")])])
    }

    func test_refsWithNonStringElementStaysObject() throws {
        // {"__refs":[…]} where not every element is a string is NOT a refList.
        let r = try decode(#"{"weird":{"__refs":["A",2,"B"]}}"#)
        XCTAssertEqual(r["weird"], .object(["__refs": .array([.string("A"), .int(2), .string("B")])]))
    }

    func test_rootIsNeverRefified() throws {
        // A record that is literally a single-key __ref object keeps the root as
        // an object (records are entity fields, never a bare ref) — preserves the
        // old `restoreRefs(&obj)` semantics, which only processed values.
        XCTAssertEqual(try decode(#"{"__ref":"User:1"}"#),
                       ["__ref": .string("User:1")])
    }

    func test_nonObjectRoot_throws() {
        XCTAssertThrowsError(try decode(#"[1,2,3]"#))
        XCTAssertThrowsError(try decode(#""scalar""#))
        XCTAssertThrowsError(try decode(""))
    }

    // Equivalence with the old restore semantics on a representative record:
    // mixed scalars + a ref + a refList + nested object, all in one blob.
    func test_mixedRecord_endToEnd() throws {
        let r = try decode(#"""
        {"__typename":"Cook","id":"c1","title":"Pasta","rating":4.5,
         "hero":{"__ref":"VideoElement:v1"},
         "tags":{"__refs":["Tag:1","Tag:2"]},
         "meta":{"views":10,"pinned":true}}
        """#)
        XCTAssertEqual(r["__typename"], .string("Cook"))
        XCTAssertEqual(r["id"], .string("c1"))
        XCTAssertEqual(r["rating"], .double(4.5))
        XCTAssertEqual(r["hero"], .ref("VideoElement:v1"))
        XCTAssertEqual(r["tags"], .refList(["Tag:1", "Tag:2"]))
        XCTAssertEqual(r["meta"], .object(["views": .int(10), "pinned": .bool(true)]))
    }
}
