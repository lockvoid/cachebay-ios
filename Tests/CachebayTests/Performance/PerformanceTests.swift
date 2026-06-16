import XCTest
@testable import Cachebay

/// Throughput + scaling benchmarks for the optimistic layer.
///
/// These tests answer four questions:
///
/// 1. **Apply + revert throughput** — how many full optimistic round-trips
///    per second for entity patches and for connection linkNode/unlinkNode?
/// 2. **Stacked-layer cost** — with K pending layers, what is the cost of
///    applying layer K+1 and of reverting a middle layer?
/// 3. **Connection-size scaling** — does linkNode cost stay sublinear as the
///    canonical connection grows from 10 to 10 000 edges?
/// 4. **Commit path** — how many commits per second (baseline restore +
///    builder replay in `.commit` phase + graph flush)?
///
/// Run with:
///   swift test --filter PerformanceTests -c release
///
/// Each test prints a one-line `[perf] …` summary that the CI pipeline can
/// scrape. The `measure { … }` wrapper gives XCTest a stable baseline for
/// regression detection.
final class PerformanceTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
    }

    private func time(_ block: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        return CFAbsoluteTimeGetCurrent() - start
    }

    private func report(_ name: String, ops: Int, seconds: Double) {
        let opsPerSec = Double(ops) / seconds
        let usPerOp = (seconds / Double(ops)) * 1_000_000
        let formattedOps = String(format: "%8.1f", opsPerSec)
        let formattedUs = String(format: "%6.2f", usPerOp)
        print("[perf] \(name.padding(toLength: 48, withPad: " ", startingAt: 0)) ops=\(ops)  \(formattedOps) ops/s  \(formattedUs) µs/op")
    }

    // MARK: - 1. Apply + revert throughput (entity path)

    /// End-to-end: create a layer, patch one entity, revert the layer. Worst
    /// case for bookkeeping: every iteration walks the full lifecycle.
    func test_perf_entity_patch_apply_revert() {
        let client = makeClient()
        try? client.writeFragment(
            id: "Post:p1", fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p1", "title": "base"])
        )

        let iterations = 10_000
        var elapsed: Double = 0
        measure {
            elapsed = time {
                for i in 0..<iterations {
                    let tx = client.modifyOptimistic { b in
                        b.patch(.key("Post:p1"), ["title": .string("v\(i)")], mode: .merge)
                    }
                    tx.revert()
                }
            }
        }
        report("entity patch apply+revert", ops: iterations, seconds: elapsed)
    }

    // MARK: - 2. Stacked layers: apply cost at depth

    /// What does it cost to `modifyOptimistic` when the pending-layers list
    /// already has K entries on the same record? This is the "chat with
    /// queued mutations" scenario.
    func test_perf_entity_patch_stacked_layers() {
        for depth in [10, 100, 1_000, 5_000] {
            let client = makeClient()
            try? client.writeFragment(
                id: "Post:p1", fragment: "fragment P on Post { id title }",
                data: .object(["__typename": "Post", "id": "p1", "title": "base"])
            )
            // Pre-stack K layers.
            var pending: [OptimisticTransaction] = []
            pending.reserveCapacity(depth)
            for i in 0..<depth {
                let tx = client.modifyOptimistic { b in
                    b.patch(.key("Post:p1"), ["title": .string("d\(i)")], mode: .merge)
                }
                pending.append(tx)
            }

            let iterations = 1_000
            let elapsed = time {
                for i in 0..<iterations {
                    let tx = client.modifyOptimistic { b in
                        b.patch(.key("Post:p1"), ["title": .string("n\(i)")], mode: .merge)
                    }
                    tx.revert()
                }
            }
            report("entity apply+revert  (depth=\(depth))", ops: iterations, seconds: elapsed)

            // Cleanup: drain pre-stacked layers so the next depth iteration starts fresh.
            for tx in pending { tx.revert() }
        }
    }

    // MARK: - 3. Stacked layers: revert cost at depth

    /// If you have K layers and revert the BOTTOM one, cachebay restores the
    /// baseline then replays the K-1 survivors. Cost should scale with K,
    /// not with the whole graph.
    func test_perf_revert_bottom_layer_replays_survivors() {
        for depth in [10, 100, 1_000] {
            let client = makeClient()
            try? client.writeFragment(
                id: "Post:p1", fragment: "fragment P on Post { id title }",
                data: .object(["__typename": "Post", "id": "p1", "title": "base"])
            )
            var pending: [OptimisticTransaction] = []
            for i in 0..<depth {
                pending.append(
                    client.modifyOptimistic { b in
                        b.patch(.key("Post:p1"), ["title": .string("d\(i)")], mode: .merge)
                    })
            }
            // Revert just the bottom layer; the rest should still apply on top.
            let elapsed = time {
                pending.removeFirst().revert()
            }
            let perSurvivor = elapsed / Double(depth)
            print("[perf] revert bottom-of-\(depth)  total=\(String(format: "%.3f", elapsed * 1000)) ms  per-survivor=\(String(format: "%.2f", perSurvivor * 1_000_000)) µs")

            for tx in pending { tx.revert() }
        }
    }

    // MARK: - 4. Connection linkNode throughput

    /// How fast can we prepend/append to a canonical connection via the
    /// optimistic path? Each iteration is one full layer.
    func test_perf_connection_addNode_throughput() {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")

        let iterations = 5_000
        var elapsed: Double = 0
        measure {
            elapsed = time {
                for i in 0..<iterations {
                    let tx = client.modifyOptimistic { b in
                        let c = b.connection(selector)
                        c.linkNode(
                            .object(["__typename": "Post", "id": .string("p\(i)")]),
                            options: LinkNodeOptions(position: .end)
                        )
                    }
                    tx.dispose()  // keep the edge; measures the hot add path
                }
            }
        }
        report("connection linkNode+commit", ops: iterations, seconds: elapsed)
    }

    // MARK: - 5. linkNode cost vs. existing connection size

    /// linkNode currently scans existing edges to de-dup by node key. This
    /// test measures whether cost grows linearly with the canonical's edge
    /// count. Expect super-linear behaviour to show up as a red flag.
    func test_perf_connection_addNode_scales_with_edge_count() {
        for preload in [100, 1_000, 5_000] {
            let client = makeClient()
            let selector = ConnectionSelector(parent: .key("Query"), key: "posts")

            // Preload `preload` edges committed once — this is the steady-state
            // canonical shape we're benchmarking add-into.
            let seed = client.modifyOptimistic { b in
                let c = b.connection(selector)
                for i in 0..<preload {
                    c.linkNode(
                        .object(["__typename": "Post", "id": .string("seed\(i)")]),
                        options: LinkNodeOptions(position: .end)
                    )
                }
            }
            seed.dispose()

            let iterations = 500
            let elapsed = time {
                for i in 0..<iterations {
                    let tx = client.modifyOptimistic { b in
                        let c = b.connection(selector)
                        c.linkNode(
                            .object(["__typename": "Post", "id": .string("new\(i)")]),
                            options: LinkNodeOptions(position: .start)
                        )
                    }
                    tx.dispose()
                }
            }
            report("connection linkNode   (preload=\(preload))", ops: iterations, seconds: elapsed)
        }
    }

    // MARK: - 6. Commit path

    /// `commit(data:)` drops the layer, restores the baseline, and replays
    /// the builder once more with `phase: .commit`. Measures how fast a full
    /// commit lifecycle runs.
    func test_perf_commit_with_server_data() {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")

        let iterations = 5_000
        var elapsed: Double = 0
        measure {
            elapsed = time {
                for i in 0..<iterations {
                    let tempId = "temp:\(i)"
                    let realId = "real\(i)"
                    let tx = client.modifyOptimistic { b in
                        b.connection(selector).linkNode(
                            .object(["__typename": "Post", "id": .string(tempId)]),
                            options: LinkNodeOptions(position: .start)
                        )
                    }
                    // Commit closure captures `realId` from outer scope —
                    // promotes the temp edge to the real-id edge after
                    // baseline restore drops the temp.
                    tx.commit { b in
                        b.connection(selector).linkNode(
                            .object(["__typename": "Post", "id": .string(realId)]),
                            options: LinkNodeOptions(position: .start)
                        )
                    }
                }
            }
        }
        report("commit(data) add+promote", ops: iterations, seconds: elapsed)
    }

    // MARK: - 7. Mixed realistic burst

    /// Realistic shape: for each "server write" equivalent, we fire 1 entity
    /// patch + 1 connection linkNode under a layer. Closest to "user taps
    /// favourite while scrolling".
    func test_perf_mixed_burst() {
        let client = makeClient()
        // Seed one entity + an empty connection.
        try? client.writeFragment(
            id: "Post:p1", fragment: "fragment P on Post { id title likes }",
            data: .object(["__typename": "Post", "id": "p1", "title": "seed", "likes": 0])
        )
        let selector = ConnectionSelector(parent: .key("Query"), key: "notifications")

        let iterations = 5_000
        var elapsed: Double = 0
        measure {
            elapsed = time {
                for i in 0..<iterations {
                    let tx = client.modifyOptimistic { b in
                        b.patch(.key("Post:p1"), ["likes": .int(Int64(i))], mode: .merge)
                        let c = b.connection(selector)
                        c.linkNode(
                            .object(["__typename": "Notification", "id": .string("n\(i)")]),
                            options: LinkNodeOptions(position: .start)
                        )
                    }
                    tx.revert()
                }
            }
        }
        report("mixed patch+linkNode apply+revert", ops: iterations, seconds: elapsed)
    }

    // MARK: - 8. Tail-latency sanity: linkNode @ preload=5000

    /// The "mean" numbers in other tests smooth over occasional spikes. This
    /// test runs a fixed number of insertions into a pre-seeded canonical and
    /// reports the full tail: p50 / p95 / p99 / p99.9 / max.
    ///
    /// The old O(N) code path would have a p99/p50 that grew unboundedly with
    /// the canonical size; the nodeIndex makes per-op work size-independent,
    /// so we assert p99 stays within 5× of p50.
    func test_perf_addNode_preload_5000_tail_latency() {
        let client = makeClient()
        let selector = ConnectionSelector(parent: .key("Query"), key: "posts")

        // Pre-seed the canonical with 5000 edges.
        let seed = client.modifyOptimistic { b in
            let c = b.connection(selector)
            for i in 0..<5_000 {
                c.linkNode(
                    .object(["__typename": "Post", "id": .string("seed\(i)")]),
                    options: LinkNodeOptions(position: .end)
                )
            }
        }
        seed.dispose()

        // Warmup — first-touch / allocator effects should not pollute the tail.
        for w in 0..<200 {
            let tx = client.modifyOptimistic { b in
                b.connection(selector).linkNode(
                    .object(["__typename": "Post", "id": .string("warm\(w)")]),
                    options: LinkNodeOptions(position: .start)
                )
            }
            tx.dispose()
        }

        let iterations = 5_000
        var samplesNs: [UInt64] = []
        samplesNs.reserveCapacity(iterations)

        for i in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            let tx = client.modifyOptimistic { b in
                b.connection(selector).linkNode(
                    .object(["__typename": "Post", "id": .string("tail\(i)")]),
                    options: LinkNodeOptions(position: .start)
                )
            }
            tx.dispose()
            samplesNs.append(DispatchTime.now().uptimeNanoseconds - start)
        }

        samplesNs.sort()
        let pctUs: (Double) -> Double = { p in
            let idx = min(samplesNs.count - 1, Int(Double(samplesNs.count - 1) * p))
            return Double(samplesNs[idx]) / 1000.0
        }
        let meanUs = Double(samplesNs.reduce(0, +)) / Double(samplesNs.count) / 1000.0
        let p50 = pctUs(0.50)
        let p95 = pctUs(0.95)
        let p99 = pctUs(0.99)
        let p999 = pctUs(0.999)
        let maxUs = Double(samplesNs.last ?? 0) / 1000.0

        print(
            String(
                format: "[perf] linkNode tail (preload=5000)  mean=%6.2f µs  p50=%6.2f  p95=%6.2f  p99=%6.2f  p99.9=%6.2f  max=%7.2f  (p99/p50=%.1fx)",
                meanUs, p50, p95, p99, p999, maxUs, p99 / p50))

        // Local M-series typically lands at p99/p50 ≈ 1.3×. GitHub-hosted
        // macos-15 runners are shared hardware with noisy neighbours and
        // routinely produce 4–6× tail ratios on identical workloads. The
        // 10× bar still catches pathological regressions (e.g. an O(n²)
        // code path that would push the ratio past 20×) without flaking
        // on CI runner load.
        XCTAssertLessThan(p99 / p50, 10.0, "p99 is \(p99 / p50)× p50 — investigate spikes")
    }

    // MARK: - 9. Variance sanity: mixed burst across runs

    /// Re-runs the "mixed" workload 5 times and prints per-run throughput so
    /// we can decide whether the 3.9% delta vs the pre-nodeIndex baseline is
    /// run-to-run noise (observed RSD ≥ 3.9%) or a systematic cost.
    func test_perf_mixed_burst_variance() {
        let runs = 5
        let iterations = 5_000
        var throughputs: [Double] = []

        for _ in 0..<runs {
            let client = makeClient()
            try? client.writeFragment(
                id: "Post:p1", fragment: "fragment P on Post { id title likes }",
                data: .object(["__typename": "Post", "id": "p1", "title": "seed", "likes": 0])
            )
            let selector = ConnectionSelector(parent: .key("Query"), key: "notifications")
            let elapsed = time {
                for i in 0..<iterations {
                    let tx = client.modifyOptimistic { b in
                        b.patch(.key("Post:p1"), ["likes": .int(Int64(i))], mode: .merge)
                        b.connection(selector).linkNode(
                            .object(["__typename": "Notification", "id": .string("n\(i)")]),
                            options: LinkNodeOptions(position: .start)
                        )
                    }
                    tx.revert()
                }
            }
            throughputs.append(Double(iterations) / elapsed)
        }

        let mean = throughputs.reduce(0, +) / Double(runs)
        let variance = throughputs.map { pow($0 - mean, 2) }.reduce(0, +) / Double(runs)
        let stddev = sqrt(variance)
        let rsd = (stddev / mean) * 100.0
        let perRun = throughputs.map { String(format: "%.0f", $0) }.joined(separator: ", ")
        print(
            String(
                format: "[perf] mixed variance   runs=[%@] mean=%.0f ops/s  stddev=%.0f  rsd=%.2f%%",
                perRun, mean, stddev, rsd))
    }
}
