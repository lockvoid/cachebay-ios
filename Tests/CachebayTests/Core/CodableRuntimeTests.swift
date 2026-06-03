import XCTest
import Foundation
@testable import Cachebay

/// Codable conformances for the two runtime types that generated `@CachebayData`
/// structs depend on: `GraphQLEnum<T>` and `JSONValue`.
final class CodableRuntimeTests: XCTestCase {

    enum SampleIntent: String, Sendable, Hashable, CaseIterable {
        case roll = "ROLL"; case story = "STORY"; case vibe = "VIBE"
    }

    private struct Box: Codable, Equatable { let intent: GraphQLEnum<SampleIntent> }

    // MARK: - GraphQLEnum

    func test_graphQLEnum_encodesRawString() throws {
        let data = try JSONEncoder().encode(Box(intent: .known(.roll)))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"intent":"ROLL"}"#)
    }

    func test_graphQLEnum_roundTrip_known() throws {
        let box = Box(intent: .known(.vibe))
        let back = try JSONDecoder().decode(Box.self, from: JSONEncoder().encode(box))
        XCTAssertEqual(back, box)
    }

    func test_graphQLEnum_decodesUnknown_doesNotThrow() throws {
        let back = try JSONDecoder().decode(Box.self, from: Data(#"{"intent":"PORTAL"}"#.utf8))
        XCTAssertEqual(back.intent, .unknown("PORTAL"))
    }

    func test_graphQLEnum_unknown_roundTrips() throws {
        let box = Box(intent: .unknown("NEW_CASE"))
        let back = try JSONDecoder().decode(Box.self, from: JSONEncoder().encode(box))
        XCTAssertEqual(back, box)
    }

    // MARK: - JSONValue

    func test_jsonValue_roundTrip_mixed() throws {
        let v: JSONValue = .object([
            "s": .string("hi"),
            "i": .int(42),
            "neg": .int(-7),
            "d": .double(1.5),
            "b": .bool(true),
            "n": .null,
            "arr": .array([.int(1), .string("x"), .bool(false)]),
            "nested": .object(["k": .double(-0.25)]),
        ])
        let back = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v))
        XCTAssertEqual(back, v)
    }

    func test_jsonValue_decodesRawJSON() throws {
        let v = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a":[1,2.5,"x",true,null]}"#.utf8))
        XCTAssertEqual(v, .object(["a": .array([.int(1), .double(2.5), .string("x"), .bool(true), .null])]))
    }

    // Documented caveat: a raw JSONValue whole-number double re-decodes as .int
    // (JSON int/double ambiguity). Concrete `Double` fields are unaffected.
    func test_jsonValue_wholeDouble_roundTripsToInt() throws {
        let back = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(JSONValue.object(["x": .double(100.0)])))
        XCTAssertEqual(back, .object(["x": .int(100)]))
    }

    // A concrete Double field round-trips a whole value correctly (decodes against Double).
    func test_concreteDouble_wholeValue_roundTripsAsDouble() throws {
        struct D: Codable, Equatable { let x: Double }
        let back = try JSONDecoder().decode(D.self, from: JSONEncoder().encode(D(x: 100.0)))
        XCTAssertEqual(back.x, 100.0)
    }
}
