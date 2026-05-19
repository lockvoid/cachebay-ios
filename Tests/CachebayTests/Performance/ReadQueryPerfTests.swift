import XCTest
@testable import Cachebay

/// Public-API perf benchmark for the **pure-Swift** cachebay-ios runtime.
///
/// Mirrors the equivalent test in cachebay-native
/// (`platforms/ios/Tests/CachebayTests/ReadQueryPerfTests.swift`) so the
/// pure-Swift baseline can be compared head-to-head against the Rust /
/// FFI numbers.
///
/// Same fixture: 5 projects × 140 items (705 entities, ~5649 scalars).
/// Same query string. Same self-timed harness. Numbers report min /
/// median / mean / p99 / max in microseconds.
///
/// Scenarios:
///   - `read warm`: seed via writeQuery, then tight readQuery loop.
///     Hits the materialize cache; isolates per-call materialize cost.
///   - `read+write cold`: writeQuery + readQuery per iteration so the
///     materialize cache is invalidated each loop.
///   - `write only`: pure writeQuery cost.
///
/// IMPORTANT: run with `-c release` for numbers comparable to the
/// cachebay-native Swift wrapper / Rust criterion benches. Debug-mode
/// numbers are ~2.6× slower and not informative.
///
///     swift test -c release --filter ReadQueryPerfTests
final class ReadQueryPerfTests: XCTestCase {

    static let projects = 5
    static let itemsPerProject = 140

    static let projectsQuery = """
    query ProjectsQuery($orderBy: String!) {
      projects(orderBy: $orderBy) @connection(key: "projects", filter: ["orderBy"]) {
        edges {
          cursor
          node {
            __typename
            id
            title
            body
            author
            likes
            count
            items {
              __typename
              id
              title
              body
              author
              likes
              rank
              tag
            }
          }
        }
        pageInfo {
          __typename
          hasNextPage
          hasPreviousPage
        }
      }
    }
    """

    static func vars() -> [String: JSONValue] {
        ["orderBy": .string("UPDATED_AT")]
    }

