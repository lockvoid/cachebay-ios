import XCTest
import Cachebay

/// Runtime behaviour of the exhaustive-interface shape (`ExhaustiveElement`) — the
/// agent's red tests #2–#5. The CLI emits the cases; these prove the generated
/// shape decodes, constructs, and misses correctly at runtime.
final class ExhaustiveInterfaceBehaviourTests: XCTestCase {
    private final class Box: @unchecked Sendable { var lines: [String] = [] }

    override func tearDown() {
        CachebayDiagnostics.sink = nil
        super.tearDown()
    }

    /// #2 — a non-selected implementor decodes into its OWN typed case (not
    /// `.unknown`), interface fields populated.
    func test_nonSelectedImplementor_decodesIntoOwnCase() {
        let e = ExhaustiveElement(cachebayJSON: .object([
            "__typename": .string("AudioElement"),
            "id": .string("a1"),
        ]))
        guard case .audioElement(let audio) = e else {
            return XCTFail("expected .audioElement, got \(String(describing: e))")
        }
        XCTAssertEqual(audio.id, "a1")
        XCTAssertEqual(audio.__typename, "AudioElement")
    }

    /// #3 — a typename outside the schema snapshot → `.unknown` (forward-compat:
    /// newer server, older app).
    func test_outOfSchemaTypename_decodesIntoUnknown() {
        let e = ExhaustiveElement(cachebayJSON: .object([
            "__typename": .string("FutureElement"),
            "id": .string("f1"),
        ]))
        guard case .unknown(let shared) = e else {
            return XCTFail("expected .unknown, got \(String(describing: e))")
        }
        XCTAssertEqual(shared.__typename, "FutureElement")
    }

    /// #4 — the draft-can't-lie property: constructing a non-selected case and
    /// encoding produces the PINNED typename, with no string passed.
    func test_constructedCase_encodesWithPinnedTypename() {
        let e = ExhaustiveElement.audioElement(.init(id: "a1")) // note: no __typename argument
        let json = e.cachebayJSON
        XCTAssertEqual(json["__typename"]?.string, "AudioElement",
                       "the macro pins the typename; a draft can't carry the wrong one")
        XCTAssertEqual(json["id"]?.string, "a1")
    }

    /// #5 — a non-selected implementor record missing a required interface field
    /// fails the SAME completeness rule as `Shared` (decode → nil) and surfaces a
    /// decode miss via the strict log-floor. No new failure class.
    func test_incompleteImplementorRecord_missesAndReportsLikeShared() {
        let box = Box()
        CachebayDiagnostics.sink = { box.lines.append($0) }
        let e = ExhaustiveElement(cachebayJSON: .object([
            "__typename": .string("AudioElement"), // missing required `id`
        ]))
        XCTAssertNil(e, "a record missing a required interface field must miss, not silently degrade")
        XCTAssertTrue(box.lines.contains { $0.contains("required field 'id'") },
                      "the miss must surface via diagnostics; got \(box.lines)")
    }
}
