import XCTest
@testable import Cachebay

/// The empty-list-after-create bug, at the cache layer.
///
/// Scenario (exactly the ferment-cuts repro): a populated connection is on screen,
/// the user creates an item, the app optimistically `linkNode`s it. The synthesized
/// optimistic edge must stay **decodable by the generated edge struct** — which
/// guards the edge `__typename` and requires a non-null `cursor`. If the edge is
/// undecodable, the list's fail-all decode drops the WHOLE connection and the
/// watcher emits an empty list (then restart shows it correctly, because the server
/// page has real edges).
///
/// Two properties make the optimistic edge decodable:
///   • it inherits the connection's REAL edge `__typename` (not the `<Node>Edge`
///     guess, which only coincidentally matches schemas like "SpellEdge" and breaks
///     for connection-specific names like "QueryProjectsConnectionEdge");
///   • it carries a synthetic `cursor`.
///
/// (That a missing cursor / mismatched typename is what kills the typed decode is
/// pinned separately in `DiagnosticsBehaviourTests`.)
final class OptimisticEdgeDecodabilityTests: XCTestCase {

    private let canonicalKey: CacheKey = "@connection.projects({})"

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    /// Seed a connection that already holds two server edges whose edge type is the
    /// schema's connection-specific edge name (NOT "<Node>Edge").
    private func seedServerConnection(_ client: CachebayClient, edgeTypename: String) {
        for id in ["1", "2"] {
            client.graph.replaceRecord("Project:\(id)", [
                CachebayConstants.typenameField: .string("Project"),
                "id": .string(id),
            ])
            client.graph.replaceRecord("srvEdge\(id)", [
                CachebayConstants.typenameField: .string(edgeTypename),
                "cursor": .string("c\(id)"),
                CachebayConstants.connectionNodeField: .ref("Project:\(id)"),
            ])
        }
        client.graph.replaceRecord(canonicalKey, [
            CachebayConstants.typenameField: .string(CachebayConstants.connectionTypename),
            CachebayConstants.connectionEdgesField: .refList(["srvEdge1", "srvEdge2"]),
        ])
    }

    private func optimisticallyLinkProject3(_ client: CachebayClient) {
        client.modifyOptimistic { b in
            b.connection(ConnectionSelector(key: "projects"))
                .linkNode(.object([
                    CachebayConstants.typenameField: .string("Project"),
                    "id": .string("3"),
                ]), options: LinkNodeOptions(position: .start))
        }.dispose()
    }

    func test_optimisticEdge_inheritsRealEdgeTypename_andHasCursor() throws {
        let client = makeClient()
        seedServerConnection(client, edgeTypename: "QueryProjectsConnectionEdge")

        optimisticallyLinkProject3(client)

        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        XCTAssertEqual(edges.count, 3, "optimistic edge must be inserted (not blanked)")

        let newEdge = try XCTUnwrap(client.graph.getRecord(edges[0]), "new edge is prepended at .start")
        // Inherited real edge typename, NOT the "ProjectEdge" guess -> guard passes.
        XCTAssertEqual(
            newEdge[CachebayConstants.typenameField]?.string, "QueryProjectsConnectionEdge",
            "edge must inherit the connection's real edge typename, got \(String(describing: newEdge[CachebayConstants.typenameField]))"
        )
        // Synthetic cursor present -> required `cursor: String` decodes.
        XCTAssertNotNil(
            newEdge["cursor"]?.string,
            "edge must carry a synthetic cursor, got \(String(describing: newEdge["cursor"]))"
        )
    }

    /// Schemas that DO name edges "<Node>Edge" keep working (the guess matches the
    /// inherited value here) — this is the demo's "SpellEdge" shape.
    func test_optimisticEdge_nodeEdgeNamedSchema_stillMatches() throws {
        let client = makeClient()
        seedServerConnection(client, edgeTypename: "ProjectEdge")

        optimisticallyLinkProject3(client)

        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        let newEdge = try XCTUnwrap(client.graph.getRecord(edges[0]))
        XCTAssertEqual(newEdge[CachebayConstants.typenameField]?.string, "ProjectEdge")
        XCTAssertNotNil(newEdge["cursor"]?.string)
    }

    /// THE empty-connection case, fixed authoritatively. The connection canonical
    /// was normalized from a schema-derived plan that stamped the edge type name on
    /// it — so even with NO sibling edge, the optimistic edge inherits the real edge
    /// `__typename` (not the `<Node>Edge` guess). This is the schema-as-source-of-
    /// truth path: the CLI knows the edge type, stamps it via the plan, insertEdge
    /// reads it.
    func test_optimisticEdge_emptyConnection_usesStampedEdgeTypename() throws {
        let client = makeClient()
        client.graph.replaceRecord("Project:3", [
            CachebayConstants.typenameField: .string("Project"), "id": .string("3"),
        ])
        // Empty connection, but stamped with its authoritative edge type (what
        // `Canonical.updateConnection` writes from the plan on normalize).
        client.graph.replaceRecord(canonicalKey, [
            CachebayConstants.typenameField: .string(CachebayConstants.connectionTypename),
            CachebayConstants.connectionEdgesField: .refList([]),
            CachebayConstants.connectionEdgeTypenameField: .string("QueryProjectsConnectionEdge"),
        ])

        optimisticallyLinkProject3(client)

        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        let newEdge = try XCTUnwrap(client.graph.getRecord(edges[0]))
        XCTAssertEqual(
            newEdge[CachebayConstants.typenameField]?.string, "QueryProjectsConnectionEdge",
            "empty connection must use the stamped edge typename, got \(String(describing: newEdge[CachebayConstants.typenameField]))"
        )
        XCTAssertNotNil(newEdge["cursor"]?.string)
    }

