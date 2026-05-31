import XCTest
import Foundation
import Cachebay

/// Behavioural layer: compile the macro expansion and exercise it.
final class CachebayDataBehaviourTests: XCTestCase {

    // B9 — memberwise init defaults (proposal §6): __typename, @CachebayDefault, optional.
    func test_memberwiseInit_defaults() {
        let v = Video(id: "v1", url: URL(string: "https://x.com/v.mp4")!, duration: 5)
        XCTAssertEqual(v.__typename, "VideoElement")
        XCTAssertEqual(v.id, "v1")
        XCTAssertEqual(v.rank, "a0")          // @CachebayDefault("a0")
        XCTAssertNil(v.intent)                // optional -> nil
        XCTAssertEqual(v.duration, 5)
    }

    // B10 — eager dict round-trip: init?(_dataDict:) then __dataDict().
    func test_dictInit_roundTrip() {
        let dict: [String: JSONValue] = [
            "__typename": .string("VideoElement"),
            "id": .string("v1"),
            "url": .string("https://x.com/v.mp4"),
            "duration": .double(12.5),
            "rank": .string("b2"),
            "intent": .string("hook"),
        ]
        let v = Video(_dataDict: dict)
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.id, "v1")
        XCTAssertEqual(v?.rank, "b2")
        XCTAssertEqual(v?.intent, "hook")
        XCTAssertEqual(v?.url.absoluteString, "https://x.com/v.mp4")

        // Round-trip back to a dict and re-decode to an equal value.
        let back = v!.__dataDict()
        XCTAssertEqual(back["id"], .string("v1"))
        XCTAssertEqual(back["rank"], .string("b2"))
        XCTAssertEqual(Video(_dataDict: back), v)
    }

    // B11 — missing required field -> whole-record miss (nil). (D3 lean, §7.)
    func test_dictInit_missingRequired_returnsNil() {
        let dict: [String: JSONValue] = [
            "__typename": .string("VideoElement"),
            // no id
            "url": .string("https://x.com/v.mp4"),
            "duration": .double(1),
        ]
        XCTAssertNil(Video(_dataDict: dict))
    }

    // B11b — wrong __typename -> nil (so an interface can dispatch by trying variants).
    func test_dictInit_wrongTypename_returnsNil() {
        let dict: [String: JSONValue] = [
            "__typename": .string("AudioElement"),
            "id": .string("v1"),
            "url": .string("https://x.com/v.mp4"),
            "duration": .double(1),
        ]
        XCTAssertNil(Video(_dataDict: dict))
    }

    // §7 — optional malformed -> nil (NOT a record miss); required custom-scalar malformed -> miss.
    func test_failureSemantics() {
        // Optional intent is malformed (number, not string) -> decodes to nil, record survives.
        let okDict: [String: JSONValue] = [
            "__typename": .string("VideoElement"),
            "id": .string("v1"),
            "url": .string("https://x.com/v.mp4"),
            "duration": .double(1),
            "rank": .string("a0"),
            "intent": .int(99),
        ]
        let v = Video(_dataDict: okDict)
        XCTAssertNotNil(v)
        XCTAssertNil(v?.intent)

        // Required URL is malformed -> whole-record miss.
        let badURL: [String: JSONValue] = [
            "__typename": .string("VideoElement"),
            "id": .string("v1"),
            "url": .int(7),
            "duration": .double(1),
        ]
        XCTAssertNil(Video(_dataDict: badURL))
    }

    // B10c — nested list + optional nested object decode uniformly via CachebayValue.
    func test_nestedAndList_decode() {
        let dict: [String: JSONValue] = [
            "__typename": .string("Cook"),
            "id": .string("c1"),
            "title": .string("Pasta"),
            "tags": .array([
                .object(["__typename": .string("Tag"), "id": .string("t1"), "label": .string("dinner")]),
                .object(["__typename": .string("Tag"), "id": .string("t2"), "label": .string("quick")]),
            ]),
            "hero": .object([
                "__typename": .string("VideoElement"), "id": .string("v1"),
                "url": .string("https://x.com/v.mp4"), "duration": .double(3),
                "rank": .string("c3"),
            ]),
        ]
        let cook = Cook(_dataDict: dict)
        XCTAssertEqual(cook?.tags.count, 2)
        XCTAssertEqual(cook?.tags.first?.label, "dinner")
        XCTAssertEqual(cook?.hero?.id, "v1")
        XCTAssertEqual(cook?.hero?.rank, "c3")        // from the record (decode is strict)
    }

    // D6 — `@CachebayDefault` is a CONSTRUCTION default (§6) only. The read/decode
    // path stays strict: a missing required field is a record miss even if it has a
    // construction default. (Selected fields are always present on the wire; a missing
    // one is genuine drift -> strictOK=false -> refetch.) Confirm at gate wk2.
    func test_dictInit_missingDefaultedField_isMiss() {
        let dict: [String: JSONValue] = [
            "__typename": .string("VideoElement"),
            "id": .string("v1"),
            "url": .string("https://x.com/v.mp4"),
            "duration": .double(1),
            // no "rank" — has a @CachebayDefault, but decode is strict
        ]
        XCTAssertNil(Video(_dataDict: dict))
    }

    // B14 — the architectural payoff: cheap, correct Equatable/Hashable from stored lets.
    func test_equatable_hashable_payoff() {
        let a = Video(id: "v1", url: URL(string: "https://x.com/v.mp4")!, duration: 5)
        let b = Video(id: "v1", url: URL(string: "https://x.com/v.mp4")!, duration: 5)
        let c = Video(id: "v2", url: URL(string: "https://x.com/v.mp4")!, duration: 5)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
        let set: Set<Video> = [a, b, c]
        XCTAssertEqual(set.count, 2)   // a == b collapse
    }
}
