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

    // WS1 enum-output fix: a selection-set enum field is generated as
    // `Cachebay.GraphQLEnum<Enum>` (SpellEnumDetail.graphql.swift is REAL CLI
    // output), and the full CLI -> macro -> runtime pipeline decodes it. Proves
    // known values land in `.known`, unknown server values in `.unknown`, and a
    // plain `String!` field stays a `String`.
    func test_generated_enum_output_decodes_known_and_unknown() {
        let dict: [String: JSONValue] = [
            "spell": .object([
                "__typename": .string("Spell"),
                "id": .string("s1"),
                "name": .string("Lumos"),
                "kind": .string("CHARM"),          // known -> .known(.charm)
                "mood": .string("NOSUCHMOOD"),     // unknown nullable enum -> .unknown
                "state": .string("active"),        // plain String! — stays String
                "tags": .array([.string("OFFENSIVE"), .string("MYSTERY"), .string("UTILITY")]),
            ]),
        ]
        let spell = SpellEnumDetail.Data(_dataDict: dict)?.spell
        XCTAssertNotNil(spell)
        XCTAssertEqual(spell?.kind, .known(.charm))
        XCTAssertEqual(spell?.kind.value, .charm)
        XCTAssertEqual(spell?.mood, .unknown("NOSUCHMOOD"))
        XCTAssertEqual(spell?.state, "active")
        XCTAssertEqual(spell?.tags, [.known(.offensive), .unknown("MYSTERY"), .known(.utility)])
    }

    // BUG 1 + BUG 2: a REAL interface-rooted fragment (ElementFields.graphql.swift,
    // root Data is a @CachebayInterface enum) must compile and decode. The mere
    // compilation of this fixture proves: (1) the interface macro emits
    // `Data.__cachebayFieldNames` (the fragment references it at line 119), and
    // (2) the shared `derivatives` sub-selection is hoisted to one enum-scope
    // `Derivatives` so the lifted accessor `var derivatives: [Derivatives]`
    // resolves and unifies across variants.
    func test_generated_interfaceFragment_decodesAndLiftsSharedFields() {
        let video: [String: JSONValue] = [
            "__typename": .string("VideoElement"),
            "id": .string("e1"),
            "url": .string("https://x.com/e1.mp4"),
            "derivatives": .array([
                .object(["__typename": .string("Cook"), "id": .string("c1"), "key": .string("k1")]),
                .object(["__typename": .string("Cook"), "id": .string("c2"), "key": .string("k2")]),
            ]),
        ]
        let e = ElementFields.Data(_dataDict: video)
        guard case .videoElement(let v) = e else { return XCTFail("expected .videoElement, got \(String(describing: e))") }
        XCTAssertEqual(v.url, "https://x.com/e1.mp4")
        // Lifted shared accessors resolve across variants (BUG 2: one `Derivatives`).
        XCTAssertEqual(e?.id, "e1")
        XCTAssertEqual(e?.derivatives.map(\.key), ["k1", "k2"])
    }

    func test_generated_interfaceFragment_unknownVariant_keepsSharedSubSelection() {
        // Unrecognized typename -> .unknown(Shared); the hoisted shared `derivatives`
        // is still carried (proving Shared and the hoisted type compose).
        let pdf: [String: JSONValue] = [
            "__typename": .string("PdfElement"),   // not narrowed in this fragment
            "id": .string("e9"),
            "derivatives": .array([
                .object(["__typename": .string("Cook"), "id": .string("c9"), "key": .string("k9")]),
            ]),
        ]
        let e = ElementFields.Data(_dataDict: pdf)
        guard case .unknown(let s) = e else { return XCTFail("expected .unknown") }
        XCTAssertEqual(s.id, "e9")
        XCTAssertEqual(e?.derivatives.first?.key, "k9")
    }

    func test_generated_interfaceFragment_emitsFieldNames() {
        // BUG 1 directly: the member the CLI references must resolve, with the
        // interface's shared fields present.
        let names = ElementFields.Data.__cachebayFieldNames
        XCTAssertEqual(names[\ElementFields.Data.id], "id")
        XCTAssertEqual(names[\ElementFields.Data.__typename], "__typename")
        XCTAssertEqual(names[\ElementFields.Data.derivatives], "derivatives")
    }

    // Codable on generated response structs (real CLI output): decode a
    // server-shaped payload, round-trip, and confirm GraphQLEnum (known + unknown)
    // survives. SpellEnumDetail.Data + .Spell are concrete → Codable.
    func test_generated_codable_roundTrip() throws {
        let json = Data(#"""
        {"spell":{"__typename":"Spell","id":"s1","name":"Lumos","kind":"CHARM","mood":"HEX","state":"active","tags":["OFFENSIVE","MYSTERY"]}}
        """#.utf8)
        let data = try JSONDecoder().decode(SpellEnumDetail.Data.self, from: json)
        XCTAssertEqual(data.spell?.name, "Lumos")
        XCTAssertEqual(data.spell?.kind, .known(.charm))
        XCTAssertEqual(data.spell?.mood, .known(.hex))
        XCTAssertEqual(data.spell?.tags, [.known(.offensive), .unknown("MYSTERY")])
        // Encode → decode round-trips to an equal value.
        let back = try JSONDecoder().decode(SpellEnumDetail.Data.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(back, data)
    }

    // The crux of choosing GraphQLEnum<T>: an unknown value on a NON-NULL enum
    // field (`kind: SpellKind!`) must NOT fail the whole record — otherwise a new
    // server enum case would drop the entire row from the UI.
    func test_generated_unknown_on_nonnull_enum_does_not_miss_record() {
        let dict: [String: JSONValue] = [
            "spell": .object([
                "__typename": .string("Spell"),
                "id": .string("s1"),
                "name": .string("Lumos"),
                "kind": .string("PORTAL"),         // server added a case this build doesn't know
                "state": .string("active"),
                "tags": .array([]),
                // mood omitted -> optional nil
            ]),
        ]
        let spell = SpellEnumDetail.Data(_dataDict: dict)?.spell
        XCTAssertNotNil(spell, "unknown value on a non-null enum must NOT fail the record")
        XCTAssertEqual(spell?.kind, .unknown("PORTAL"))
        XCTAssertNil(spell?.mood)
    }
}
