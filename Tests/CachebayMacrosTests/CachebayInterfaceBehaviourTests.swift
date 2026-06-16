import XCTest
import Foundation
import Cachebay

/// WS2 / Gate wk2 — the sum-type interface enum and §3.1 `.unknown` correctness.
final class CachebayInterfaceBehaviourTests: XCTestCase {

    private func videoRecord(id: String = "v1") -> [String: JSONValue] {
        [
            "__typename": .string("VideoElement"),
            "id": .string(id),
            "url": .string("https://x.com/\(id).mp4"),
            "duration": .double(4),
        ]
    }

    // Known typename decodes to its concrete variant; variant fields are accessible.
    func test_decode_knownVariant() {
        let e = Element(_dataDict: videoRecord())
        guard case .video(let v) = e else { return XCTFail("expected .video, got \(String(describing: e))") }
        XCTAssertEqual(v.url.absoluteString, "https://x.com/v1.mp4")
        XCTAssertEqual(v.duration, 4)
    }

    // Audio variant dispatch (proves typename-directed dispatch, not just first-match).
    func test_decode_audioVariant() {
        let e = Element(_dataDict: [
            "__typename": .string("AudioElement"),
            "id": .string("a1"),
            "waveformURL": .string("https://x.com/a1.wav"),
        ])
        guard case .audio(let a) = e else { return XCTFail("expected .audio") }
        XCTAssertEqual(a.waveformURL.absoluteString, "https://x.com/a1.wav")
    }

    // §3.1 — unrecognized typename -> .unknown(Shared), carrying interface-level fields.
    func test_decode_unknownVariant_carriesSharedFields() {
        guard
            let e = Element(_dataDict: [
                "__typename": .string("PdfElement"),  // not narrowed in this query
                "id": .string("p1"),
            ])
        else { return XCTFail("expected a decoded element") }
        guard case .unknown(let s) = e else { return XCTFail("expected .unknown") }
        XCTAssertEqual(s.id, "p1")
        XCTAssertEqual(s.__typename, "PdfElement")
        // Lifted accessor works on .unknown — no optional, no force-unwrap.
        XCTAssertEqual(e.id, "p1")
    }

    // Lifted shared accessor works uniformly across every variant.
    func test_liftedAccessor_acrossVariants() {
        XCTAssertEqual(Element(_dataDict: videoRecord(id: "v9"))?.id, "v9")
        XCTAssertEqual(
            Element(_dataDict: [
                "__typename": .string("AudioElement"), "id": .string("a9"),
                "waveformURL": .string("https://x.com/a9.wav"),
            ])?.id, "a9")
        XCTAssertEqual(
            Element(_dataDict: [
                "__typename": .string("ZzzElement"), "id": .string("u9"),
            ])?.id, "u9")
    }

    // §7 — a KNOWN typename whose required field is missing is a record MISS,
    // NOT a silent degrade to .unknown.
    func test_knownTypename_missingRequired_isMiss_notUnknown() {
        let e = Element(_dataDict: [
            "__typename": .string("VideoElement"),
            "id": .string("v1"),
            // no url / duration
        ])
        XCTAssertNil(e)
    }

    // Exhaustive switch over the sum type compiles and dispatches.
    func test_exhaustiveSwitch() {
        func describe(_ e: Element) -> String {
            switch e {
            case .video(let v): return "video:\(v.id)"
            case .audio(let a): return "audio:\(a.id)"
            case .image(let i): return "image:\(i.id)"
            case .unknown(let s): return "unknown:\(s.id)"
            }
        }
        XCTAssertEqual(describe(Element(_dataDict: videoRecord(id: "v1"))!), "video:v1")
    }

    // BUG 1 — the interface enum must emit `__cachebayFieldNames` (one entry per
    // lifted shared accessor), so an interface-rooted fragment's CLI-emitted
    // `Data.__cachebayFieldNames` resolves and KeyPath patching of shared fields works.
    func test_interfaceData_emitsFieldNamesForSharedFields() {
        let names = Element.__cachebayFieldNames
        XCTAssertEqual(names[\Element.id], "id")
        XCTAssertEqual(names[\Element.__typename], "__typename")
        XCTAssertEqual(names.count, 2)  // only the Shared (interface-level) fields
    }

    // Round-trip through __dataDict() and re-decode to an equal value (Equatable payoff).
    func test_roundTrip_and_equatable() {
        let e1 = Element(_dataDict: videoRecord(id: "v5"))!
        let e2 = Element(_dataDict: e1.__dataDict())!
        XCTAssertEqual(e1, e2)

        let img = Element(_dataDict: [
            "__typename": .string("ImageElement"), "id": .string("i1"),
            "thumbnailURL": .string("https://x.com/i1.png"),
        ])!
        XCTAssertNotEqual(e1, img)
    }
}