    /// A truly bare connection (never normalized -> no stamp, no sibling) still
    /// degrades to the best-effort "<Node>Edge" guess — now LOUD via diagnostics,
    /// not silent.
    func test_optimisticEdge_unstampedEmptyConnection_fallsBackToGuess() throws {
        let client = makeClient()
        client.graph.replaceRecord("Project:3", [
            CachebayConstants.typenameField: .string("Project"), "id": .string("3"),
        ])
        optimisticallyLinkProject3(client)

        let edges = client.graph.getField(canonicalKey, CachebayConstants.connectionEdgesField)?.refList ?? []
        let newEdge = try XCTUnwrap(client.graph.getRecord(edges[0]))
        XCTAssertEqual(newEdge[CachebayConstants.typenameField]?.string, "ProjectEdge")
        XCTAssertNotNil(newEdge["cursor"]?.string)
    }
}

/// The schema → cache half of the fix: a codegen plan carries the connection's
/// edge type (`PlanField.connectionEdgeTypename`), and `Canonical.updateConnection`
/// stamps it onto the canonical when the connection is normalized — even an EMPTY
/// page — so a later optimistic `insertEdge` has the authoritative type to use.
final class ConnectionEdgeTypenameStampTests: XCTestCase {

    private func connectionField(edgeTypename: String?) -> PlanField {
        let edges = PlanField.make(responseKey: "edges", fieldName: "edges", children: [
            PlanField.make(responseKey: "__typename", fieldName: "__typename"),
            PlanField.make(responseKey: "cursor", fieldName: "cursor"),
            PlanField.make(responseKey: "node", fieldName: "node", children: [
                PlanField.make(responseKey: "__typename", fieldName: "__typename"),
                PlanField.make(responseKey: "id", fieldName: "id"),
            ]),
        ])
        let pageInfo = PlanField.make(responseKey: "pageInfo", fieldName: "pageInfo", children: [
            PlanField.make(responseKey: "__typename", fieldName: "__typename"),
        ])
        return PlanField.make(
            responseKey: "projects", fieldName: "projects",
            isConnection: true, connectionKey: "projects", connectionMode: .page,
            connectionEdgeTypename: edgeTypename,
            children: [edges, pageInfo]
        )
    }

    /// Seeds an EMPTY page record (as normalize would for a connection that
    /// returned zero edges) and runs the canonical merge.
    private func normalizeEmptyPage(_ canonical: Canonical, _ graph: Graph, field: PlanField) -> CacheKey {
        let parentId = CachebayConstants.rootID
        graph.replaceRecord("pi", [CachebayConstants.typenameField: .string("PageInfo")])
        let pageKey: CacheKey = "testPage"
        graph.replaceRecord(pageKey, [
            CachebayConstants.typenameField: .string("QueryProjectsConnection"),
            CachebayConstants.connectionEdgesField: .refList([]),
            CachebayConstants.connectionPageInfoField: .ref("pi"),
        ])
        canonical.updateConnection(field: field, parentId: parentId, variables: [:], pageKey: pageKey)
        return Keys.buildConnectionCanonicalKey(field: field, parentId: parentId, variables: [:])
    }

    func test_updateConnection_stampsEdgeTypenameFromPlan_evenWhenEmpty() {
        let graph = Graph()
        let canonical = Canonical(graph: graph)
        let canonicalKey = normalizeEmptyPage(canonical, graph, field: connectionField(edgeTypename: "QueryProjectsConnectionEdge"))

        XCTAssertEqual(
            graph.getRecord(canonicalKey)?[CachebayConstants.connectionEdgeTypenameField]?.string,
            "QueryProjectsConnectionEdge",
            "the schema edge type must be stamped onto the canonical, even for an empty page"
        )
    }

    /// A runtime-compiled plan has no schema edge type (nil) → no stamp (the
    /// optimistic insert falls back to sibling/guess, which is fine).
    func test_updateConnection_noStamp_whenPlanHasNoEdgeTypename() {
        let graph = Graph()
        let canonical = Canonical(graph: graph)
        let canonicalKey = normalizeEmptyPage(canonical, graph, field: connectionField(edgeTypename: nil))

        XCTAssertNil(graph.getRecord(canonicalKey)?[CachebayConstants.connectionEdgeTypenameField])
    }
}
