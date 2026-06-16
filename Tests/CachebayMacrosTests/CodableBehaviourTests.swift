import XCTest
import Foundation
import Cachebay

/// Exercises the `Codable` that `@CachebayData` emits when a value opts in —
/// the local persistence round-trip (analyzer writes a blob, reader decodes it).
final class CodableBehaviourTests: XCTestCase {

    private func sample() -> CodableAudioEvents {
        CodableAudioEvents(
            id: "ae1",
            rank: "b2",
            bpm: 128.0,
            kind: .known(.audio),
            summary: "two drops",
            tags: ["drop", "build"],
            beatGrid: CodableBeatGrid(id: "bg1", coverage: 0.97, downbeats: [0.5, 1.0, 1.5])
        )
    }

    // Full round-trip through Foundation JSON (encode → decode → equal).
    func test_roundTrip_viaFoundationJSON() throws {
        let v = sample()
        let data = try JSONEncoder().encode(v)
        let back = try JSONDecoder().decode(CodableAudioEvents.self, from: data)
        XCTAssertEqual(back, v)
    }

    // Wire keys + explicit null for nil optionals + GraphQLEnum as raw string.
    func test_encode_usesWireKeys_andRawEnum() throws {
        let v = CodableAudioEvents(id: "ae1", bpm: 1, kind: .known(.video), summary: nil, tags: [], beatGrid: nil)
        let s = String(decoding: try JSONEncoder().encode(v), as: UTF8.self)
        XCTAssertTrue(s.contains(#""__typename":"AudioEvents""#), s)
        XCTAssertTrue(s.contains(#""rank":"a0""#), s)  // @CachebayDefault memberwise value
        XCTAssertTrue(s.contains(#""kind":"VIDEO""#), s)  // GraphQLEnum → raw string
        XCTAssertTrue(s.contains(#""summary":null"#), s)  // nil optional → explicit null
        XCTAssertTrue(s.contains(#""beatGrid":null"#), s)
    }

    // Schema evolution: a blob written before `rank`/`summary`/`beatGrid` existed
    // (those keys absent) still decodes — `@CachebayDefault` is honored, optionals
    // tolerate absence. This is the no-recompute-storm guarantee.
    func test_decode_missingDefaultedAndOptionalFields_honorsDefaults() throws {
        let json = #"""
            {"__typename":"AudioEvents","id":"ae1","bpm":120,"kind":"AUDIO","tags":["x"]}
            """#
        let back = try JSONDecoder().decode(CodableAudioEvents.self, from: Data(json.utf8))
        XCTAssertEqual(back.rank, "a0")  // @CachebayDefault honored on absence
        XCTAssertNil(back.summary)  // optional absent → nil
        XCTAssertNil(back.beatGrid)  // optional nested absent → nil
        XCTAssertEqual(back.bpm, 120)
        XCTAssertEqual(back.kind, .known(.audio))
    }

    // Forward-compat enum: an unknown wire value decodes (does not throw).
    func test_decode_unknownEnumValue_survives() throws {
        let json = #"{"__typename":"AudioEvents","id":"ae1","bpm":1,"kind":"HOLOGRAM","tags":[]}"#
        let back = try JSONDecoder().decode(CodableAudioEvents.self, from: Data(json.utf8))
        XCTAssertEqual(back.kind, .unknown("HOLOGRAM"))
    }

    // A self-produced blob and a server-shaped payload are interchangeable: a
    // payload with the same wire keys decodes into the model.
    func test_decode_serverShapedPayload() throws {
        let json = #"""
            {"__typename":"AudioEvents","id":"ae1","rank":"c3","bpm":90.5,"kind":"AUDIO",
             "summary":"intro","tags":["a","b"],
             "beatGrid":{"__typename":"BeatGrid","id":"bg9","coverage":1.0,"downbeats":[0.25,0.5]}}
            """#
        let back = try JSONDecoder().decode(CodableAudioEvents.self, from: Data(json.utf8))
        XCTAssertEqual(back.rank, "c3")
        XCTAssertEqual(back.beatGrid?.id, "bg9")
        XCTAssertEqual(back.beatGrid?.downbeats, [0.25, 0.5])
    }
}
