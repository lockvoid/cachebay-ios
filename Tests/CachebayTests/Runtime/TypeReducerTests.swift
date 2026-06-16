import XCTest
@testable import Cachebay

final class TypeReducerTests: XCTestCase {

    // MARK: - Stack

    private func makeStack(
        typeReducers: [String: EntityReducer] = [:]
    ) -> (Graph, Documents) {
        let graph = Graph(options: GraphOptions(keys: [:], interfaces: [:]))
        let planner = Planner()
        let canonical = Canonical(graph: graph)
        let documents = Documents(
            graph: graph,
            planner: planner,
            canonical: canonical,
            typeReducers: typeReducers
        )
        return (graph, documents)
    }

    private func planFor(_ source: String) throws -> CachePlan {
        try Compiler.compilePlan(source: source)
    }

    // MARK: - Baseline

    func test_no_reducer_registered_behaves_identically_to_default() throws {
        let (graph, documents) = makeStack(typeReducers: [:])
        let plan = try planFor("query Q { chat { id state updatedAt } }")
        documents.normalize(
            plan: plan, variables: [:],
            data: .object([
                "chat": .object([
                    "__typename": "Chat", "id": "1",
                    "state": "idle", "updatedAt": "T2",
                ])
            ]))
        let rec = graph.getRecord("Chat:1") ?? [:]
        XCTAssertEqual(rec["state"]?.string, "idle")
        XCTAssertEqual(rec["updatedAt"]?.string, "T2")
    }

    // MARK: - Context contents

