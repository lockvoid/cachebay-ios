import XCTest
@testable import Cachebay

/// The strict log-floor: decode AND materialize misses flow through one sink;
/// the sink defaults ON under XCTest so a miss is never silent in a test run; and
/// a `strictAssert` flag (default OFF — the log is the floor, the crash is opt-in)
/// gates the DEBUG abort, so the library's own deliberate miss-path tests don't
/// detonate.
final class CachebayDiagnosticsTests: XCTestCase {
    private final class Box: @unchecked Sendable { var lines: [String] = [] }

    override func tearDown() {
        CachebayDiagnostics.sink = nil
        CachebayDiagnostics.strictAssert = false
        super.tearDown()
    }

    func test_decodeMiss_and_materializeMiss_routeToOneSink() {
        let box = Box()
        CachebayDiagnostics.sink = { box.lines.append($0) }
        CachebayDiagnostics.decodeMiss("Edges", "required field 'cursor' did not decode")
        CachebayDiagnostics.materializeMiss("record Cook:1 has no field 'title'")
        XCTAssertTrue(
            box.lines.contains { $0.contains("typed-decode miss") && $0.contains("Edges") },
            "decode miss must route to the sink; got \(box.lines)")
        XCTAssertTrue(
            box.lines.contains { $0.contains("materialize miss") && $0.contains("Cook:1") },
            "materialize miss must route to the SAME sink; got \(box.lines)")
    }

    func test_strictAssert_defaultsOff_soAMissNeverCrashes() {
        XCTAssertFalse(CachebayDiagnostics.strictAssert, "the crash is opt-in; the log is the floor")
        // With strictAssert off, a miss logs but must not abort — this test running
        // to completion is the assertion.
        CachebayDiagnostics.sink = nil
        CachebayDiagnostics.decodeMiss("X", "y")
        CachebayDiagnostics.materializeMiss("z")
    }

    func test_defaultSink_isInstalledUnderXCTest() {
        // The env var is set during XCTest, so the factory installs a default sink
        // — a miss is visible even without a client logger.
        XCTAssertNotNil(CachebayDiagnostics.makeDefaultSink())
    }

    /// End-to-end: a real materialize miss in `Documents` (a record missing an
    /// object field its query selects) reaches the unified sink — no longer a
    /// logger-only line the test harness can't see.
    func test_realMaterializeMiss_reachesTheSink() throws {
        let box = Box()
        CachebayDiagnostics.sink = { box.lines.append($0) }
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))

        // Seed a Cook with no `project` object field…
        try client.writeQuery(
            query: "query { cook { __typename id } }",
            variables: [:],
            data: .object([
                "cook": .object([
                    CachebayConstants.typenameField: .string("Cook"), "id": .string("c1"),
                ])
            ])
        )
        // …then read a query that DOES select `project { … }` on it → miss.
        _ = try? client.readQuery(
            query: "query { cook { __typename id project { __typename id } } }",
            variables: [:]
        )

        XCTAssertTrue(
            box.lines.contains { $0.contains("materialize miss") && $0.contains("project") },
            "a real materialize miss must reach the sink; got \(box.lines)"
        )
    }

    // MARK: - Encode fixed-point (custom-scalar stability)

    private struct StableScalar: CachebayValue {
        let s: String
        init(s: String) { self.s = s }
        init?(cachebayJSON j: JSONValue) { guard let x = j.string else { return nil }; self.s = x }
        var cachebayJSON: JSONValue { .string(s) }
    }
    /// Asymmetric: decode drops the sign, so re-encoding differs.
    private struct LossyScalar: CachebayValue {
        let n: Int
        init(n: Int) { self.n = n }
        init?(cachebayJSON j: JSONValue) { guard let i = j.int else { return nil }; self.n = abs(Int(i)) }
        var cachebayJSON: JSONValue { .int(Int64(n)) }
    }

    func test_encodeStable_true_forSymmetricConformance() {
        XCTAssertTrue(CachebayDiagnostics.checkEncodeStable(StableScalar(s: "hello")))
    }

    func test_encodeStable_falseAndReports_forLossyConformance() {
        let box = Box()
        CachebayDiagnostics.sink = { box.lines.append($0) }
        XCTAssertFalse(CachebayDiagnostics.checkEncodeStable(LossyScalar(n: -5)))
        XCTAssertTrue(box.lines.contains { $0.contains("encode-unstable") }, "got \(box.lines)")
    }

    /// The fixed point is on the ENCODED form, so a Date that loses sub-millisecond
    /// precision on round-trip is still encode-stable (re-encoding yields the same
    /// string) — the false-positive class we explicitly avoid.
    func test_encodeStable_toleratesDateSubMillisecondPrecision() {
        XCTAssertTrue(CachebayDiagnostics.checkEncodeStable(Date(timeIntervalSince1970: 1_700_000_000.123456)))
    }
}
