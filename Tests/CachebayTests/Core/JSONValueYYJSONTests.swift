import XCTest
import Foundation
@testable import Cachebay

/// Phase 1: the yyjson-backed `JSONValue.from(json:)` codec. Asserts correctness
/// on a battery of shapes, the intentional number-typing fix, and structural
/// parity against the old Foundation path (`JSONSerialization` + `from(any:)`)
/// across many samples — tolerating only the documented int-vs-double change.
final class JSONValueYYJSONTests: XCTestCase {

    private func parse(_ s: String) throws -> JSONValue {
        try JSONValue.from(json: Data(s.utf8))
    }

    // MARK: - Scalars

    func test_scalars() throws {
        XCTAssertEqual(try parse("\"hi\""), .string("hi"))
        XCTAssertEqual(try parse("true"), .bool(true))
        XCTAssertEqual(try parse("false"), .bool(false))
        XCTAssertEqual(try parse("null"), .null)
        XCTAssertEqual(try parse("42"), .int(42))
        XCTAssertEqual(try parse("-7"), .int(-7))
        XCTAssertEqual(try parse("0"), .int(0))
    }

    // The headline fix: yyjson preserves real-ness from the literal, so `100.0`
    // is `.double`. The old NSNumber `.stringValue.contains(".")` heuristic
    // misclassified it as `.int(100)`.
    func test_numberTyping_realStaysDouble() throws {
        XCTAssertEqual(try parse("100.0"), .double(100.0))
        XCTAssertEqual(try parse("3.14"), .double(3.14))
        XCTAssertEqual(try parse("1e3"), .double(1000.0))
        XCTAssertEqual(try parse("1.5e2"), .double(150.0))
        XCTAssertEqual(try parse("-0.5"), .double(-0.5))
        // Integer literals stay ints.
        XCTAssertEqual(try parse("100"), .int(100))
    }

    func test_bigIntegers() throws {
        XCTAssertEqual(try parse("9223372036854775807"), .int(Int64.max))
        XCTAssertEqual(try parse("-9223372036854775808"), .int(Int64.min))
        // > Int64.max → promoted to .double (documented edge for uint64).
        guard case .double = try parse("18446744073709551615") else {
            return XCTFail("uint64 max should promote to .double")
        }
    }

    // MARK: - Containers

    func test_nestedAndArrays() throws {
        let v = try parse(#"{"a":[1,2,{"b":"x"}],"c":null,"d":true}"#)
        XCTAssertEqual(
            v,
            .object([
                "a": .array([.int(1), .int(2), .object(["b": .string("x")])]),
                "c": .null,
                "d": .bool(true),
            ]))
    }

    func test_emptyContainers() throws {
        XCTAssertEqual(try parse("{}"), .object([:]))
        XCTAssertEqual(try parse("[]"), .array([]))
        XCTAssertEqual(try parse(#"{"a":{},"b":[]}"#), .object(["a": .object([:]), "b": .array([])]))
    }

    func test_unicodeAndEscapes() throws {
        XCTAssertEqual(try parse(#""café \"q\" \n\t""#), .string("café \"q\" \n\t"))
        XCTAssertEqual(try parse(#""🎉""#), .string("🎉"))
        XCTAssertEqual(try parse(#"{"kéy":1}"#), .object(["kéy": .int(1)]))
    }

    func test_deepNesting() throws {
        let v = try parse(#"[[[[[1]]]]]"#)
        XCTAssertEqual(v, .array([.array([.array([.array([.array([.int(1)])])])])]))
    }

    // MARK: - Errors

    func test_invalidJSON_throws() {
        XCTAssertThrowsError(try parse("{ not json"))
        XCTAssertThrowsError(try parse(""))
        XCTAssertThrowsError(try parse(#"{"a":}"#))
        XCTAssertThrowsError(try parse("[1,2"))
    }

    // MARK: - Network path must NOT restore refs

    func test_networkPath_doesNotRestoreRefs() throws {
        // from(json:) is the server/response path: a literal {"__ref":…} object
        // must stay an object (only the store-decode path restores sentinels).
        XCTAssertEqual(try parse(#"{"__ref":"User:1"}"#), .object(["__ref": .string("User:1")]))
        XCTAssertEqual(
            try parse(#"{"__refs":["A","B"]}"#),
            .object(["__refs": .array([.string("A"), .string("B")])]))
    }

    // Duplicate keys are spec-implementation-defined and never occur in GraphQL
    // responses or our own store blobs. yyjson resolves last-wins (vs
    // JSONSerialization's first-wins) — documented here as intentional, not parity.
    func test_duplicateKeys_lastWins() throws {
        XCTAssertEqual(try parse(#"{"a":1,"a":2}"#), .object(["a": .int(2)]))
    }

    // MARK: - Differential parity vs Foundation

    /// Coerce every number to `.double` so the *intended* int-vs-double change
    /// doesn't trip the comparison, while structure/strings/bools/nulls/keys
    /// must still match exactly.
    private func numbersToDouble(_ v: JSONValue) -> JSONValue {
        switch v {
        case .int(let i): return .double(Double(i))
        case .double(let d): return .double(d)
        case .array(let a): return .array(a.map(numbersToDouble))
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, sub) in o { out[k] = numbersToDouble(sub) }
            return .object(out)
        default: return v
        }
    }

    func test_fuzz_structuralParityWithFoundation() throws {
        let samples: [String] = [
            #"{}"#, #"[]"#, #"null"#, #"true"#, #"false"#, #"0"#, #"-0"#, #"42"#, #"-99"#,
            #""string""#, #""with \"quote\" and \n newline""#, #""unicode: é☃""#,
            #"[1,2,3]"#, #"[1.5, 2.0, 3]"#, #"[true,false,null]"#,
            #"{"a":1,"b":"two","c":true,"d":null,"e":[1,2],"f":{"g":3}}"#,
            #"{"nested":{"deep":{"deeper":[{"x":1},{"y":2.5}]}}}"#,
            #"{"mixed":[1,"two",3.0,true,null,{"k":"v"},[9]]}"#,
            #"{"empty_obj":{},"empty_arr":[],"zero":0,"neg":-5}"#,
            #"[{"id":"1","tags":["a","b"]},{"id":"2","tags":[]}]"#,
            #"{"unicode_key_é":"value","emoji":"🎉🚀"}"#,
            #"{"big":9007199254740991,"small":-9007199254740991}"#,
            #"{"floats":[0.1,0.2,3.14159,1e10,2.5e-3]}"#,
            #"{"bool_array":[true,true,false],"null_array":[null,null]}"#,
            #"   {"leading":"whitespace"}   "#,
        ]
        for s in samples {
            let data = Data(s.utf8)
            let yy = try JSONValue.from(json: data)
            let foundationAny = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let foundation = try JSONValue.from(any: foundationAny)
            XCTAssertEqual(
                numbersToDouble(yy), numbersToDouble(foundation),
                "structural mismatch on sample: \(s)"
            )
        }
    }
}
