import XCTest
import Cachebay
@testable import CachebayAbly

/// The pure half of `AblyTransport` — mapping a decoded Ably payload to a
/// Cachebay result frame. No live Ably connection needed (the channel/lifecycle
/// half is integration-tested against a real Ably client).
final class AblyFrameMappingTests: XCTestCase {

    func test_graphqlEnvelope_splitsDataAndErrors() {
        let frame: JSONValue = .object([
            "data": .object(["projectUpdated": .object(["id": .string("p1")])]),
            "errors": .array([.object(["message": .string("partial failure")])]),
        ])
        let result = AblyTransport.result(from: frame)
        XCTAssertEqual(result.data, .object(["projectUpdated": .object(["id": .string("p1")])]))
        XCTAssertEqual(result.error?.graphqlErrors.first?.message, "partial failure")
    }

    func test_envelope_dataOnly_hasNoError() {
        let frame: JSONValue = .object(["data": .object(["x": .int(1)])])
        let result = AblyTransport.result(from: frame)
        XCTAssertEqual(result.data, .object(["x": .int(1)]))
        XCTAssertNil(result.error)
    }

    func test_envelope_nullDataWithErrors_yieldsNilDataAndError() {
        let frame: JSONValue = .object([
            "data": .null,
            "errors": .array([.object(["message": .string("denied")])]),
        ])
        let result = AblyTransport.result(from: frame)
        XCTAssertNil(result.data)
        XCTAssertEqual(result.error?.graphqlErrors.first?.message, "denied")
    }

    func test_nonEnvelopePayload_isTreatedAsData() {
        // Server publishes the subscription payload directly (no {data,errors}
        // wrapper) — the whole object is the data.
        let frame: JSONValue = .object(["projectUpdated": .object(["id": .string("p1"), "status": .string("ready")])])
        let result = AblyTransport.result(from: frame)
        XCTAssertEqual(result.data, frame)
        XCTAssertNil(result.error)
    }

    func test_multipleGraphqlErrors_allCarried() {
        let frame: JSONValue = .object([
            "data": .null,
            "errors": .array([
                .object(["message": .string("e1")]),
                .object(["message": .string("e2")]),
            ]),
        ])
        let result = AblyTransport.result(from: frame)
        XCTAssertEqual(result.error?.graphqlErrors.map(\.message), ["e1", "e2"])
    }
}
