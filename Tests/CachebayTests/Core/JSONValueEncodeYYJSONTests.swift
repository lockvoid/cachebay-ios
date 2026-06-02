import XCTest
import Foundation
@testable import Cachebay

/// Phase 1 (encode): the yyjson-writer side of the codec. Asserts encode→decode
/// round-trips (including refs through the store path), sorted-key output for
/// `encodeJSON`, and that the number-typing fix survives a round-trip.
final class JSONValueEncodeYYJSONTests: XCTestCase {

    // Mirrors what SQLiteStorage.encodeRecord/decodeRecord do: encode with refs
    // as sentinels, decode restoring them. Full record fidelity.
    func test_recordRoundTrip_withRefsAndScalars() throws {
        let record: [String: JSONValue] = [
            "__typename": .string("Cook"),
            "id": .string("c1"),
            "count": .int(42),
            "rating": .double(4.5),
            "active": .bool(true),
            "missing": .null,
            "hero": .ref("VideoElement:v1"),
            "tags": .refList(["Tag:1", "Tag:2", "Tag:3"]),
            "meta": .object(["views": .int(10), "nested": .object(["x": .string("y")])]),
            "list": .array([.int(1), .string("a"), .bool(false), .double(2.5)]),
        ]
        let data = try JSONValue.object(record).encodeYYJSON(sortKeys: false, pretty: false)
        XCTAssertEqual(try JSONValue.parseYYJSONRecord(data), record)
    }

    func test_encodeJSON_sortsKeys() throws {
        let data = try JSONValue.object(["banana": .int(1), "apple": .int(2), "cherry": .int(3)]).encodeJSON()
        let s = String(decoding: data, as: UTF8.self)
        let a = s.range(of: "apple")!.lowerBound
        let b = s.range(of: "banana")!.lowerBound
        let c = s.range(of: "cherry")!.lowerBound
        XCTAssertTrue(a < b && b < c, "encodeJSON keys should be sorted: \(s)")
    }

    func test_encodeJSON_roundTrip_nested() throws {
        let v: JSONValue = .object([
            "b": .int(2), "a": .int(1),
            "c": .object(["z": .bool(true), "a": .null]),
            "arr": .array([.string("x"), .double(1.5), .int(0)]),
        ])
        XCTAssertEqual(try JSONValue.from(json: try v.encodeJSON()), v)
    }

    // The number-typing fix must survive a full round-trip: .double(100.0) stays
    // .double (the yyjson writer emits "100.0", the parser reads it back as real).
    func test_numberTyping_survivesRoundTrip() throws {
        let v: JSONValue = .object(["whole": .double(100.0), "int": .int(100), "frac": .double(3.14), "neg": .int(-5)])
        let back = try JSONValue.from(json: try v.encodeJSON())
        XCTAssertEqual(back, v)
        XCTAssertEqual(back["whole"], .double(100.0))
        XCTAssertEqual(back["int"], .int(100))
    }

    func test_emptyContainers_roundTrip() throws {
        XCTAssertEqual(try JSONValue.from(json: JSONValue.object([:]).encodeJSON()), .object([:]))
        XCTAssertEqual(try JSONValue.from(json: JSONValue.array([]).encodeJSON()), .array([]))
    }

    func test_unicodeAndEscapes_roundTrip() throws {
        let v: JSONValue = .object([
            "emoji": .string("🎉🚀"),
            "accent": .string("café"),
            "escapes": .string("a\"b\\c\nd\te"),
        ])
        XCTAssertEqual(try JSONValue.from(json: try v.encodeJSON()), v)
    }

    func test_bigInt_roundTrip() throws {
        let v: JSONValue = .object(["max": .int(Int64.max), "min": .int(Int64.min)])
        XCTAssertEqual(try JSONValue.from(json: try v.encodeJSON()), v)
    }
}
