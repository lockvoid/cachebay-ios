import XCTest
@testable import Cachebay

final class SQLiteStorageTests: XCTestCase {
    private func tmpPath() -> String {
        let base = FileManager.default.temporaryDirectory
        return base.appendingPathComponent("cachebay-\(UUID().uuidString).sqlite").path
    }

    private func makeAdapter(path: String) -> SQLiteStorage {
        let noop: @Sendable ([(CacheKey, [String: JSONValue])]) -> Void = { _ in }
        let noopRemove: @Sendable ([CacheKey]) -> Void = { _ in }
        let ctx = StorageContext(instanceID: "inst-1", onUpdate: noop, onRemove: noopRemove)
        return SQLiteStorage(context: ctx, options: .init(path: path))
    }

    func test_put_load_roundtrip() async throws {
        let path = tmpPath()
        let a = makeAdapter(path: path)
        a.put([
            ("Post:p1", ["__typename": "Post", "id": "p1", "title": "Hello"]),
            ("Post:p2", ["__typename": "Post", "id": "p2", "title": "World"]),
        ])
        try await a.flush()
        a.dispose()

        let b = makeAdapter(path: path)
        let loaded = try await b.load()
        let byId = Dictionary(uniqueKeysWithValues: loaded.map { ($0.0, $0.1) })
        XCTAssertEqual(byId["Post:p1"]?["title"]?.string, "Hello")
        XCTAssertEqual(byId["Post:p2"]?["title"]?.string, "World")
        b.dispose()
    }

    func test_remove_clears_records() async throws {
        let path = tmpPath()
        let a = makeAdapter(path: path)
        a.put([("Post:p1", ["__typename": "Post", "id": "p1"])])
        a.remove(["Post:p1"])
        try await a.flush()
        let loaded = try await a.load()
        XCTAssertEqual(loaded.count, 0)
        a.dispose()
    }

    func test_ref_encoding_roundtrip() async throws {
        let path = tmpPath()
        let a = makeAdapter(path: path)
        a.put([
            ("@", [
                "post({\"id\":\"p1\"})": .ref("Post:p1"),
                "posts": .refList(["Post:p1", "Post:p2"]),
            ]),
            ("Post:p1", ["__typename": "Post", "id": "p1", "title": "A"]),
        ])
        try await a.flush()
        let loaded = try await a.load()
        let rootRecord = loaded.first(where: { $0.0 == "@" })?.1 ?? [:]
        if case .ref(let key) = rootRecord["post({\"id\":\"p1\"})"] ?? .undefined {
            XCTAssertEqual(key, "Post:p1")
        } else {
            XCTFail("Expected restored .ref")
        }
        if case .refList(let list) = rootRecord["posts"] ?? .undefined {
            XCTAssertEqual(list, ["Post:p1", "Post:p2"])
        } else {
            XCTFail("Expected restored .refList")
        }
        a.dispose()
    }

    func test_evictAll_clears_both_stores() async throws {
        let path = tmpPath()
        let a = makeAdapter(path: path)
        a.put([("Post:p1", ["__typename": "Post", "id": "p1"])])
        try await a.flush()
        try await a.evictAll()
        let info = try await a.inspect()
        XCTAssertEqual(info.recordCount, 0)
        a.dispose()
    }

    func test_client_persists_and_reloads() async throws {
        let path = tmpPath()
        // First client writes data.
        let client1 = CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0,
            storage: SQLiteStorage.factory(options: .init(path: path))
        ))
        try client1.writeFragment(id: "Post:p1", fragment: "fragment P on Post { id title }", data: .object([
            "__typename": "Post", "id": "p1", "title": "Persist-me"
        ]))
        // Give the storage queue a chance to flush.
        try await client1.storage?.flush()
        await client1.shutdown()

        // Second client reads from the same file.
        let client2 = CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0,
            storage: SQLiteStorage.factory(options: .init(path: path))
        ))
        // Hydrate load runs in a Task — give it a moment.
        try await Task.sleep(nanoseconds: 100_000_000)

        let read = client2.readFragment(id: "Post:p1", fragment: "fragment P on Post { id title }")
        XCTAssertEqual(read?["title"]?.string, "Persist-me")
        await client2.shutdown()
    }
}
