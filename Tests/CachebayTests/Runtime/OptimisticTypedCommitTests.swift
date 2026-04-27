import XCTest
@testable import Cachebay

/// `OptimisticTransaction.commit<O: OperationData>(_:)` — typed
/// overload that wraps a typed mutation/operation response into the
/// `JSONValue.object` shape the underlying `commit(_:)` closure
/// expects. Without this, callers had to write
/// `.commit(result.data.map { .object($0.__data) })` manually, OR
/// `.commit(nil)` and silently discard the server data.
///
/// The typed overload is the supported path for committing with
/// server data — it makes the call site one line and ensures the
/// builder closure's `BuilderContext.data` sees the canonical
/// response during the replay-commit cycle.
final class OptimisticTypedCommitTests: XCTestCase {

    // Synthetic OperationData for the test — mimics what cachebay-cli
    // emits for a mutation's `Data` struct.
    private struct FakeMutationData: OperationData {
        let __data: [String: JSONValue]
        init(__data: [String: JSONValue]) { self.__data = __data }
    }

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    /// The closure's `BuilderContext.data` must receive the typed
    /// response's `.object(__data)` during the replay-commit phase
    /// when commit is called with a typed `OperationData?`.
    func test_typedCommit_passesServerDataToBuilderContext() {
        let client = makeClient()
        let phaseRecord = PhaseDataRecord()

        let tx = client.modifyOptimistic { _, ctx in
            phaseRecord.record(phase: ctx.phase, data: ctx.data)
        }
        // Typed response — what callers actually have from
        // `result.data` after `executeMutation(...)`.
        let typedResponse = FakeMutationData(__data: [
            "createPost": .object([
                CachebayConstants.typenameField: .string("Post"),
                "id": .string("p1"),
                "title": .string("Server"),
            ]),
        ])
        tx.commit(typedResponse)

        // Two phases: .optimistic (data: nil) then .commit (data: typedResponse wrapped).
        let entries = phaseRecord.snapshot()
        XCTAssertEqual(entries.count, 2, "builder must run at .optimistic and .commit")
        XCTAssertEqual(entries[0].phase, .optimistic)
        XCTAssertNil(entries[0].data, "optimistic phase must see data: nil")
        XCTAssertEqual(entries[1].phase, .commit)
        // Commit phase must see typed __data wrapped into .object(...).
        if case .object(let obj) = entries[1].data {
            XCTAssertEqual(obj["createPost"]?["title"]?.string, "Server",
                           "commit phase must see the typed response data")
        } else {
            XCTFail("commit data should be .object, got \(String(describing: entries[1].data))")
        }
    }

    /// Passing `nil` to the typed overload must behave identically to
    /// the JSONValue overload's nil — used when there's no server
    /// response (e.g. error path) or the optimistic ops are already
    /// idempotent against the eventual server state.
    func test_typedCommit_nilPassthrough_equivalentToJSONValueNil() {
        let client = makeClient()
        let phaseRecord = PhaseDataRecord()

        let tx = client.modifyOptimistic { _, ctx in
            phaseRecord.record(phase: ctx.phase, data: ctx.data)
        }
        let nilResponse: FakeMutationData? = nil
        tx.commit(nilResponse)

        let entries = phaseRecord.snapshot()
        XCTAssertEqual(entries.count, 2)
        XCTAssertNil(entries[0].data)
        XCTAssertNil(entries[1].data, "typed nil must pass through as nil to commit phase")
    }

    /// The typed overload must NOT shadow the existing
    /// `JSONValue?`-shaped commit closure — both paths stay callable
    /// for callers that already have a JSONValue (rare, but supported).
    func test_typedCommit_doesNotShadowJSONValueOverload() {
        let client = makeClient()
        let phaseRecord = PhaseDataRecord()

        let tx = client.modifyOptimistic { _, ctx in
            phaseRecord.record(phase: ctx.phase, data: ctx.data)
        }
        // Direct JSONValue commit — the original API surface.
        tx.commit(JSONValue.object(["fromJSONValue": .bool(true)]))

        let entries = phaseRecord.snapshot()
        XCTAssertEqual(entries.count, 2)
        if case .object(let obj) = entries[1].data {
            XCTAssertEqual(obj["fromJSONValue"]?.bool, true)
        } else {
            XCTFail("JSONValue commit dropped during commit phase")
        }
    }
}

// MARK: - Sendable closure capture box

/// Records `BuilderContext`-shaped events crossing the @Sendable
/// boundary safely. Local helper for `OptimisticTypedCommitTests`.
private final class PhaseDataRecord: @unchecked Sendable {
    struct Entry: Sendable {
        let phase: BuilderPhase
        let data: JSONValue?
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    func record(phase: BuilderPhase, data: JSONValue?) {
        lock.lock(); defer { lock.unlock() }
        entries.append(Entry(phase: phase, data: data))
    }
    func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }
}