    /// Build the `data` payload matching the cachebay-native fixture
    /// byte-for-byte (same field names, same value types, same N×M shape).
    static func buildResponse(projects: Int, itemsPerProject: Int) -> JSONValue {
        var edges: [JSONValue] = []
        edges.reserveCapacity(projects)
        for p in 0..<projects {
            var items: [JSONValue] = []
            items.reserveCapacity(itemsPerProject)
            for i in 0..<itemsPerProject {
                items.append(.object([
                    "__typename": .string("Item"),
                    "id":         .string("p\(p)-i\(i)"),
                    "title":      .string("Item title \(p)-\(i)"),
                    "body":       .string("Item body  \(p)-\(i)"),
                    "author":     .string("Author \(p)"),
                    "likes":      .int(Int64(i)),
                    "rank":       .int(Int64(i % 10)),
                    "tag":        .string("tag-\(i % 5)"),
                ]))
            }
            edges.append(.object([
                "__typename": .string("ProjectEdge"),
                "cursor":     .string("c-p\(p)"),
                "node": .object([
                    "__typename": .string("Project"),
                    "id":         .string("p\(p)"),
                    "title":      .string("Project \(p)"),
                    "body":       .string("Description for project \(p)"),
                    "author":     .string("Author \(p)"),
                    "likes":      .int(Int64(p * 10)),
                    "count":      .int(Int64(itemsPerProject)),
                    "items":      .array(items),
                ]),
            ]))
        }
        return .object([
            "projects": .object([
                "__typename": .string("ProjectConnection"),
                "edges":      .array(edges),
                "pageInfo": .object([
                    "__typename":      .string("PageInfo"),
                    "hasNextPage":     .bool(false),
                    "hasPreviousPage": .bool(false),
                ]),
            ]),
        ])
    }

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    /// Self-timed harness — mirrors the cachebay-native ReadQueryPerfTests
    /// helper so the output format matches (easy diff between repos).
    private func benchmark(
        _ label: String,
        iterations: Int,
        warmup: Int = 50,
        body: () -> Void
    ) {
        for _ in 0..<warmup { body() }
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let t0 = CFAbsoluteTimeGetCurrent()
            body()
            let t1 = CFAbsoluteTimeGetCurrent()
            samples.append((t1 - t0) * 1_000_000) // microseconds
        }
        samples.sort()
        let minV = samples.first ?? 0
        let median = samples[samples.count / 2]
        let p99 = samples[Int(Double(samples.count) * 0.99)]
        let maxV = samples.last ?? 0
        let mean = samples.reduce(0, +) / Double(samples.count)
        print("""
        ⏱  \(label) (n=\(iterations))
            min:    \(String(format: "%.2f", minV)) µs
            median: \(String(format: "%.2f", median)) µs
            mean:   \(String(format: "%.2f", mean)) µs
            p99:    \(String(format: "%.2f", p99)) µs
            max:    \(String(format: "%.2f", maxV)) µs
        """)
    }

    // MARK: - 1. Warm read — seeded once, tight readQuery loop

    /// Seed once via `writeQuery`, then loop `readQuery`. The
    /// materialize cache (cached by query signature) stays warm,
    /// isolating the per-call public-API cost: signature build,
    /// cache lookup, fingerprint check, output construction.
    func test_perf_readQuery_warm_5x140() throws {
        let client = makeClient()
        let response = Self.buildResponse(
            projects: Self.projects,
            itemsPerProject: Self.itemsPerProject
        )
        try client.writeQuery(
            query: Self.projectsQuery,
            variables: Self.vars(),
            data: response
        )

        benchmark("readQuery warm 5×140", iterations: 500) {
            // Use pattern-match against `.object` (not `XCTAssertNotNil`)
            // to verify non-nil. `XCTAssertNotNil(r)` autoclosures the
            // value into `Any?` which triggers a full retain-walk over
            // the JSONValue tree on every call — that's not part of the
            // readQuery cost we want to measure (and the Rust
            // criterion bench doesn't have it either).
            guard case .object? = client.readQuery(
                query: Self.projectsQuery,
                variables: Self.vars()
            ) else {
                XCTFail("readQuery returned nil")
                return
            }
        }
    }

    // MARK: - 2. Cold read — writeQuery + readQuery per iteration

    /// `writeQuery` + `readQuery` per loop so the materialize cache is
    /// invalidated each iteration. Measures the full round-trip cost.
    func test_perf_writeQuery_then_readQuery_cold_5x140() throws {
        let client = makeClient()
        let response = Self.buildResponse(
            projects: Self.projects,
            itemsPerProject: Self.itemsPerProject
        )
        // Prime caches so the first measured iteration isn't dominated
        // by one-time plan-compile cost.
        try client.writeQuery(
            query: Self.projectsQuery,
            variables: Self.vars(),
            data: response
        )

        benchmark("writeQuery+readQuery cold 5×140", iterations: 200) {
            try? client.writeQuery(
                query: Self.projectsQuery,
                variables: Self.vars(),
                data: response
            )
            _ = client.readQuery(
                query: Self.projectsQuery,
                variables: Self.vars()
            )
        }
    }

    // MARK: - 3. Projected read — mirrors the Rust "projected" bench

    /// Same as warm but with a tree walk after each `readQuery` that
    /// touches the fields a typed SwiftUI list cell would actually
    /// consume: `node.{id,title}` per project edge, plus
    /// `item.{id,title,likes}` per item. Total = 5×2 + 5×140×3 =
    /// **2110 scalars** read per iteration.
    ///
    /// This mirrors `bench_read_query_projected` in
    /// `cachebay-native/crates/cachebay-bench/benches/read_query_public.rs`.
    ///
    /// **Note:** pure-Swift cachebay-ios has no lazy-projection API —
    /// `readQuery` materialises the whole tree on every call regardless
    /// of which fields the caller reads. So this bench should land at
    /// roughly the same cost as `readQuery warm`, with a tiny extra
    /// for the in-Swift walk. The Rust-wrapper "projected" path
    /// (via `readQueryHandle` + typed accessors) is a different shape
    /// — it materialises in Rust and reads only the projected fields
    /// across FFI, so it scales with the projection, not the full
    /// selection.
    func test_perf_readQuery_projected_5x140() throws {
        let client = makeClient()
        let response = Self.buildResponse(
            projects: Self.projects,
            itemsPerProject: Self.itemsPerProject
        )
        try client.writeQuery(
            query: Self.projectsQuery,
            variables: Self.vars(),
            data: response
        )

        benchmark("readQuery projected 5×140", iterations: 200) {
            guard let r = client.readQuery(
                query: Self.projectsQuery,
                variables: Self.vars()
            ) else {
                XCTFail("readQuery returned nil")
                return
            }
            // Walk: projects.edges[*].node.{id,title} + items[*].{id,title,likes}
            var scalars = 0
            guard
                case .object(let root) = r,
                case .object(let projects)? = root["projects"],
                case .array(let edges)? = projects["edges"]
            else { return }
            for edge in edges {
                guard
                    case .object(let edgeObj) = edge,
                    case .object(let node)? = edgeObj["node"]
                else { continue }
                _ = node["id"]?.string
                _ = node["title"]?.string
                scalars += 2
                guard case .array(let items)? = node["items"] else { continue }
                for item in items {
                    guard case .object(let itemObj) = item else { continue }
                    _ = itemObj["id"]?.string
                    _ = itemObj["title"]?.string
                    _ = itemObj["likes"]?.int
                    scalars += 3
                }
            }
            XCTAssertGreaterThan(scalars, 0)
        }
    }

    // MARK: - 4. Pure writeQuery (no read between iters)

    /// Pure write cost — repeated `writeQuery` of the same data shape.
    /// Most subsequent writes hit deep-equal short-circuits inside
    /// `putRecord`, so this is dominated by the response walk +
    /// per-record hash lookups, not by actual writes.
    func test_perf_writeQuery_only_5x140() throws {
        let client = makeClient()
        let response = Self.buildResponse(
            projects: Self.projects,
            itemsPerProject: Self.itemsPerProject
        )

        benchmark("writeQuery only 5×140", iterations: 200) {
            try? client.writeQuery(
                query: Self.projectsQuery,
                variables: Self.vars(),
                data: response
            )
        }
    }
}