    func test_reducer_receives_id_and_atomic_patch() throws {
        let box = ContextBox()
        let reducer: EntityReducer = { ctx in
            box.record(id: ctx.id, prev: ctx.prev, next: ctx.next)
            return ctx.next
        }
        let (_, documents) = makeStack(typeReducers: ["Chat": reducer])
        let plan = try planFor("query Q { chat { id state updatedAt } }")
        documents.normalize(
            plan: plan, variables: [:],
            data: .object([
                "chat": .object([
                    "__typename": "Chat", "id": "1",
                    "state": "idle", "updatedAt": "T1",
                ])
            ]))
        let calls = box.snapshot()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "1")
        // `prev` is nil for a brand-new entity.
        XCTAssertNil(calls[0].prev)
        // `next` carries the entire entity patch atomically — state AND updatedAt.
        XCTAssertEqual(calls[0].next["state"]?.string, "idle")
        XCTAssertEqual(calls[0].next["updatedAt"]?.string, "T1")
        XCTAssertEqual(calls[0].next["__typename"]?.string, "Chat")
    }

    // MARK: - User's scenario: out-of-order timestamp guard

    func test_reducer_skips_stale_write_when_timestamp_older() throws {
        let reducer: EntityReducer = { ctx in
            guard let prev = ctx.prev else { return ctx.next }
            let pT = prev["updatedAt"]?.string ?? ""
            let nT = ctx.next["updatedAt"]?.string ?? ""
            return nT >= pT ? ctx.next : prev
        }
        let (graph, documents) = makeStack(typeReducers: ["Chat": reducer])
        let plan = try planFor("query Q { chat { id state updatedAt } }")

        // T=2 lands first (newer payload).
        documents.normalize(
            plan: plan, variables: [:],
            data: .object([
                "chat": .object([
                    "__typename": "Chat", "id": "1",
                    "state": "idle", "updatedAt": "T2",
                ])
            ]))
        XCTAssertEqual(graph.getRecord("Chat:1")?["state"]?.string, "idle")

        // T=1 arrives out-of-order — reducer must reject.
        documents.normalize(
            plan: plan, variables: [:],
            data: .object([
                "chat": .object([
                    "__typename": "Chat", "id": "1",
                    "state": "toolCalling", "updatedAt": "T1",
                ])
            ]))
        XCTAssertEqual(
            graph.getRecord("Chat:1")?["state"]?.string, "idle",
            "stale write should not overwrite newer state")
        XCTAssertEqual(graph.getRecord("Chat:1")?["updatedAt"]?.string, "T2")
    }

    // MARK: - Custom merged record

    func test_reducer_can_return_custom_merged_record() throws {
        // Reducer accepts updatedAt updates but refuses to change `state`.
        let reducer: EntityReducer = { ctx in
            var merged = ctx.prev ?? [:]
            for (k, v) in ctx.next {
                if k == "state", ctx.prev?["state"] != nil { continue }
                merged[k] = v
            }
            return merged
        }
        let (graph, documents) = makeStack(typeReducers: ["Chat": reducer])
        let plan = try planFor("query Q { chat { id state updatedAt } }")

        documents.normalize(
            plan: plan, variables: [:],
            data: .object([
                "chat": .object([
                    "__typename": "Chat", "id": "1",
                    "state": "idle", "updatedAt": "T1",
                ])
            ]))
        documents.normalize(
            plan: plan, variables: [:],
            data: .object([
                "chat": .object([
                    "__typename": "Chat", "id": "1",
                    "state": "toolCalling", "updatedAt": "T2",
                ])
            ]))
        XCTAssertEqual(
            graph.getRecord("Chat:1")?["state"]?.string, "idle",
            "state field protected by custom reducer")
        XCTAssertEqual(
            graph.getRecord("Chat:1")?["updatedAt"]?.string, "T2",
            "updatedAt field allowed through")
    }

    // MARK: - Per-type opt-in

    func test_other_types_unaffected_when_reducer_only_registered_for_one() throws {
        // Chat reducer rejects everything; User has no reducer.
        let reducer: EntityReducer = { ctx in ctx.prev ?? ctx.next }
        let (graph, documents) = makeStack(typeReducers: ["Chat": reducer])
        let plan = try planFor(
            """
                query Q {
                    chat { id state }
                    user { id name }
                }
            """)
        documents.normalize(
            plan: plan, variables: [:],
            data: .object([
                "chat": .object(["__typename": "Chat", "id": "1", "state": "first"]),
                "user": .object(["__typename": "User", "id": "u1", "name": "alice"]),
            ]))
        XCTAssertEqual(graph.getRecord("Chat:1")?["state"]?.string, "first")
        XCTAssertEqual(graph.getRecord("User:u1")?["name"]?.string, "alice")

        documents.normalize(
            plan: plan, variables: [:],
            data: .object([
                "chat": .object(["__typename": "Chat", "id": "1", "state": "second"]),
                "user": .object(["__typename": "User", "id": "u1", "name": "bob"]),
            ]))
        XCTAssertEqual(
            graph.getRecord("Chat:1")?["state"]?.string, "first",
            "Chat reducer protected the record")
        XCTAssertEqual(
            graph.getRecord("User:u1")?["name"]?.string, "bob",
            "User write proceeded normally (no reducer registered)")
    }

    // MARK: - Reducer sees the merged candidate, not the raw partial patch

    func test_reducer_next_is_merge_candidate_including_existing_fields() throws {
        // The user's resolver needs to inspect a field that wasn't in the
        // current wire payload but is in the stored record (e.g. comparing
        // a server-only field). `next` must contain the merge candidate —
        // existing fields preserved + incoming fields layered on top.
        let captured = ContextBox()
        let reducer: EntityReducer = { ctx in
            captured.record(id: ctx.id, prev: ctx.prev, next: ctx.next)
            return ctx.next
        }
        let (_, documents) = makeStack(typeReducers: ["Chat": reducer])
        let planFull = try planFor("query Q { chat { id state updatedAt activeRole } }")
        let planPartial = try planFor("query Q { chat { id state } }")

        documents.normalize(
            plan: planFull, variables: [:],
            data: .object([
                "chat": .object([
                    "__typename": "Chat", "id": "1",
                    "state": "idle", "updatedAt": "T1", "activeRole": "user",
                ])
            ]))
        documents.normalize(
            plan: planPartial, variables: [:],
            data: .object([
                "chat": .object([
                    "__typename": "Chat", "id": "1",
                    "state": "thinking",
                ])
            ]))
        let calls = captured.snapshot()
        XCTAssertEqual(calls.count, 2)
        // Second call: prev has full record, next has merged candidate.
        XCTAssertEqual(calls[1].prev?["activeRole"]?.string, "user")
        XCTAssertEqual(calls[1].next["state"]?.string, "thinking")
        XCTAssertEqual(
            calls[1].next["activeRole"]?.string, "user",
            "next must include fields from prev that aren't in the partial payload")
        XCTAssertEqual(
            calls[1].next["updatedAt"]?.string, "T1",
            "next must include fields from prev that aren't in the partial payload")
    }

    // MARK: - Client-level: reducer-reject suppresses watcher emit

    func test_reducer_returns_prev_does_not_emit_to_watcher() async throws {
        let reducer: EntityReducer = { ctx in
            // Reject any second write — always keep prev once it exists.
            ctx.prev ?? ctx.next
        }
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0,
                typeReducers: ["Chat": reducer]
            ))

        let q = "query GetChat($id: ID!) { chat(id: $id) { id state } }"
        try client.writeQuery(
            query: q, variables: ["id": "1"],
            data: .object([
                "chat": .object(["__typename": "Chat", "id": "1", "state": "idle"])
            ]))

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: q,
            options: WatchQueryOptions(
                variables: ["id": "1"],
                immediate: true,
                onData: { received.append($0) }
            )
        )
        XCTAssertEqual(received.value.count, 1)
        XCTAssertEqual(received.value[0]["chat"]?["state"]?.string, "idle")

        // Second wire-shaped write: reducer rejects → record unchanged →
        // watcher must NOT emit.
        try client.writeQuery(
            query: q, variables: ["id": "1"],
            data: .object([
                "chat": .object(["__typename": "Chat", "id": "1", "state": "toolCalling"])
            ]))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(
            received.value.count, 1,
            "rejected write must not produce a watcher emit")
        XCTAssertEqual(client.graph.getRecord("Chat:1")?["state"]?.string, "idle")
        handle.unsubscribe()
    }

    // MARK: - Client-level: optimistic writes bypass the reducer

    func test_optimistic_writes_bypass_reducer() throws {
        // Reducer rejects every wire write. Optimistic patches must
        // still land because they don't go through Documents.normalize.
        let reducer: EntityReducer = { ctx in ctx.prev ?? ctx.next }
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0,
                typeReducers: ["Chat": reducer]
            ))

        // Seed an initial state via wire write — first one passes (prev=nil).
        let q = "query Q($id: ID!) { chat(id: $id) { id state } }"
        try client.writeQuery(
            query: q, variables: ["id": "1"],
            data: .object([
                "chat": .object(["__typename": "Chat", "id": "1", "state": "idle"])
            ]))
        XCTAssertEqual(client.graph.getRecord("Chat:1")?["state"]?.string, "idle")

        // Wire write rejected by reducer.
        try client.writeQuery(
            query: q, variables: ["id": "1"],
            data: .object([
                "chat": .object(["__typename": "Chat", "id": "1", "state": "rejected-by-reducer"])
            ]))
        XCTAssertEqual(client.graph.getRecord("Chat:1")?["state"]?.string, "idle")

        // Optimistic patch must bypass and land.
        client.modifyOptimistic { b in
            b.patch(.key("Chat:1"), ["state": .string("optimistic-state")], mode: .merge)
        }.dispose()
        XCTAssertEqual(
            client.graph.getRecord("Chat:1")?["state"]?.string, "optimistic-state",
            "optimistic writes must bypass the type reducer")
    }

    // MARK: - Fragment writes hit the reducer too

    func test_fragment_write_path_invokes_reducer() throws {
        let captured = ContextBox()
        let reducer: EntityReducer = { ctx in
            captured.record(id: ctx.id, prev: ctx.prev, next: ctx.next)
            return ctx.next
        }
        let (graph, documents) = makeStack(typeReducers: ["Chat": reducer])
        let planner = Planner()
        let fragments = Fragments(planner: planner, documents: documents)

        let plan = try planFor("fragment ChatBits on Chat { id state }")
        try fragments.writeFragment(
            plan: plan,
            rootId: "Chat:1",
            variables: [:],
            data: .object(["__typename": "Chat", "id": "1", "state": "idle"])
        )
        XCTAssertEqual(captured.snapshot().count, 1)
        XCTAssertEqual(graph.getRecord("Chat:1")?["state"]?.string, "idle")
    }
}

// MARK: - Context capture helper

private final class ContextBox: @unchecked Sendable {
    struct Call {
        let id: String
        let prev: [String: JSONValue]?
        let next: [String: JSONValue]
    }
    private let lock = NSLock()
    private var calls: [Call] = []
    func record(id: String, prev: [String: JSONValue]?, next: [String: JSONValue]) {
        lock.lock(); defer { lock.unlock() }
        calls.append(.init(id: id, prev: prev, next: next))
    }
    func snapshot() -> [Call] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}
