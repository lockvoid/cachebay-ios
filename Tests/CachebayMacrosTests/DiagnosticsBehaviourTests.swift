import XCTest
import Foundation
import Cachebay

/// The typed-decode path used to fail in total silence: a required field missing,
/// a `__typename` mismatch, or one bad element fail-all'ing a whole list would
/// return `nil` with no log, blanking the UI. (This is what made the ferment-cuts
/// empty-list-after-create bug invisible — 29 raw edges materialized fine, then the
/// typed decode silently dropped them to 0.)
///
/// `CachebayDiagnostics.decodeMiss` now surfaces every such drop through the client's
/// logger. These tests pin that the drop is observable and names its cause.
final class DiagnosticsBehaviourTests: XCTestCase {
    /// Reference box so the (non-`@Sendable`) sink closure captures a class, not the
    /// MainActor-isolated test case.
    private final class Captured: @unchecked Sendable { var lines: [String] = [] }
    private var box = Captured()
    private var captured: [String] { box.lines }

    override func setUp() {
        super.setUp()
        box = Captured()
        let box = self.box
        CachebayDiagnostics.sink = { msg in box.lines.append(msg) }
    }

    override func tearDown() {
        CachebayDiagnostics.sink = nil
        box = Captured()
        super.tearDown()
    }

    private func videoDict(id: String? = "v1", typename: String = "VideoElement") -> JSONValue {
        var o: [String: JSONValue] = [
            "__typename": .string(typename),
            "url": .string("https://x.com/v.mp4"),
            "duration": .double(5),
        ]
        if let id { o["id"] = .string(id) }
        return .object(o)
    }

    // A required field that fails to decode names itself (instead of vanishing).
    func test_missingRequiredField_emitsDecodeMiss_namingField() {
        guard case .object(let d) = videoDict(id: nil) else { return XCTFail("setup") }
        XCTAssertNil(Element.Video(_dataDict: d))
        XCTAssertTrue(
            captured.contains { $0.contains("Video") && $0.contains("required field 'id'") },
            "expected a decode-miss naming Video.id, got: \(captured)"
        )
    }

    // A __typename mismatch names the expected type (the optimistic-edge case).
    func test_wrongTypename_emitsDecodeMiss_namingExpectedType() {
        guard case .object(let d) = videoDict(typename: "AudioElement") else { return XCTFail("setup") }
        XCTAssertNil(Element.Video(_dataDict: d))
        XCTAssertTrue(
            captured.contains { $0.contains("__typename did not match expected 'VideoElement'") },
            "expected a __typename decode-miss, got: \(captured)"
        )
    }

    // THE ferment-cuts bug, at the type level: a list where one element fails to
    // decode is dropped *whole* — and that must be loud, not silent.
    func test_listWithOneUndecodableElement_emitsDecodeMiss_andDropsWholeList() {
        let list: JSONValue = .array([videoDict(id: "ok"), videoDict(id: nil)])
        XCTAssertNil([Element.Video](cachebayJSON: list), "fail-all: one bad element nils the list")
        // The list-level drop is reported...
        XCTAssertTrue(
            captured.contains { $0.contains("whole list dropped") && $0.contains("element 1 of 2") },
            "expected a list-dropped decode-miss, got: \(captured)"
        )
        // ...and the underlying field cause is reported too.
        XCTAssertTrue(
            captured.contains { $0.contains("required field 'id'") },
            "expected the element's field cause, got: \(captured)"
        )
    }

    // No sink installed -> zero cost, no crash (the reason autoclosure isn't run).
    func test_noSink_isSilentAndSafe() {
        CachebayDiagnostics.sink = nil
        guard case .object(let d) = videoDict(id: nil) else { return XCTFail("setup") }
        XCTAssertNil(Element.Video(_dataDict: d))
        XCTAssertTrue(captured.isEmpty)
    }
}
