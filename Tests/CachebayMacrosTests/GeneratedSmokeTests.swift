import XCTest
import Cachebay

// WS6 smoke test: the files under GeneratedSmoke/ are REAL `cachebay-cli --typed`
// output (regenerated from the demo's SpellDetail query + SpellFields fragment).
// They must compile (proves the typed emitter -> macros pipeline) AND decode.

final class GeneratedSmokeTests: XCTestCase {
    func test_generated_operation_decodes_via_fragment_spread() {
        // Materialized root: `spell` is a SpellFields.Data (fragment spread).
        let dict: [String: JSONValue] = [
            "spell": .object([
                "__typename": .string("Spell"),
                "id": .string("s1"),
                "name": .string("Lumos"),
                "category": .string("Charm"),
                "effect": .string("Creates light"),
                // creator / light / imageUrl / wikiUrl omitted -> optionals
            ]),
        ]
        let data = SpellDetail.Data(_dataDict: dict)
        XCTAssertEqual(data?.spell?.name, "Lumos")
        XCTAssertEqual(data?.spell?.category, "Charm")
        XCTAssertNil(data?.spell?.creator)        // optional, absent
        XCTAssertEqual(data?.spell?.id, "s1")     // Identifiable via lifted id
    }

    func test_generated_fragment_typename_guard() {
        // A wrong-typename record fails the fragment Data's @CachebayData guard.
        let wrong: [String: JSONValue] = [
            "__typename": .string("Potion"), "id": .string("x"),
            "name": .string("n"), "category": .string("c"), "effect": .string("e"),
        ]
        XCTAssertNil(SpellFields.Data(_dataDict: wrong))

        let right: [String: JSONValue] = [
            "__typename": .string("Spell"), "id": .string("s1"),
            "name": .string("Lumos"), "category": .string("Charm"), "effect": .string("light"),
        ]
        XCTAssertEqual(SpellFields.Data(_dataDict: right)?.name, "Lumos")
    }

    // The generated operation conforms to the typed CachebayOperation protocol.
    func test_generated_conforms_to_CachebayOperation() {
        func accept<Op: CachebayOperation>(_ op: Op.Type) {}
        accept(SpellDetail.self)
        XCTAssertEqual(SpellDetail.operationName, "SpellDetail")
    }
}
