import XCTest
@testable import Cachebay

/// Hand-port of cachebay-web's `documents-normalize-{queries,mutations,
/// subscriptions,fragments}.test.ts`. Focuses on graph-level shape after
/// normalize: stored records, refs, refLists for entities/connections/edges.
final class DocumentsNormalizeTests: XCTestCase {
    private func makeStack(
        keys: [String: KeyFunction] = [:],
        interfaces: [String: [String]] = [:]
    ) -> (Graph, Documents) {
        let graph = Graph(options: GraphOptions(keys: keys, interfaces: interfaces))
        let planner = Planner()
        let canonical = Canonical(graph: graph)
        let documents = Documents(graph: graph, planner: planner, canonical: canonical)
        return (graph, documents)
    }

    private func planFor(_ source: String) throws -> CachePlan {
        return try Compiler.compilePlan(source: source)
    }

    // MARK: - Primitives

    func test_normalize_string_scalar() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("""
        query Q($id: ID!) {
            entity(id: $id) { id data }
        }
        """)
        documents.normalize(plan: plan, variables: ["id": "e1"], data: .object([
            "entity": .object(["__typename": "Entity", "id": "e1", "data": "string"])
        ]))
        let rec = graph.getRecord("Entity:e1") ?? [:]
        XCTAssertEqual(rec["__typename"]?.string, "Entity")
        XCTAssertEqual(rec["id"]?.string, "e1")
        XCTAssertEqual(rec["data"]?.string, "string")
    }

    func test_normalize_number_scalar() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("query Q($id: ID!) { entity(id: $id) { id data } }")
        documents.normalize(plan: plan, variables: ["id": "e1"], data: .object([
            "entity": .object(["__typename": "Entity", "id": "e1", "data": .int(123)])
        ]))
        XCTAssertEqual(graph.getRecord("Entity:e1")?["data"]?.intValue, 123)
    }

    func test_normalize_boolean_scalar() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("query Q($id: ID!) { entity(id: $id) { id data } }")
        documents.normalize(plan: plan, variables: ["id": "e1"], data: .object([
            "entity": .object(["__typename": "Entity", "id": "e1", "data": .bool(true)])
        ]))
        XCTAssertEqual(graph.getRecord("Entity:e1")?["data"]?.bool, true)
    }

    func test_normalize_null_scalar() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("query Q($id: ID!) { entity(id: $id) { id data } }")
        documents.normalize(plan: plan, variables: ["id": "e1"], data: .object([
            "entity": .object(["__typename": "Entity", "id": "e1", "data": .null])
        ]))
        // `data` is selected as a leaf scalar, so an explicit null on a leaf
        // scalar is stored as `.null` — null link path only applies when the
        // field has a selection set.
        let rec = graph.getRecord("Entity:e1") ?? [:]
        if case .null = rec["data"] { /* ok */ } else {
            XCTFail("expected data == .null, got \(String(describing: rec["data"]))")
        }
    }

    func test_normalize_inline_json_scalar() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("query Q($id: ID!) { entity(id: $id) { id data } }")
        documents.normalize(plan: plan, variables: ["id": "e1"], data: .object([
            "entity": .object([
                "__typename": "Entity",
                "id": "e1",
                "data": .object(["foo": .object(["bar": "baz"])])
            ])
        ]))
        // No selection set on `data` — stored as inline JSON object.
        let rec = graph.getRecord("Entity:e1") ?? [:]
        let dataObj = rec["data"]?.object ?? [:]
        XCTAssertEqual(dataObj["foo"]?["bar"]?.string, "baz")
    }

    // MARK: - Aliases

    func test_aliased_field_with_args_uses_separate_storage_key() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("""
        query Q($id: ID!) {
            entity(id: $id) {
                id
                dataUrl
                previewUrl: dataUrl(variant: "preview")
            }
        }
        """)
        documents.normalize(plan: plan, variables: ["id": "e1"], data: .object([
            "entity": .object([
                "__typename": "Entity",
                "id": "e1",
                "dataUrl": "1",
                "previewUrl": "2",
            ])
        ]))
        let rec = graph.getRecord("Entity:e1") ?? [:]
        XCTAssertEqual(rec["dataUrl"]?.string, "1")
        XCTAssertEqual(rec["dataUrl({\"variant\":\"preview\"})"]?.string, "2")
    }

    // MARK: - Connections

    func test_root_connection_writes_per_page_records_and_canonical() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("""
        query Q($role: String!, $first: Int, $after: String) {
            users(role: $role, first: $first, after: $after) @connection(filter: ["role"]) {
                pageInfo { startCursor endCursor hasNextPage hasPreviousPage }
                edges { cursor node { id email } }
            }
        }
        """)

        let firstVars: [String: JSONValue] = ["role": "admin", "first": 2, "after": .null]
        documents.normalize(plan: plan, variables: firstVars, data: .object([
            "users": .object([
                "__typename": "UserConnection",
                "pageInfo": .object([
                    "__typename": "PageInfo",
                    "startCursor": "u1", "endCursor": "u2",
                    "hasNextPage": true, "hasPreviousPage": false,
                ]),
                "edges": .array([
                    .object(["__typename": "UserEdge", "cursor": "u1", "node": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])]),
                    .object(["__typename": "UserEdge", "cursor": "u2", "node": .object(["__typename": "User", "id": "u2", "email": "u2@example.com"])]),
                ]),
            ])
        ]))

        let secondVars: [String: JSONValue] = ["role": "admin", "first": 2, "after": "u2"]
        documents.normalize(plan: plan, variables: secondVars, data: .object([
            "users": .object([
                "__typename": "UserConnection",
                "pageInfo": .object([
                    "__typename": "PageInfo",
                    "startCursor": "u3", "endCursor": "u3",
                    "hasNextPage": false, "hasPreviousPage": true,
                ]),
                "edges": .array([
                    .object(["__typename": "UserEdge", "cursor": "u3", "node": .object(["__typename": "User", "id": "u3", "email": "u3@example.com"])]),
                ]),
            ])
        ]))

        let pageKey1 = "@.users({\"role\":\"admin\",\"first\":2,\"after\":null})"
        let pageKey2 = "@.users({\"role\":\"admin\",\"first\":2,\"after\":\"u2\"})"
        let canonicalKey = "@connection.users({\"role\":\"admin\"})"

        let page1 = graph.getRecord(pageKey1) ?? [:]
        XCTAssertEqual(page1["__typename"]?.string, "UserConnection")
        XCTAssertEqual(page1["edges"]?.refList ?? [], [
            "\(pageKey1).edges.0",
            "\(pageKey1).edges.1",
        ])
        XCTAssertEqual(page1["pageInfo"]?.ref, "\(pageKey1).pageInfo")

        let edge0 = graph.getRecord("\(pageKey1).edges.0") ?? [:]
        XCTAssertEqual(edge0["__typename"]?.string, "UserEdge")
        XCTAssertEqual(edge0["cursor"]?.string, "u1")
        XCTAssertEqual(edge0["node"]?.ref, "User:u1")

        let page2 = graph.getRecord(pageKey2) ?? [:]
        XCTAssertEqual(page2["edges"]?.refList ?? [], ["\(pageKey2).edges.0"])

        // Canonical merges both pages.
        let canonical = graph.getRecord(canonicalKey) ?? [:]
        XCTAssertEqual(canonical["__typename"]?.string, "UserConnection")
        XCTAssertEqual(canonical["edges"]?.refList ?? [], [
            "\(pageKey1).edges.0",
            "\(pageKey1).edges.1",
            "\(pageKey2).edges.0",
        ])
    }

    func test_normalizes_arrays_of_entities() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("""
        query Q($id: ID!) {
            post(id: $id) {
                id
                title
                tags { id name }
            }
        }
        """)
        documents.normalize(plan: plan, variables: ["id": "p1"], data: .object([
            "post": .object([
                "__typename": "Post",
                "id": "p1",
                "title": "Post 1",
                "tags": .array([
                    .object(["__typename": "Tag", "id": "t1", "name": "Tag 1"]),
                    .object(["__typename": "Tag", "id": "t2", "name": "Tag 2"]),
                ]),
            ])
        ]))

        XCTAssertEqual(graph.getRecord("Post:p1")?["tags"]?.refList ?? [], ["Tag:t1", "Tag:t2"])
        XCTAssertEqual(graph.getRecord("Tag:t1")?["name"]?.string, "Tag 1")
        XCTAssertEqual(graph.getRecord("Tag:t2")?["name"]?.string, "Tag 2")
    }

    func test_custom_key_function_indexes_entity_by_slug() throws {
        let (graph, documents) = makeStack(keys: [
            "Profile": { _, obj in obj["slug"]?.string }
        ])
        let plan = try planFor("""
        query Profile($slug: String!) {
            profile(slug: $slug) { slug name }
        }
        """)
        documents.normalize(plan: plan, variables: ["slug": "dimitri"], data: .object([
            "profile": .object([
                "__typename": "Profile",
                "slug": "dimitri",
                "name": "Dimitri",
            ])
        ]))
        let rec = graph.getRecord("Profile:dimitri") ?? [:]
        XCTAssertEqual(rec["name"]?.string, "Dimitri")

        // No canonical connection should have been created for a single-entity query.
        for k in graph.keysList() {
            XCTAssertFalse(k.hasPrefix("@connection"), "unexpected canonical key \(k)")
        }
    }

    // MARK: - Mutations with rootId

    func test_mutation_with_rootId_links_field_under_mutation_root() throws {
        let (graph, documents) = makeStack(keys: ["User": { _, obj in obj["id"]?.string }])
        let plan = try planFor("""
        mutation UpdateUser($input: UpdateUserInput!) {
            updateUser(input: $input) {
                user { id email }
            }
        }
        """)
        let vars: [String: JSONValue] = ["input": .object(["id": "u1", "email": "updated@example.com"])]
        documents.normalize(plan: plan, variables: vars, data: .object([
            "updateUser": .object([
                "__typename": "UpdateUserPayload",
                "user": .object(["__typename": "User", "id": "u1", "email": "updated@example.com"])
            ])
        ]), rootId: "@mutation.0")

        XCTAssertEqual(graph.getRecord("User:u1")?["email"]?.string, "updated@example.com")
        let mutationRoot = graph.getRecord("@mutation.0") ?? [:]
        XCTAssertEqual(mutationRoot["__typename"]?.string, "@mutation.0")
        // The mutation root must have at least one updateUser-keyed field that
        // links to the payload record. We don't pin the exact JSON encoding of
        // the input arg (whitespace/key order is implementation detail).
        let updateUserField = mutationRoot.keys.first { $0.hasPrefix("updateUser(") }
        XCTAssertNotNil(updateUserField, "expected an updateUser(...) field on @mutation.0")
        if let fk = updateUserField, case .ref = mutationRoot[fk] {
            // ok — field links via ref
        } else if let fk = updateUserField {
            XCTFail("expected ref link on field \(fk), got \(String(describing: mutationRoot[fk]))")
        }
    }

    func test_mutation_with_rootId_does_not_pollute_query_root() throws {
        let (graph, documents) = makeStack(keys: ["User": { _, obj in obj["id"]?.string }])
        let plan = try planFor("""
        mutation UpdateUser($input: UpdateUserInput!) {
            updateUser(input: $input) { user { id email } }
        }
        """)
        documents.normalize(
            plan: plan,
            variables: ["input": .object(["id": "u1", "email": "x@x.com"])],
            data: .object([
                "updateUser": .object([
                    "__typename": "UpdateUserPayload",
                    "user": .object(["__typename": "User", "id": "u1", "email": "x@x.com"])
                ])
            ]),
            rootId: "@mutation.0"
        )

        let queryRoot = graph.getRecord("@") ?? [:]
        for key in queryRoot.keys {
            XCTAssertFalse(key.contains("updateUser"), "unexpected updateUser field under @ root: \(key)")
        }
        XCTAssertNotNil(graph.getRecord("@mutation.0"))
    }

    func test_multiple_mutations_with_distinct_rootIds_create_separate_records() throws {
        let (graph, documents) = makeStack(keys: ["User": { _, obj in obj["id"]?.string }])
        let plan = try planFor("""
        mutation UpdateUser($input: UpdateUserInput!) {
            updateUser(input: $input) { user { id email } }
        }
        """)

        documents.normalize(
            plan: plan,
            variables: ["input": .object(["id": "u1", "email": "first@example.com"])],
            data: .object([
                "updateUser": .object([
                    "__typename": "UpdateUserPayload",
                    "user": .object(["__typename": "User", "id": "u1", "email": "first@example.com"])
                ])
            ]),
            rootId: "@mutation.0"
        )
        documents.normalize(
            plan: plan,
            variables: ["input": .object(["id": "u2", "email": "second@example.com"])],
            data: .object([
                "updateUser": .object([
                    "__typename": "UpdateUserPayload",
                    "user": .object(["__typename": "User", "id": "u2", "email": "second@example.com"])
                ])
            ]),
            rootId: "@mutation.1"
        )

        XCTAssertEqual(graph.getRecord("User:u1")?["email"]?.string, "first@example.com")
        XCTAssertEqual(graph.getRecord("User:u2")?["email"]?.string, "second@example.com")
        XCTAssertEqual(graph.getRecord("@mutation.0")?["__typename"]?.string, "@mutation.0")
        XCTAssertEqual(graph.getRecord("@mutation.1")?["__typename"]?.string, "@mutation.1")
    }

    func test_mutation_without_rootId_uses_default_root() throws {
        let (graph, documents) = makeStack(keys: ["User": { _, obj in obj["id"]?.string }])
        let plan = try planFor("""
        mutation UpdateUser($input: UpdateUserInput!) {
            updateUser(input: $input) { user { id email } }
        }
        """)
        documents.normalize(
            plan: plan,
            variables: ["input": .object(["id": "u1", "email": "legacy@x.com"])],
            data: .object([
                "updateUser": .object([
                    "__typename": "UpdateUserPayload",
                    "user": .object(["__typename": "User", "id": "u1", "email": "legacy@x.com"])
                ])
            ])
        )

        XCTAssertEqual(graph.getRecord("User:u1")?["email"]?.string, "legacy@x.com")
        XCTAssertEqual(graph.getRecord("@")?["__typename"]?.string, "@")
    }

    func test_mutation_with_explicit_null_field_persists_null_link() throws {
        let (graph, documents) = makeStack()
        let plan = try planFor("""
        mutation CreateDirectUpload($input: CreateDirectUploadInput!) {
            createDirectUpload(input: $input) {
                directUpload { uploadUrl }
                errors { message }
            }
        }
        """)
        documents.normalize(
            plan: plan,
            variables: ["input": .object(["filename": "test.wav"])],
            data: .object([
                "createDirectUpload": .object([
                    "__typename": "CreateDirectUploadPayload",
                    "directUpload": .object([
                        "__typename": "DirectUpload",
                        "uploadUrl": "https://example.com/upload",
                    ]),
                    "errors": .null,
                ])
            ]),
            rootId: "@mutation.0"
        )

        // The payload container is an inline (no key) record; locate it via
        // mutation root link.
        let mutationRoot = graph.getRecord("@mutation.0") ?? [:]
        let fieldKey = mutationRoot.keys.first { $0.hasPrefix("createDirectUpload(") }
        guard let fk = fieldKey, case .ref(let payloadKey) = mutationRoot[fk] ?? .undefined else {
            return XCTFail("expected ref at createDirectUpload(...) field; root=\(mutationRoot)")
        }
        let payload = graph.getRecord(payloadKey) ?? [:]
        // `errors` is a null link (selection set + null value).
        if case .null = payload["errors"] { /* ok */ } else {
            XCTFail("expected payload.errors == .null, got \(String(describing: payload["errors"]))")
        }
    }

    // MARK: - Subscriptions with rootId

    func test_subscription_with_rootId_creates_subscription_root() throws {
        let (graph, documents) = makeStack(keys: ["User": { _, obj in obj["id"]?.string }])
        let plan = try planFor("""
        subscription UserUpdated($id: ID!) {
            userUpdated(id: $id) {
                user { id email }
            }
        }
        """)
        documents.normalize(
            plan: plan,
            variables: ["id": "u1"],
            data: .object([
                "userUpdated": .object([
                    "__typename": "UserUpdatedPayload",
                    "user": .object(["__typename": "User", "id": "u1", "email": "subscribed@example.com"])
                ])
            ]),
            rootId: "@subscription.0"
        )

        XCTAssertEqual(graph.getRecord("User:u1")?["email"]?.string, "subscribed@example.com")
        XCTAssertEqual(graph.getRecord("@subscription.0")?["__typename"]?.string, "@subscription.0")
    }

    func test_subscription_rootIds_independent_per_event() throws {
        let (graph, documents) = makeStack(keys: ["User": { _, obj in obj["id"]?.string }])
        let plan = try planFor("""
        subscription UserUpdated($id: ID!) {
            userUpdated(id: $id) { user { id email } }
        }
        """)

        documents.normalize(
            plan: plan, variables: ["id": "u1"],
            data: .object([
                "userUpdated": .object([
                    "__typename": "UserUpdatedPayload",
                    "user": .object(["__typename": "User", "id": "u1", "email": "event1@x.com"])
                ])
            ]),
            rootId: "@subscription.0"
        )
        documents.normalize(
            plan: plan, variables: ["id": "u1"],
            data: .object([
                "userUpdated": .object([
                    "__typename": "UserUpdatedPayload",
                    "user": .object(["__typename": "User", "id": "u1", "email": "event2@x.com"])
                ])
            ]),
            rootId: "@subscription.1"
        )

        // Both roots present.
        XCTAssertNotNil(graph.getRecord("@subscription.0"))
        XCTAssertNotNil(graph.getRecord("@subscription.1"))
        // Entity is updated.
        XCTAssertEqual(graph.getRecord("User:u1")?["email"]?.string, "event2@x.com")
    }

    func test_subscription_without_rootId_uses_default_root() throws {
        let (graph, documents) = makeStack(keys: ["User": { _, obj in obj["id"]?.string }])
        let plan = try planFor("""
        subscription UserUpdated($id: ID!) {
            userUpdated(id: $id) { user { id email } }
        }
        """)
        documents.normalize(
            plan: plan, variables: ["id": "u1"],
            data: .object([
                "userUpdated": .object([
                    "__typename": "UserUpdatedPayload",
                    "user": .object(["__typename": "User", "id": "u1", "email": "legacy@x.com"])
                ])
            ])
        )

        XCTAssertEqual(graph.getRecord("User:u1")?["email"]?.string, "legacy@x.com")
        XCTAssertEqual(graph.getRecord("@")?["__typename"]?.string, "@")
    }

    // MARK: - Fragments with rootId

    func test_fragment_normalizes_to_existing_entity_id() throws {
        let (graph, documents) = makeStack(keys: ["User": { _, obj in obj["id"]?.string }])
        let plan = try Compiler.compilePlan(source: """
        fragment UserFields on User { id email name }
        """)
        documents.normalize(
            plan: plan, variables: [:],
            data: .object([
                "__typename": "User",
                "id": "u1",
                "email": "user@example.com",
                "name": "Alice",
            ]),
            rootId: "User:u1"
        )

        let rec = graph.getRecord("User:u1") ?? [:]
        XCTAssertEqual(rec["__typename"]?.string, "User")
        XCTAssertEqual(rec["id"]?.string, "u1")
        XCTAssertEqual(rec["email"]?.string, "user@example.com")
        XCTAssertEqual(rec["name"]?.string, "Alice")
    }

    func test_fragment_with_nested_entities_normalizes_children() throws {
        let (graph, documents) = makeStack(keys: [
            "User": { _, obj in obj["id"]?.string },
            "Post": { _, obj in obj["id"]?.string },
        ])
        let plan = try Compiler.compilePlan(source: """
        fragment UserWithPosts on User {
            id
            name
            posts { id title }
        }
        """)
        documents.normalize(
            plan: plan, variables: [:],
            data: .object([
                "__typename": "User",
                "id": "u1",
                "name": "Alice",
                "posts": .array([
                    .object(["__typename": "Post", "id": "p1", "title": "Post 1"]),
                    .object(["__typename": "Post", "id": "p2", "title": "Post 2"]),
                ]),
            ]),
            rootId: "User:u1"
        )

        XCTAssertEqual(graph.getRecord("User:u1")?["name"]?.string, "Alice")
        XCTAssertEqual(graph.getRecord("Post:p1")?["title"]?.string, "Post 1")
        XCTAssertEqual(graph.getRecord("Post:p2")?["title"]?.string, "Post 2")
    }

    func test_fragment_with_custom_key_field_uuid() throws {
        let (graph, documents) = makeStack(keys: [
            "Comment": { _, obj in obj["uuid"]?.string }
        ])
        let plan = try Compiler.compilePlan(source: """
        fragment CommentFields on Comment { uuid text }
        """)
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        documents.normalize(
            plan: plan, variables: [:],
            data: .object([
                "__typename": "Comment",
                "uuid": .string(uuid),
                "text": "Great post!",
            ]),
            rootId: "Comment:\(uuid)"
        )
        let rec = graph.getRecord("Comment:\(uuid)") ?? [:]
        XCTAssertEqual(rec["uuid"]?.string, uuid)
        XCTAssertEqual(rec["text"]?.string, "Great post!")
    }

    func test_fragment_normalize_updates_existing_entity_in_place() throws {
        let (graph, documents) = makeStack(keys: ["User": { _, obj in obj["id"]?.string }])
        let plan = try Compiler.compilePlan(source: "fragment UserFields on User { id email }")

        documents.normalize(
            plan: plan, variables: [:],
            data: .object(["__typename": "User", "id": "u1", "email": "old@x.com"]),
            rootId: "User:u1"
        )
        documents.normalize(
            plan: plan, variables: [:],
            data: .object(["__typename": "User", "id": "u1", "email": "new@x.com"]),
            rootId: "User:u1"
        )

        XCTAssertEqual(graph.getRecord("User:u1")?["email"]?.string, "new@x.com")
    }
}

// MARK: - Helpers

private extension JSONValue {
    var intValue: Int64? {
        if case .int(let v) = self { return v }
        return nil
    }
}
