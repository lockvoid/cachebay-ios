import XCTest

@testable import Cachebay

/// Investigation (confirm-first): "the thinking blinker lags the optimistic
/// message." The unverified link is whether an OPTIMISTIC patch on a NESTED
/// entity reached via a ref — `Project.chat → Chat:cid`, exactly the
/// `ChatQuery` shape `project { chat { ...ChatFields } }` — synchronously
/// notifies a query watcher that read that nested entity.
///
/// If both tests PASS, cachebay's nested-entity dep-fanout is NOT the lag
/// source → the symptom is app-side. If either FAILS, it's a cachebay bug and
/// these are the red tests that drive the fix.
final class OptimisticNestedEntityNotifyTests: XCTestCase {

    private let query = """
        query GetProject($id: ID!) {
            project(id: $id) { id title chat { id state } }
        }
        """

    /// Thread-safe emit recorder (the watcher `onData` is `@Sendable`).
    private final class Emits: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [JSONValue] = []
        func append(_ v: JSONValue) { lock.lock(); items.append(v); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
        var last: JSONValue? { lock.lock(); defer { lock.unlock() }; return items.last }
        func at(_ i: Int) -> JSONValue { lock.lock(); defer { lock.unlock() }; return items[i] }
    }

    // MARK: - Link 1 (surgical): the nested entity is a tracked dependency

    func test_materialize_records_nested_entity_via_ref_as_dependency() throws {
        let graph = Graph(options: GraphOptions(keys: [:], interfaces: [:]))
        let documents = Documents(graph: graph, planner: Planner(), canonical: Canonical(graph: graph))
        let p = try Compiler.compilePlan(source: query)
        documents.normalize(
            plan: p, variables: ["id": "pid"],
            data: .object([
                "project": .object([
                    "__typename": "Project", "id": "pid", "title": "Demo",
                    "chat": .object(["__typename": "Chat", "id": "cid", "state": "idle"]),
                ])
            ]))
        let res = documents.materialize(plan: p, variables: ["id": "pid"])

        // The entity reached via the `Project.chat` ref MUST be a dependency,
        // or an entity patch on it can never fan out to this watcher.
        XCTAssertTrue(
            res.dependencies.contains("Chat:cid"),
            "nested entity reached via ref must be a tracked dependency; deps=\(res.dependencies)")
        XCTAssertTrue(res.dependencies.contains("Project:pid"))
    }

    // MARK: - Link 2 (behavioral): optimistic nested patch → SYNCHRONOUS emit

    func test_optimistic_patch_on_nested_entity_notifies_watcher_synchronously() throws {
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0))

        try client.writeQuery(
            query: query, variables: ["id": "pid"],
            data: .object([
                "project": .object([
                    "__typename": "Project", "id": "pid", "title": "Demo",
                    "chat": .object(["__typename": "Chat", "id": "cid", "state": "idle"]),
                ])
            ]))

        let emits = Emits()
        let handle = try client.watchQuery(
            query: query,
            options: WatchQueryOptions(
                variables: ["id": "pid"], immediate: true,
                onData: { emits.append($0) }))
        XCTAssertEqual(emits.count, 1, "immediate emit")
        XCTAssertEqual(emits.at(0)["project"]?["chat"]?["state"]?.string, "idle")

        // Optimistic patch on the nested Chat ONLY — mirrors the chat-state flip
        // in ChatMutations.sendMessage (no connection op in this layer).
        let opt = client.modifyOptimistic { b in
            b.patch(.key("Chat:cid"), ["state": .string("thinking")], mode: .merge)
        }

        // SYNCHRONOUS — no sleep. If cachebay fans out the nested-entity patch in
        // the same flush, the watcher has already re-emitted with the new state.
        XCTAssertEqual(
            emits.count, 2,
            "optimistic nested-entity patch must notify the query watcher synchronously (same flush)")
        XCTAssertEqual(emits.last?["project"]?["chat"]?["state"]?.string, "thinking")

        opt.dispose()
        handle.unsubscribe()
    }
}
