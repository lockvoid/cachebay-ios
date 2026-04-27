import XCTest
@testable import Cachebay

/// Web parity for `core/optimistic.ts` Entity Operations: covers gaps the
/// existing iOS suite missed — closure-form `patch(target, mode:, _ build:)`
/// (read-modify-write), `revert` after `commit` is a no-op for entities,
/// and the "object identity" form `b.delete(.object(...))` / patch via
/// `.object(...)` ref.
final class OptimisticEntityTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    // MARK: - patch via object ref (typename + id)

    func test_patch_objectRef_resolvesToCanonicalKey() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p1", "title": "Old"])
        )

        client.modifyOptimistic { b, _ in
            b.patch(.object(["__typename": "Post", "id": "p1"]),
                    ["title": .string("New")], mode: .merge)
        }.commit(nil)

        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "New")
    }

    // MARK: - closure-form patch

    func test_patch_closureForm_seesPriorSnapshot() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p1", "title": "Post 1"])
        )

        client.modifyOptimistic { b, _ in
            b.patch(.key("Post:p1"), mode: .merge) { prev in
                let title = prev["title"]?.string ?? ""
                return ["title": .string(title + "!")]
            }
        }.commit(nil)

        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Post 1!",
            "closure-form patch should see the cached prior snapshot")
    }

    func test_patch_closureForm_revertRestores() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "User:7",
            fragment: "fragment U on User { id name }",
            data: .object(["__typename": "User", "id": "7", "name": "Old"])
        )

        let tx = client.modifyOptimistic { b, _ in
            b.patch(.key("User:7"), mode: .merge) { prev in
                let name = prev["name"]?.string ?? ""
                return ["name": .string(name + "-modified")]
            }
        }
        XCTAssertEqual(client.graph.getField("User:7", "name")?.string, "Old-modified")

        tx.revert()
        XCTAssertEqual(client.graph.getField("User:7", "name")?.string, "Old")
    }

    func test_patch_closureForm_emptyResult_isNoOp() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "Post:p1",
            fragment: "fragment P on Post { id title }",
            data: .object(["__typename": "Post", "id": "p1", "title": "Stable"])
        )

        // Closure returns empty dict — should be treated as no-op.
        client.modifyOptimistic { b, _ in
            b.patch(.key("Post:p1"), mode: .merge) { _ in [:] }
        }.commit(nil)

        XCTAssertEqual(client.graph.getField("Post:p1", "title")?.string, "Stable")
    }

    // MARK: - delete revert-after-commit no-op

    func test_delete_revertAfterCommit_isNoOp() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "User:9",
            fragment: "fragment U on User { id email }",
            data: .object(["__typename": "User", "id": "9", "email": "x@x.com"])
        )

        let tx = client.modifyOptimistic { b, _ in
            b.delete(.key("User:9"))
        }
        XCTAssertNil(client.graph.getRecord("User:9"))

        tx.commit(nil)
        // After commit, the record is gone permanently. revert is a no-op.
        tx.revert()
        XCTAssertNil(client.graph.getRecord("User:9"),
            "revert after commit must NOT restore the record")
    }

    // MARK: - patch revert-after-commit no-op (web: ignores revert after commit)

    func test_patch_revertAfterCommit_isNoOp() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "User:7",
            fragment: "fragment U on User { id name }",
            data: .object(["__typename": "User", "id": "7", "name": "Old"])
        )

        let tx = client.modifyOptimistic { b, _ in
            b.patch(.key("User:7"), ["name": .string("New")], mode: .merge)
        }
        tx.commit(nil)
        tx.revert()

        XCTAssertEqual(client.graph.getField("User:7", "name")?.string, "New",
            "after commit, revert must not roll back the entity")
    }

    // MARK: - delete via object ref

    func test_delete_objectRef_removesEntity() throws {
        let client = makeClient()
        try client.writeFragment(
            id: "User:9",
            fragment: "fragment U on User { id email }",
            data: .object(["__typename": "User", "id": "9", "email": "x@x.com"])
        )

        client.modifyOptimistic { b, _ in
            b.delete(.object(["__typename": "User", "id": "9"]))
        }.commit(nil)

        XCTAssertNil(client.graph.getRecord("User:9"))
    }
}
