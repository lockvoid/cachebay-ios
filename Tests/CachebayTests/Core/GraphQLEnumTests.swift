import XCTest
@testable import Cachebay

/// `GraphQLEnum<T>` is the forward-compatible wrapper the typed codegen uses for
/// **output** enum fields (selection sets). The generated enum itself stays a
/// clean closed `enum Foo: String, CaseIterable` — usable verbatim for *input*
/// fields — while the wrapper absorbs server values the client build doesn't yet
/// know via `.unknown(rawValue)`, so decode is **total** and a new server enum
/// case never fails the whole record (the footgun a closed enum + lenient
/// decoder would hit on a non-null field).
///
/// House rule (deliberate, see CHANGELOG): interfaces carry `.unknown(Shared)`
/// *inline* on the generated `@CachebayInterface` enum; enums carry unknown via
/// this *outer* `GraphQLEnum<T>` wrapper. Two idioms, one reason each.
final class GraphQLEnumTests: XCTestCase {

    /// Mirrors a generated enum: closed, `String`-backed, `CaseIterable`.
    enum SampleIntent: String, Sendable, Hashable, CaseIterable {
        case roll = "ROLL"
        case story = "STORY"
        case vibe = "VIBE"
    }

    // MARK: - Construction

    func test_init_knownRawValue_isKnown() {
        XCTAssertEqual(GraphQLEnum<SampleIntent>("ROLL"), .known(.roll))
        XCTAssertEqual(GraphQLEnum<SampleIntent>("VIBE").value, .vibe)
    }

    func test_init_unknownRawValue_isUnknown() {
        let g = GraphQLEnum<SampleIntent>("PORTRAIT")  // server added a case we don't know
        XCTAssertEqual(g, .unknown("PORTRAIT"))
        XCTAssertNil(g.value)                          // `.value` is nil for unknown
        XCTAssertEqual(g.rawValue, "PORTRAIT")         // raw is preserved
    }

    func test_rawValue_roundTrips_forBothCases() {
        XCTAssertEqual(GraphQLEnum<SampleIntent>.known(.story).rawValue, "STORY")
        XCTAssertEqual(GraphQLEnum<SampleIntent>.unknown("X").rawValue, "X")
    }

    // MARK: - CachebayValue decode/encode (the macro decode substrate)

    func test_decode_knownString() {
        let g = GraphQLEnum<SampleIntent>(cachebayJSON: .string("STORY"))
        XCTAssertEqual(g, .known(.story))
    }

    func test_decode_unknownString_doesNotFail() {
        // The whole point: an unseen server value decodes, it does NOT return nil.
        let g = GraphQLEnum<SampleIntent>(cachebayJSON: .string("HOLOGRAM"))
        XCTAssertEqual(g, .unknown("HOLOGRAM"))
    }

    func test_decode_nonString_isRecordMiss() {
        // A number / null / missing where an enum string was required is genuine
        // drift, not a forward-compat case -> nil (required-field miss), matching
        // the built-in scalar contract.
        XCTAssertNil(GraphQLEnum<SampleIntent>(cachebayJSON: .int(7)))
        XCTAssertNil(GraphQLEnum<SampleIntent>(cachebayJSON: .null))
        XCTAssertNil(GraphQLEnum<SampleIntent>(cachebayJSON: .undefined))
    }

    func test_encode_roundTrip() {
        let g = GraphQLEnum<SampleIntent>.known(.vibe)
        XCTAssertEqual(g.cachebayJSON, .string("VIBE"))
        XCTAssertEqual(GraphQLEnum<SampleIntent>(cachebayJSON: g.cachebayJSON), g)

        let u = GraphQLEnum<SampleIntent>.unknown("NEW")
        XCTAssertEqual(u.cachebayJSON, .string("NEW"))
        XCTAssertEqual(GraphQLEnum<SampleIntent>(cachebayJSON: u.cachebayJSON), u)
    }

    // MARK: - Composition through the Optional / Array CachebayValue wrappers
    // (reviewer ask: prove the generic composes, don't just assert it.)

    func test_optional_composition() {
        // nullable enum field: `GraphQLEnum<T>?`
        XCTAssertEqual(
            Optional<GraphQLEnum<SampleIntent>>(cachebayJSON: .string("ROLL")),
            .some(.known(.roll))
        )
        // missing / null -> .none (never a record miss for optional)
        XCTAssertEqual(Optional<GraphQLEnum<SampleIntent>>(cachebayJSON: .null), .some(.none))
        XCTAssertEqual(Optional<GraphQLEnum<SampleIntent>>(cachebayJSON: .undefined), .some(.none))
        // unknown string still decodes (to .some(.unknown))
        XCTAssertEqual(
            Optional<GraphQLEnum<SampleIntent>>(cachebayJSON: .string("ZZZ")),
            .some(.unknown("ZZZ"))
        )
    }

    func test_array_composition() {
        let json = JSONValue.array([.string("ROLL"), .string("MYSTERY"), .string("VIBE")])
        let decoded = [GraphQLEnum<SampleIntent>](cachebayJSON: json)
        XCTAssertEqual(decoded, [.known(.roll), .unknown("MYSTERY"), .known(.vibe)])
        // round-trips back to the same JSON array
        XCTAssertEqual(decoded?.cachebayJSON, json)
    }

    // MARK: - Pattern-match ergonomics

    func test_matches_knownCase() {
        let g = GraphQLEnum<SampleIntent>.known(.roll)
        XCTAssertTrue(g == .roll)        // == against the underlying case
        XCTAssertFalse(g == .vibe)
        XCTAssertFalse(GraphQLEnum<SampleIntent>.unknown("ROLL") == .roll)
    }

    func test_notEquals_heterogeneous() {
        let known = GraphQLEnum<SampleIntent>.known(.roll)
        XCTAssertTrue(known != .vibe)
        XCTAssertFalse(known != .roll)
        XCTAssertTrue(SampleIntent.vibe != known)   // reversed operand order
        XCTAssertFalse(SampleIntent.roll != known)
        // unknown is != every known case.
        XCTAssertTrue(GraphQLEnum<SampleIntent>.unknown("ROLL") != .roll)
        // Agrees with the negation of ==.
        XCTAssertEqual(known != .vibe, !(known == .vibe))
        XCTAssertEqual(known != .roll, !(known == .roll))
    }

    func test_switch_matchesKnownCaseViaTilde() {
        // The terser switch form, mixing `~=` known patterns with the real
        // `.unknown` case pattern. Non-exhaustive by design -> `default` required.
        func classify(_ g: GraphQLEnum<SampleIntent>) -> String {
            switch g {
            case .roll: return "roll"                  // matched via ~=
            case .story: return "story"
            case .unknown(let raw): return "unknown:\(raw)"
            default: return "other"                    // e.g. .known(.vibe)
            }
        }
        XCTAssertEqual(classify(.known(.roll)), "roll")
        XCTAssertEqual(classify(.known(.story)), "story")
        XCTAssertEqual(classify(.known(.vibe)), "other")
        XCTAssertEqual(classify(.unknown("ZZZ")), "unknown:ZZZ")
    }

    func test_tilde_returnsFalseForUnknown() {
        XCTAssertTrue(SampleIntent.roll ~= GraphQLEnum<SampleIntent>.known(.roll))
        XCTAssertFalse(SampleIntent.vibe ~= GraphQLEnum<SampleIntent>.known(.roll))
        XCTAssertFalse(SampleIntent.roll ~= GraphQLEnum<SampleIntent>.unknown("ROLL"))
    }
}
