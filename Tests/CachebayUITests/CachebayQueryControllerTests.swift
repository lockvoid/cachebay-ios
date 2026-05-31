import XCTest
import Foundation
import CachebayMacros
import CachebayUI
@testable import Cachebay

// WS8 — the observable controller behind @CachebayQuery, tested in isolation
// (the SwiftUI lifecycle needs a host app; the data/reconcile logic is here).

@CachebayData(typename: "")
private struct GetCookData: Sendable, CachebayValue {
    let cook: CookNode?
}

@CachebayData(typename: "Cook")
private struct CookNode: Identifiable, Sendable, Hashable, CachebayValue {
    let __typename: String
    let id: String
    let title: String
}

private struct GetCook: CachebayOperation {
    struct Variables: OperationVariables {
        let id: String
        var __cachebay: [String: JSONValue] { ["id": .string(id)] }
    }
    typealias Data = GetCookData
    static let document: QueryDocument = .source(
        "query GetCook($id: ID!) { cook(id: $id) { __typename id title } }"
    )
}

private struct NoopHTTP: HTTPTransport {
    func execute(_ context: HTTPContext) async throws -> OperationResult<JSONValue> {
        OperationResult<JSONValue>(data: nil)
    }
}

@MainActor
final class CachebayQueryControllerTests: XCTestCase {
    private func makeClient() -> CachebayClient {
        let client = CachebayClient(options: CachebayOptions(transport: Transport(http: NoopHTTP())))
        client.graph.putRecord("Cook:c1", ["__typename": .string("Cook"), "id": .string("c1"), "title": .string("Pasta")])
        client.graph.putRecord("Cook:c2", ["__typename": .string("Cook"), "id": .string("c2"), "title": .string("Soup")])
        client.graph.putRecord(CachebayConstants.rootID, [
            "cook({\"id\":\"c1\"})": .ref("Cook:c1"),
            "cook({\"id\":\"c2\"})": .ref("Cook:c2"),
        ])
        return client
    }

    func test_deliversCacheData_immediately_onMain() {
        let controller = CachebayQueryController<GetCook>()
        controller.sync(client: makeClient(), variables: .init(id: "c1"))
        // Immediate cache emission fires synchronously on the main thread.
        XCTAssertEqual(controller.data?.cook?.title, "Pasta")
        XCTAssertEqual(controller.phase, .loaded)
        XCTAssertNil(controller.error)
    }

    func test_variableSwap_updatesInPlace() {
        let client = makeClient()
        let controller = CachebayQueryController<GetCook>()
        controller.sync(client: client, variables: .init(id: "c1"))
        XCTAssertEqual(controller.data?.cook?.title, "Pasta")
        // Filter-like swap: same watcher, new variables -> handle.update in place.
        controller.sync(client: client, variables: .init(id: "c2"))
        XCTAssertEqual(controller.data?.cook?.title, "Soup")
    }

    func test_idempotentSync_sameVariables_isNoOp() {
        let client = makeClient()
        let controller = CachebayQueryController<GetCook>()
        controller.sync(client: client, variables: .init(id: "c1"))
        controller.sync(client: client, variables: .init(id: "c1"))   // unchanged -> no resubscribe
        XCTAssertEqual(controller.data?.cook?.title, "Pasta")
        XCTAssertEqual(controller.phase, .loaded)
    }

    func test_stop_tearsDown() {
        let client = makeClient()
        let controller = CachebayQueryController<GetCook>()
        controller.sync(client: client, variables: .init(id: "c1"))
        controller.stop()
        // After stop, a fresh sync re-subscribes cleanly.
        controller.sync(client: client, variables: .init(id: "c2"))
        XCTAssertEqual(controller.data?.cook?.title, "Soup")
    }
}
