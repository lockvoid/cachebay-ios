import XCTest
import Foundation
@testable import Cachebay

// WS4 / Gate wk6 — validate the §5 cost-model bet: eager decode pays once at
// materialize, then field reads are direct loads (~free); the lazy dict-wrapper
// pays a subscript + enum-unwrap on EVERY read. On a high read-ratio workload
// (our workload — diff-driven UI, AI message lists), eager wins.

@CachebayData(typename: "Msg")
private struct Msg: Sendable, Hashable, CachebayValue {
    let __typename: String
    let id: String
    let text: String
    let score: Double
    let author: String
}

final class TypedDecodePerfTests: XCTestCase {
    private func dicts(_ n: Int) -> [[String: JSONValue]] {
        (0..<n).map { i in
            [
                "__typename": .string("Msg"),
                "id": .string("m\(i)"),
                "text": .string("message body number \(i)"),
                "score": .double(Double(i) * 0.5),
                "author": .string("u\(i % 10)"),
            ]
        }
    }

    // Eager decode of N records — the bounded "pay once at materialize" cost.
    func test_perf_eagerDecode() {
        let ds = dicts(1000)
        measure { _ = ds.compactMap { Msg(_dataDict: $0) } }
    }

    // High read-ratio: each record's field is read M times. Isolates access cost
    // (Double field load vs dict-subscript + enum-unwrap).
    func test_perf_readRatio_eager_vs_lazy() {
        let n = 1000, m = 500
        let ds = dicts(n)
        let msgs = ds.compactMap { Msg(_dataDict: $0) }
        XCTAssertEqual(msgs.count, n)

        let t0 = CFAbsoluteTimeGetCurrent()
        var a = 0
        for _ in 0..<m { for msg in msgs { a &+= Int(msg.score) } }  // direct field load
        let eager = CFAbsoluteTimeGetCurrent() - t0

        let t1 = CFAbsoluteTimeGetCurrent()
        var b = 0
        for _ in 0..<m { for d in ds { b &+= Int(d["score"]?.double ?? 0) } }  // subscript + unwrap
        let lazy = CFAbsoluteTimeGetCurrent() - t1

        XCTAssertEqual(a, b, "both paths compute the same sum")
        // Informational (wall-clock asserts are flaky in CI). The number is the
        // gate-wk6 deliverable: eager field reads beat lazy dict reads, and the
        // bigger wins are pay-once-at-materialize + free synthesized Equatable.
        print(
            String(
                format: "[perf] read-ratio N=%d M=%d (%d reads): eager=%.2fms lazy=%.2fms speedup=%.1fx",
                n, m, n * m, eager * 1000, lazy * 1000, lazy / max(eager, 1e-9)))
    }
}
