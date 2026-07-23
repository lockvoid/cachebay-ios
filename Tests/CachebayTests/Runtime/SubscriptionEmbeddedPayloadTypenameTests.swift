import XCTest
@testable import Cachebay

/// REPRODUCTION — Ferment "bolt panel blind to generation cooks" bug.
///
/// The real `processorManNetworkChanged` subscription delivers an ENTITY
/// payload (`ProcessorManNetworkChangedPayload` — it has `id`) whose `network`
/// field is a SINGULAR EMBEDDED object (ProcessorManNetwork has no id),
/// selected through a fragment spread that includes `__typename`, holding an
/// embedded LIST of operators.
///
/// Field evidence from the live dev cache (2026-07-23): the subscription-path
/// normalizer wrote `ProcessorManNetworkChangedPayload:119.network` WITHOUT
/// `__typename` while the same frame's list items
/// (`…network.operators.N`) kept theirs. `__typename` is a selected field, so
/// the per-frame materialize then misses → `event.data` nil → the app's
/// handler silently `continue`s — every topology event of the session dropped.
final class SubscriptionEmbeddedPayloadTypenameTests: XCTestCase {

    /// Mirrors the wire query VERBATIM in structure: the embedded `network`
    /// subtree is reached through a FRAGMENT SPREAD (`...NetFields`), with
    /// `__typename` selected both at the spread site and inside the fragment —
    /// exactly what the app's planner emits for
    /// `ProcessorManNetworkChangedSubscription.graphql`.
    private let subscription = """
    subscription NC {
      thingChanged {
        __typename
        operation
        id
        network {
          __typename
          ...NetFields
        }
      }
    }
    fragment NetFields on ProcessorManNetwork {
      __typename
      recordType
      recordId
      operators {
        __typename
        key
        cookKey
      }
    }
    """

    private func frame(operators: [(key: String, cookKey: String)]) -> JSONValue {
        .object([
            "thingChanged": .object([
                "__typename": "ThingChangedPayload",
                "operation": "UPDATED",
                "id": "119",
                "network": .object([
                    "__typename": "ProcessorManNetwork",
                    "recordType": "Project",
                    "recordId": "67",
                    "operators": .array(operators.map { op in
                        .object([
                            "__typename": "ProcessorManOperator",
                            "key": .string(op.key),
                            "cookKey": .string(op.cookKey),
                        ])
                    }),
                ]),
            ])
        ])
    }

    /// Frame 1 must materialize with the full `network` subtree — including
    /// `__typename` on the singular embedded object — and the cache record
    /// backing it must retain `__typename` for every later re-materialize.
    func test_entityPayload_singularEmbed_keepsTypename_andMaterializes() async throws {
        let staged = StagedWSTransport()
        let client = CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport(), ws: staged),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))

        let stream = try client.executeSubscription(query: subscription)
        let task = Task { @Sendable in
            var networks: [[String: JSONValue]] = []
            var errors: [String] = []
            do {
                for try await event in stream {
                    if let n = event.data?["thingChanged"]?["network"]?.object { networks.append(n) }
                    if let e = event.error?.networkError { errors.append(e) }
                }
            } catch { /* OK */ }
            return (networks, errors)
        }
        try await staged.awaitSubscribed()

        // Frame 1 — the 15:59:10 event: one operator on the base network.
        staged.emit(frame(operators: [(key: "op-a", cookKey: "pmck/Project/67/op-a")]))
        // Frame 2 — the 16:11:27 event: the SAME payload entity again, one
        // operator added (the generation the bolt panel never saw).
        staged.emit(frame(operators: [
            (key: "op-a", cookKey: "pmck/Project/67/op-a"),
            (key: "op-b", cookKey: "pmck/Project/67/op-b"),
        ]))
        staged.finish()

        let (networks, errors) = await task.value

        // The singular embed's cache record must keep the selected __typename.
        let embed = client.graph.getRecord("ThingChangedPayload:119.network")
        XCTAssertEqual(
            embed?["__typename"]?.string, "ProcessorManNetwork",
            "singular embedded object under an entity payload must retain __typename in the cache; got \(embed ?? [:])"
        )

        // BOTH frames must reach the consumer with the network subtree intact.
        XCTAssertEqual(errors, [String](), "no frame may degrade to an error frame")
        XCTAssertEqual(networks.count, 2, "both frames must deliver data — a silent nil here is the app's dropped topology event")
        XCTAssertEqual(networks.first?["__typename"]?.string, "ProcessorManNetwork")
        XCTAssertEqual(networks.first?["operators"]?.array?.count, 1)
        XCTAssertEqual(networks.last?["operators"]?.array?.count, 2, "frame 2 must carry the ADDED operator — this is the generation the jobs panel never saw")
    }
}
