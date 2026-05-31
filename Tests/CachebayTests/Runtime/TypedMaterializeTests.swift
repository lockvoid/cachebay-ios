import XCTest
import Foundation
import CachebayMacros
@testable import Cachebay

// WS4 — eager typed decode against the REAL `Documents.materialize`, end-to-end:
// interface dispatch + entity list + an un-narrowed (unknown) variant + §7 miss.
// This validates the "layered" decode strategy (materialize -> [String:JSONValue]
// -> CachebayValue.init?(cachebayJSON:)) before swapping the client's typed sites.

// MARK: - Typed shapes (hand-written; CLI-emitted in production)

@CachebayData(typename: "")
private struct GetCookData: Sendable, CachebayValue {
    let cook: Cook?
}

@CachebayData(typename: "Cook")
private struct Cook: Identifiable, Sendable, Hashable, CachebayValue {
    let __typename: String
    let id: String
    let title: String
    let elements: [Element]
}

@CachebayInterface
private enum Element: Identifiable, Sendable, Hashable, CachebayValue {
    case video(Video)
    case audio(Audio)
    case image(Image)
    case unknown(Shared)

    @CachebayData(typename: "")
    struct Shared: Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
    }
    @CachebayData(typename: "VideoElement")
    struct Video: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let url: URL
        let duration: TimeInterval
    }
    @CachebayData(typename: "AudioElement")
    struct Audio: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let waveformURL: URL
    }
    @CachebayData(typename: "ImageElement")
    struct Image: Identifiable, Sendable, Hashable, CachebayValue {
        let __typename: String
        let id: String
        let thumbnailURL: URL
    }
}

private let cookQuerySource = """
query GetCook($id: ID!) {
  cook(id: $id) {
    __typename
    id
    title
    elements {
      __typename
      id
      ... on VideoElement { url duration }
      ... on AudioElement { waveformURL }
      ... on ImageElement { thumbnailURL }
    }
  }
}
"""

private struct GetCook: CachebayOperation {
    struct Variables: OperationVariables {
        let id: String
        var __cachebay: [String: JSONValue] { ["id": .string(id)] }
    }
    typealias Data = GetCookData
    static let document: QueryDocument = .source(cookQuerySource)
}

final class TypedMaterializeTests: XCTestCase {
    private func makeStack() -> (Graph, Documents) {
        let graph = Graph(options: GraphOptions(
            keys: [:],
            interfaces: ["Element": ["VideoElement", "AudioElement", "ImageElement"]]
        ))
        let documents = Documents(graph: graph, planner: Planner(), canonical: Canonical(graph: graph))
        return (graph, documents)
    }

    private static let query = cookQuerySource

    private func seedCook(_ graph: Graph) {
        graph.putRecord("VideoElement:v1", [
            "__typename": .string("VideoElement"), "id": .string("v1"),
            "url": .string("https://x.com/v1.mp4"), "duration": .double(12.5),
        ])
        graph.putRecord("AudioElement:a1", [
            "__typename": .string("AudioElement"), "id": .string("a1"),
            "waveformURL": .string("https://x.com/a1.wav"),
        ])
        // PdfElement is NOT narrowed in the query -> interface-level fields only.
        graph.putRecord("PdfElement:p1", [
            "__typename": .string("PdfElement"), "id": .string("p1"),
        ])
        graph.putRecord("Cook:c1", [
            "__typename": .string("Cook"), "id": .string("c1"), "title": .string("Pasta"),
            "elements": .refList(["VideoElement:v1", "AudioElement:a1", "PdfElement:p1"]),
        ])
        graph.putRecord(CachebayConstants.rootID, [
            "cook({\"id\":\"c1\"})": .ref("Cook:c1"),
        ])
    }

    func test_typedDecode_interface_list_and_unknown() throws {
        let (graph, documents) = makeStack()
        let plan = try Compiler.compilePlan(source: Self.query)
        seedCook(graph)

        let result = documents.materialize(plan: plan, variables: ["id": .string("c1")])
        XCTAssertNotEqual(result.source, .none)

        // Eager typed decode of the whole operation root.
        let data = GetCookData(cachebayJSON: result.data)
        let cook = try XCTUnwrap(data?.cook)
        XCTAssertEqual(cook.title, "Pasta")
        XCTAssertEqual(cook.elements.count, 3)

        // Exhaustive switch over the sum type, including the un-narrowed variant.
        var kinds: [String] = []
        for element in cook.elements {
            switch element {
            case .video(let v):
                kinds.append("video")
                XCTAssertEqual(v.url.absoluteString, "https://x.com/v1.mp4")
                XCTAssertEqual(v.duration, 12.5)
            case .audio(let a):
                kinds.append("audio")
                XCTAssertEqual(a.waveformURL.absoluteString, "https://x.com/a1.wav")
            case .image:
                kinds.append("image")
            case .unknown(let s):
                kinds.append("unknown")
                XCTAssertEqual(s.__typename, "PdfElement")  // §3.1 — carries interface fields
                XCTAssertEqual(s.id, "p1")
            }
        }
        XCTAssertEqual(kinds, ["video", "audio", "unknown"])

        // Lifted id works across every variant, including .unknown.
        XCTAssertEqual(cook.elements.map(\.id), ["v1", "a1", "p1"])
    }

    func test_typedDecode_missingRequiredField_isMiss() throws {
        // Fresh stack: seed the video record WITHOUT the required `url` from the start
        // (putRecord merges, so we can't drop a field by re-writing).
        let (graph, documents) = makeStack()
        let plan = try Compiler.compilePlan(source: Self.query)
        graph.putRecord("VideoElement:v1", [
            "__typename": .string("VideoElement"), "id": .string("v1"),
            "duration": .double(1),   // no url
        ])
        graph.putRecord("Cook:c1", [
            "__typename": .string("Cook"), "id": .string("c1"), "title": .string("Pasta"),
            "elements": .refList(["VideoElement:v1"]),
        ])
        graph.putRecord(CachebayConstants.rootID, ["cook({\"id\":\"c1\"})": .ref("Cook:c1")])

        let result = documents.materialize(plan: plan, variables: ["id": .string("c1")])
        // Eager typed decode enforces §7 (D3/D7): a known-typename record missing a
        // required selected field is a whole-record miss — regardless of how lenient
        // the underlying materialize is about scalars.
        XCTAssertNil(GetCookData(cachebayJSON: result.data)?.cook)
    }

    // The public typed client API: client.read(_:variables:) -> Op.Data?.
    func test_client_read_typedOperation() {
        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            interfaces: ["Element": ["VideoElement", "AudioElement", "ImageElement"]]
        ))
        seedCook(client.graph)

        let data = client.read(GetCook.self, variables: .init(id: "c1"))
        XCTAssertEqual(data?.cook?.title, "Pasta")
        XCTAssertEqual(data?.cook?.elements.count, 3)
        XCTAssertEqual(data?.cook?.elements.map(\.id), ["v1", "a1", "p1"])

        // Cache miss -> nil (no record for c2).
        XCTAssertNil(client.read(GetCook.self, variables: .init(id: "c2"))?.cook)
    }
}
