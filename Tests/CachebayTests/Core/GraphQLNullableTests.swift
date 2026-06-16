import XCTest
@testable import Cachebay

/// `GraphQLNullable<T>` is the tri-state wrapper the typed codegen uses for
/// **nullable input** positions (input-object fields + operation variables).
///
/// GraphQL distinguishes three states for a nullable input, and resolvers rely
/// on the difference (spec §"Input Coercion": *"there is a semantic difference
/// between the explicitly provided value null versus having not provided a
/// value"*):
///
///   • **omit**  — field absent from the wire → "leave untouched"   → `.none` / `nil`
///   • **null**  — field present as JSON null  → "clear / set null"  → `.null`
///   • **value** — field present with a value                       → `.some(x)`
///
/// A plain Swift `Optional` collapses omit and explicit-null into one state, so
/// it can only ever serialize explicit-null — never omit. This wrapper restores
/// the distinction, mirroring Apollo's `GraphQLNullable`.
final class GraphQLNullableTests: XCTestCase {

    enum SampleEnum: String, Sendable, Hashable, CaseIterable {
        case asc = "ASC"
        case desc = "DESC"
    }

    // MARK: - The three states are distinct

    func test_none_null_some_areDistinct() {
        let omit: GraphQLNullable<String> = .none
        let null: GraphQLNullable<String> = .null
        let some: GraphQLNullable<String> = .some("x")
        XCTAssertNotEqual(omit, null)
        XCTAssertNotEqual(omit, some)
        XCTAssertNotEqual(null, some)
    }

    // MARK: - nil literal means OMIT (the default-argument ergonomic)

    func test_nilLiteral_isNone_notNull() {
        let v: GraphQLNullable<String> = nil
        XCTAssertEqual(v, .none)
        XCTAssertNotEqual(v, .null)  // crucial: `nil` is omit, NOT explicit null
    }

    // MARK: - Literal conformances wrap into .some

    func test_stringLiteral_isSome() {
        let v: GraphQLNullable<String> = "hello"
        XCTAssertEqual(v, .some("hello"))
    }

    func test_integerLiteral_isSome() {
        let v: GraphQLNullable<Int> = 42
        XCTAssertEqual(v, .some(42))
    }

    func test_floatLiteral_isSome() {
        let v: GraphQLNullable<Double> = 1.5
        XCTAssertEqual(v, .some(1.5))
    }

    func test_booleanLiteral_isSome() {
        let v: GraphQLNullable<Bool> = true
        XCTAssertEqual(v, .some(true))
    }

    func test_arrayLiteral_isSome() {
        let v: GraphQLNullable<[String]> = ["a", "b"]
        XCTAssertEqual(v, .some(["a", "b"]))
    }

    // MARK: - __cachebayEncode: omit / null / value

    func test_encode_none_omits_returnsNil() {
        let v: GraphQLNullable<String> = .none
        XCTAssertNil(v.__cachebayEncode { .string($0) })
    }

    func test_encode_null_returnsExplicitNull() {
        let v: GraphQLNullable<String> = .null
        XCTAssertEqual(v.__cachebayEncode { .string($0) }, .null)
    }

    func test_encode_some_appliesTransform() {
        let v: GraphQLNullable<String> = .some("x")
        XCTAssertEqual(v.__cachebayEncode { .string($0) }, .string("x"))
    }

    func test_encode_some_enumViaRawValue() {
        let v: GraphQLNullable<SampleEnum> = .some(.desc)
        XCTAssertEqual(v.__cachebayEncode { .string($0.rawValue) }, .string("DESC"))
    }

    /// The whole point: a non-nil caller value reaches the wire as a value, an
    /// explicit `.null` reaches it as null, and `.none` is *absent* — so a
    /// serializer that skips nil results omits the key entirely.
    func test_encode_drivesOmitVsNullVsValue() {
        func wire(_ v: GraphQLNullable<Int>) -> JSONValue? {
            v.__cachebayEncode { .int(Int64($0)) }
        }
        XCTAssertNil(wire(.none))  // key omitted
        XCTAssertEqual(wire(.null), .null)  // key present, null
        XCTAssertEqual(wire(.some(7)), .int(7))  // key present, value
    }

    // MARK: - Optional bridge (nil → omit, value → some; never .null)

    func test_optionalBridge_nilIsOmit_valueIsSome() {
        XCTAssertEqual(GraphQLNullable<String>(Optional<String>.none), .none)
        XCTAssertEqual(GraphQLNullable<String>(Optional("x")), .some("x"))
    }

    func test_optionalBridge_roundTripsThroughEncoderAsOmitOrValue() {
        // A nil Optional bridges to OMIT — the serializer skips the key.
        XCTAssertNil(GraphQLNullable<String>(Optional<String>.none).__cachebayEncode { .string($0) })
        XCTAssertEqual(GraphQLNullable<String>(Optional("y")).__cachebayEncode { .string($0) }, .string("y"))
    }

    // MARK: - Hashable

    func test_hashable_distinguishesStates() {
        let set: Set<GraphQLNullable<String>> = [.none, .null, .some("a"), .some("a")]
        XCTAssertEqual(set.count, 3)
    }
}
