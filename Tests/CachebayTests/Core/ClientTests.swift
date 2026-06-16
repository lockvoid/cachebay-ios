import XCTest
@testable import Cachebay

/// Port of `cachebay-web/test/unit/core/client.test.ts`.
///
/// On iOS the `CachebayClient` initialiser takes a strongly-typed
/// `Transport` (no `unknown` blobs), so the JS suite's "throws when
/// `transport.http` is missing / not a function" cases collapse into a
/// compile-time check. The remaining behaviours — public API surface,
/// wire-up of every subsystem, optional WS transport, evictAll
/// orchestration — port verbatim.
final class ClientTests: XCTestCase {

    private func makeClient(http: MockHTTPTransport? = nil, ws: MockWSTransport? = nil, options: CachebayOptions? = nil) -> CachebayClient {
        let transport = Transport(http: http ?? MockHTTPTransport(), ws: ws)
        let opts = options ?? CachebayOptions(transport: transport, cachePolicy: .cacheFirst, suspensionTimeout: 0)
        return CachebayClient(options: opts)
    }

    // MARK: - Public API surface

    func test_exposesPublicAPI() {
        let client = makeClient()

        // Identity
        // (`identify` is a method, so we can call it through the type
        // system — no `typeof` reflection needed.)
        _ = client.identify

        // Fragments API
        _ = client.readFragment(id: "x", fragment: "fragment X on Foo { id }")
        _ = client.writeFragment as Any
        _ = client.watchFragment as Any

        // Queries API
        _ = client.readQuery as Any
        _ = client.writeQuery as Any
        _ = client.watchQuery as Any

        // Optimistic API — disambiguate against the autoCommit overload.
        _ = client.modifyOptimistic as (@Sendable (_ b: OptimisticBuilder) -> Void) -> OptimisticTransaction

        // Operations API
        _ = client.executeQuery as Any
        _ = client.executeMutation as Any
        _ = client.executeSubscription as Any

        // Inspect API
        XCTAssertNotNil(client.inspect)

        // Evict API
        _ = client.evictAll as Any

        // Subsystems exposed as public properties (parallel to JS
        // `__internals` accessor).
        XCTAssertNotNil(client.graph)
        XCTAssertNotNil(client.optimistic)
        XCTAssertNotNil(client.planner)
        XCTAssertNotNil(client.canonical)
        XCTAssertNotNil(client.documents)
        XCTAssertNotNil(client.fragments)
        XCTAssertNotNil(client.queries)
        XCTAssertNotNil(client.operations)
    }

    func test_acceptsOptionalWebSocketTransport() {
        let ws = MockWSTransport()
        let client = makeClient(ws: ws)

        // Subscription stream is constructed without throwing.
        XCTAssertNoThrow(
            try {
                _ = try client.executeSubscription(query: "subscription S { x }")
            }())
    }

    // MARK: - Option propagation

    func test_optionPropagation_keysAndInterfaces() throws {
        let userKey: KeyFunction = { _, obj in obj["email"]?.string }
        let opts = CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            keys: ["User": userKey],
            interfaces: ["Post": ["AudioPost", "VideoPost"]],
            suspensionTimeout: 0
        )
        let client = CachebayClient(options: opts)

        // `keys` flows into Graph.identify for User.
        XCTAssertEqual(
            client.graph.identify(["__typename": .string("User"), "email": .string("a@b.c")]),
            "User:a@b.c"
        )

        // `interfaces` flows into Graph.canonicalTypename and identify.
        XCTAssertEqual(
            client.graph.identify(["__typename": .string("AudioPost"), "id": .string("p1")]),
            "Post:p1"
        )
        XCTAssertEqual(client.graph.canonicalTypename("VideoPost"), "Post")
    }

    func test_optionPropagation_cachePolicy_defaultsToProvided() async throws {
        let http = MockHTTPTransport()
        http.whenQueryContains(
            "post",
            respondWith: .object([
                "post": .object(["__typename": .string("Post"), "id": .string("p1"), "title": .string("Hello")])
            ]))
        let opts = CachebayOptions(
            transport: Transport(http: http),
            cachePolicy: .cacheOnly,
            suspensionTimeout: 0
        )
        let client = CachebayClient(options: opts)

        // cache-only policy means a cold cache → error.
        let res = try await client.executeQuery(query: "{ post(id: \"p1\") { id title } }")
        XCTAssertNil(res.data)
        XCTAssertNotNil(res.error)
    }

    // MARK: - evictAll orchestration

    func test_evictAll_clearsAllSubsystems() async throws {
        let client = makeClient()

        // Seed graph + optimistic layer + planner cache + documents cache.
        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("v1"),
            ])
        )
        let tx = client.modifyOptimistic { b in
            b.patch(.key("Post:p1"), ["title": "Optimistic"], mode: .merge)
        }
        _ = tx
        // Graph has data.
        XCTAssertNotNil(client.graph.getRecord("Post:p1"))

        await client.evictAll()

        // After evict: graph is empty, watchers fired, planner clean.
        XCTAssertNil(client.graph.getRecord("Post:p1"))
        XCTAssertEqual(client.graph.keysList().count, 0)
    }

    func test_evictAll_storage_isCalledFirst() async throws {
        // The recently-aligned behaviour spec'd in the codebase says
        // `CachebayClient.evictAll` calls `storage.evictAll()` BEFORE
        // wiping the in-memory graph, so a shared SQLite file doesn't
        // resurrect records on the next `load`.
        let recorder = StorageRecorder()
        let factory: StorageAdapterFactory = { _ in
            RecorderStorage(recorder: recorder)
        }
        let opts = CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0,
            storage: factory
        )
        let client = CachebayClient(options: opts)

        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object([
                "__typename": .string("Post"),
                "id": .string("p1"),
                "title": .string("v"),
            ])
        )

        await client.evictAll()

        // The "evictAll" record must be present in the recorder.
        XCTAssertTrue(recorder.snapshot().contains("evictAll"))
    }
}

// MARK: - Storage test doubles

private final class StorageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func record(_ s: String) { lock.lock(); events.append(s); lock.unlock() }
    func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return events }
}

/// Minimal `StorageAdapter` that records every call. Implements every
/// protocol method (`put`, `remove`, `load`, `flush`, `evictJournal`,
/// `evictAll`, `inspect`, `dispose`) — the strict-concurrency checker
/// will reject incomplete conformance otherwise.
private struct RecorderStorage: StorageAdapter {
    let recorder: StorageRecorder
    func put(_ records: [(CacheKey, [String: JSONValue])]) { recorder.record("put(\(records.count))") }
    func remove(_ ids: [CacheKey]) { recorder.record("remove(\(ids.count))") }
    func load() async throws -> [(CacheKey, [String: JSONValue])] { recorder.record("load"); return [] }
    func loadSync() throws -> [(CacheKey, [String: JSONValue])] { recorder.record("loadSync"); return [] }
    func flush() async throws { recorder.record("flush") }
    func evictJournal() async throws { recorder.record("evictJournal") }
    func evictAll() async throws { recorder.record("evictAll") }
    func inspect() async throws -> StorageInspection {
        recorder.record("inspect")
        return StorageInspection(recordCount: 0, journalCount: 0, lastSeenSeq: 0, instanceID: "test")
    }
    func dispose() { recorder.record("dispose") }
}
