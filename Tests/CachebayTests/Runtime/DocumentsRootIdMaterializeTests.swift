import XCTest
@testable import Cachebay

/// Hand-port of cachebay-web's
///   * `documents-materialize-mutations.test.ts`
///   * `documents-materialize-subscriptions.test.ts`
///   * `documents-materialize-fragments.test.ts`
///
/// These all share a single behavior surface: `materialize(... rootId:)`
/// reads the response shape rooted at a custom record (mutation root,
/// subscription root, or entity record). Mutation/subscription roots are
/// scoped by `@mutation.<n>` / `@subscription.<n>`; fragments use the
/// entity's natural cache key (e.g. `User:u1`).
final class DocumentsRootIdMaterializeTests: XCTestCase {
    private func makeStack(
        keys: [String: KeyFunction] = [
            "User": { _, obj in obj["id"]?.string },
            "Post": { _, obj in obj["id"]?.string },
            "Comment": { _, obj in obj["uuid"]?.string },
        ]
    ) -> (Graph, Documents) {
        let graph = Graph(options: GraphOptions(keys: keys))
        let planner = Planner()
        let canonical = Canonical(graph: graph)
        let documents = Documents(graph: graph, planner: planner, canonical: canonical)
        return (graph, documents)
    }

    private func plan(_ source: String) throws -> CachePlan {
        return try Compiler.compilePlan(source: source)
    }

    // MARK: - Mutations

    func test_materialize_mutation_from_custom_rootId() throws {
        let (_, documents) = makeStack()
        let p = try plan(
            """
            mutation UpdateUser($input: UpdateUserInput!) {
                updateUser(input: $input) { user { id email } }
            }
            """)
        let vars: [String: JSONValue] = ["input": .object(["id": "u1", "email": "materialized@example.com"])]
        documents.normalize(
            plan: p, variables: vars,
            data: .object([
                "updateUser": .object([
                    "__typename": "UpdateUserPayload",
                    "user": .object(["__typename": "User", "id": "u1", "email": "materialized@example.com"]),
                ])
            ]), rootId: "@mutation.0")

        let res = documents.materialize(plan: p, variables: vars, options: MaterializeOptions(canonical: true, rootId: "@mutation.0", fingerprint: false, preferCache: false))
        XCTAssertNotEqual(res.source, .none)
        let user = res.data["updateUser"]?["user"]?.object ?? [:]
        XCTAssertEqual(user["id"]?.string, "u1")
        XCTAssertEqual(user["email"]?.string, "materialized@example.com")
    }

    func test_materialize_multiple_mutations_independently() throws {
        let (_, documents) = makeStack()
        let p = try plan(
            """
            mutation UpdateUser($input: UpdateUserInput!) {
                updateUser(input: $input) { user { id email } }
            }
            """)
        let vars1: [String: JSONValue] = ["input": .object(["id": "u1", "email": "first@example.com"])]
        let vars2: [String: JSONValue] = ["input": .object(["id": "u2", "email": "second@example.com"])]

        documents.normalize(
            plan: p, variables: vars1,
            data: .object([
                "updateUser": .object([
                    "__typename": "UpdateUserPayload",
                    "user": .object(["__typename": "User", "id": "u1", "email": "first@example.com"]),
                ])
            ]), rootId: "@mutation.0")

        documents.normalize(
            plan: p, variables: vars2,
            data: .object([
                "updateUser": .object([
                    "__typename": "UpdateUserPayload",
                    "user": .object(["__typename": "User", "id": "u2", "email": "second@example.com"]),
                ])
            ]), rootId: "@mutation.1")

        let r1 = documents.materialize(plan: p, variables: vars1, options: MaterializeOptions(rootId: "@mutation.0", fingerprint: false, preferCache: false))
        let r2 = documents.materialize(plan: p, variables: vars2, options: MaterializeOptions(rootId: "@mutation.1", fingerprint: false, preferCache: false))

        XCTAssertEqual(r1.data["updateUser"]?["user"]?["email"]?.string, "first@example.com")
        XCTAssertEqual(r2.data["updateUser"]?["user"]?["email"]?.string, "second@example.com")
    }

    func test_materialize_mutation_with_unknown_rootId_returns_none() throws {
        let (_, documents) = makeStack()
        let p = try plan(
            """
            mutation UpdateUser($input: UpdateUserInput!) {
                updateUser(input: $input) { user { id email } }
            }
            """)
        let vars: [String: JSONValue] = ["input": .object(["id": "u1", "email": "x@x.com"])]

        let res = documents.materialize(plan: p, variables: vars, options: MaterializeOptions(rootId: "@mutation.999", fingerprint: false, preferCache: false))
        XCTAssertEqual(res.source, .none)
    }

    func test_materialize_mutation_resolves_entity_refs_after_external_update() throws {
        let (graph, documents) = makeStack()
        let p = try plan(
            """
            mutation UpdateUser($input: UpdateUserInput!) {
                updateUser(input: $input) { user { id email } }
            }
            """)
        let vars: [String: JSONValue] = ["input": .object(["id": "u1", "email": "resolved@example.com"])]
        documents.normalize(
            plan: p, variables: vars,
            data: .object([
                "updateUser": .object([
                    "__typename": "UpdateUserPayload",
                    "user": .object(["__typename": "User", "id": "u1", "email": "resolved@example.com"]),
                ])
            ]), rootId: "@mutation.0")

        // Simulate an unrelated entity write (e.g. another mutation/fragment
        // patches the user) — materialize MUST follow the ref to the latest
        // record, not return a stale snapshot.
        graph.putRecord("User:u1", ["email": "updated-after-mutation@example.com"])

        let res = documents.materialize(plan: p, variables: vars, options: MaterializeOptions(rootId: "@mutation.0", fingerprint: false, preferCache: false))
        XCTAssertEqual(res.data["updateUser"]?["user"]?["email"]?.string, "updated-after-mutation@example.com")
    }

    func test_materialize_mutation_with_wrong_variables_misses() throws {
        let (_, documents) = makeStack()
        let p = try plan(
            """
            mutation UpdateUser($input: UpdateUserInput!) {
                updateUser(input: $input) { user { id email } }
            }
            """)
        let correct: [String: JSONValue] = ["input": .object(["id": "u1", "email": "correct@example.com"])]
        let wrong: [String: JSONValue] = ["input": .object(["id": "u1", "email": "wrong@example.com"])]

        documents.normalize(
            plan: p, variables: correct,
            data: .object([
                "updateUser": .object([
                    "__typename": "UpdateUserPayload",
                    "user": .object(["__typename": "User", "id": "u1", "email": "correct@example.com"]),
                ])
            ]), rootId: "@mutation.0")

        let res = documents.materialize(plan: p, variables: wrong, options: MaterializeOptions(rootId: "@mutation.0", fingerprint: false, preferCache: false))
        XCTAssertFalse(res.canonicalOK, "different vars must not satisfy a canonical read")
    }

    // MARK: - Subscriptions

    func test_materialize_subscription_from_custom_rootId() throws {
        let (_, documents) = makeStack()
        let p = try plan(
            """
            subscription UserUpdated($id: ID!) {
                userUpdated(id: $id) {
                    user { id email }
                }
            }
            """)
        let vars: [String: JSONValue] = ["id": "u1"]
        documents.normalize(
            plan: p, variables: vars,
            data: .object([
                "userUpdated": .object([
                    "__typename": "UserUpdatedPayload",
                    "user": .object(["__typename": "User", "id": "u1", "email": "sub-materialized@example.com"]),
                ])
            ]), rootId: "@subscription.0")

        let res = documents.materialize(plan: p, variables: vars, options: MaterializeOptions(rootId: "@subscription.0", fingerprint: false, preferCache: false))
        XCTAssertNotEqual(res.source, .none)
        XCTAssertEqual(res.data["userUpdated"]?["user"]?["email"]?.string, "sub-materialized@example.com")
    }

    func test_materialize_multiple_subscription_events() throws {
        let (_, documents) = makeStack()
        let p = try plan(
            """
            subscription UserUpdated($id: ID!) {
                userUpdated(id: $id) { user { id email } }
            }
            """)
        let vars: [String: JSONValue] = ["id": "u1"]
        documents.normalize(
            plan: p, variables: vars,
            data: .object([
                "userUpdated": .object([
                    "__typename": "UserUpdatedPayload",
                    "user": .object(["__typename": "User", "id": "u1", "email": "event1@example.com"]),
                ])
            ]), rootId: "@subscription.0")
        documents.normalize(
            plan: p, variables: vars,
            data: .object([
                "userUpdated": .object([
                    "__typename": "UserUpdatedPayload",
                    "user": .object(["__typename": "User", "id": "u1", "email": "event2@example.com"]),
                ])
            ]), rootId: "@subscription.1")

        let r1 = documents.materialize(plan: p, variables: vars, options: MaterializeOptions(rootId: "@subscription.0", fingerprint: false, preferCache: false))
        let r2 = documents.materialize(plan: p, variables: vars, options: MaterializeOptions(rootId: "@subscription.1", fingerprint: false, preferCache: false))

        XCTAssertNotEqual(r1.source, .none)
        XCTAssertNotEqual(r2.source, .none)
        // Entity is shared; both materializations read the latest email.
        XCTAssertEqual(r1.data["userUpdated"]?["user"]?["email"]?.string, "event2@example.com")
        XCTAssertEqual(r2.data["userUpdated"]?["user"]?["email"]?.string, "event2@example.com")
    }

    func test_materialize_subscription_with_unknown_rootId_returns_none() throws {
        let (_, documents) = makeStack()
        let p = try plan(
            """
            subscription UserUpdated($id: ID!) {
                userUpdated(id: $id) { user { id email } }
            }
            """)
        let res = documents.materialize(plan: p, variables: ["id": "u1"], options: MaterializeOptions(rootId: "@subscription.999", fingerprint: false, preferCache: false))
        XCTAssertEqual(res.source, .none)
    }

    func test_materialize_subscription_resolves_external_entity_update() throws {
        let (graph, documents) = makeStack()
        let p = try plan(
            """
            subscription UserUpdated($id: ID!) {
                userUpdated(id: $id) { user { id email } }
            }
            """)
        let vars: [String: JSONValue] = ["id": "u1"]
        documents.normalize(
            plan: p, variables: vars,
            data: .object([
                "userUpdated": .object([
                    "__typename": "UserUpdatedPayload",
                    "user": .object(["__typename": "User", "id": "u1", "email": "initial@example.com"]),
                ])
            ]), rootId: "@subscription.0")

        graph.putRecord("User:u1", ["email": "updated-after-event@example.com"])

        let res = documents.materialize(plan: p, variables: vars, options: MaterializeOptions(rootId: "@subscription.0", fingerprint: false, preferCache: false))
        XCTAssertEqual(res.data["userUpdated"]?["user"]?["email"]?.string, "updated-after-event@example.com")
    }

    func test_materialize_subscription_with_wrong_variables_misses() throws {
        let (_, documents) = makeStack()
        let p = try plan(
            """
            subscription UserUpdated($id: ID!) {
                userUpdated(id: $id) { user { id email } }
            }
            """)
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "userUpdated": .object([
                    "__typename": "UserUpdatedPayload",
                    "user": .object(["__typename": "User", "id": "u1", "email": "correct@example.com"]),
                ])
            ]), rootId: "@subscription.0")

        let res = documents.materialize(plan: p, variables: ["id": "u2"], options: MaterializeOptions(rootId: "@subscription.0", fingerprint: false, preferCache: false))
        XCTAssertFalse(res.canonicalOK)
    }

    // MARK: - Fragments

    func test_fragment_read_with_standard_id_field() throws {
        let (_, documents) = makeStack()
        let queryPlan = try plan("query U($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: queryPlan, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "user1@test.com"])
            ]))

        let fragPlan = try Compiler.compilePlan(source: "fragment UserFields on User { id email }")
        let res = documents.materialize(plan: fragPlan, variables: [:], options: MaterializeOptions(rootId: "User:u1", preferCache: false))
        XCTAssertNotEqual(res.source, .none)
        let obj = res.data.object ?? [:]
        XCTAssertEqual(obj["__typename"]?.string, "User")
        XCTAssertEqual(obj["id"]?.string, "u1")
        XCTAssertEqual(obj["email"]?.string, "user1@test.com")
        // Fragment read still emits a __version on the result (at the entity level).
        let fps = res.fingerprints.object ?? [:]
        if case .int(let v) = fps[CachebayConstants.fingerprintKey] ?? .undefined {
            XCTAssertGreaterThan(v, 0)
        } else {
            XCTFail("expected entity __version on fragment fingerprints")
        }
    }

    func test_fragment_read_with_custom_key_uuid_and_nested_ref() throws {
        let (_, documents) = makeStack()
        // Seed the author entity via a query so it's normalized.
        let userPlan = try plan("query U($id: ID!) { user(id: $id) { id name } }")
        documents.normalize(
            plan: userPlan, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "name": "Alice"])
            ]))

        // Seed the comment via a query.
        let commentUuid = "550e8400-e29b-41d4-a716-446655440000"
        let commentQuery = try plan(
            """
            query GetComment($uuid: ID!) {
                comment(uuid: $uuid) {
                    uuid
                    text
                    author { id name }
                }
            }
            """)
        documents.normalize(
            plan: commentQuery, variables: ["uuid": .string(commentUuid)],
            data: .object([
                "comment": .object([
                    "__typename": "Comment",
                    "uuid": .string(commentUuid),
                    "text": "Great post!",
                    "author": .object(["__typename": "User", "id": "u1", "name": "Alice"]),
                ])
            ]))

        let fragPlan = try Compiler.compilePlan(
            source: """
                fragment CommentFields on Comment {
                    uuid
                    text
                    author { id name }
                }
                """)
        let res = documents.materialize(plan: fragPlan, variables: [:], options: MaterializeOptions(rootId: "Comment:\(commentUuid)", preferCache: false))
        XCTAssertNotEqual(res.source, .none)
        let obj = res.data.object ?? [:]
        XCTAssertEqual(obj["__typename"]?.string, "Comment")
        XCTAssertEqual(obj["uuid"]?.string, commentUuid)
        XCTAssertEqual(obj["text"]?.string, "Great post!")
        let author = obj["author"]?.object ?? [:]
        XCTAssertEqual(author["__typename"]?.string, "User")
        XCTAssertEqual(author["id"]?.string, "u1")
        XCTAssertEqual(author["name"]?.string, "Alice")
    }

    func test_fragment_read_for_unknown_entity_returns_none() throws {
        let (_, documents) = makeStack()
        let fragPlan = try Compiler.compilePlan(source: "fragment UserFields on User { id email }")
        let res = documents.materialize(plan: fragPlan, variables: [:], options: MaterializeOptions(rootId: "User:nonexistent", preferCache: false))
        XCTAssertEqual(res.source, .none)
        if case .undefined = res.data { /* ok */
        } else {
            XCTFail("expected undefined data for missing fragment entity")
        }
    }

    func test_fragment_invalidate_drops_cached_result() throws {
        let (_, documents) = makeStack()
        let userPlan = try plan("query U($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: userPlan, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "original@test.com"])
            ]))
        let fragPlan = try Compiler.compilePlan(source: "fragment UserFields on User { id email }")
        let opts = MaterializeOptions(rootId: "User:u1", preferCache: true, updateCache: true)
        let r1 = documents.materialize(plan: fragPlan, variables: [:], options: opts)
        XCTAssertFalse(r1.hot)
        let r2 = documents.materialize(plan: fragPlan, variables: [:], options: opts)
        XCTAssertTrue(r2.hot)

        documents.invalidate(plan: fragPlan, variables: [:], rootId: "User:u1")

        let r3 = documents.materialize(plan: fragPlan, variables: [:], options: opts)
        XCTAssertFalse(r3.hot)
    }

    func test_fragment_with_nested_entity_array_resolves_correctly() throws {
        let (_, documents) = makeStack()
        let userQuery = try plan(
            """
            query GetUser($id: ID!) {
                user(id: $id) {
                    id
                    name
                    posts { id title }
                }
            }
            """)
        documents.normalize(
            plan: userQuery, variables: ["id": "u1"],
            data: .object([
                "user": .object([
                    "__typename": "User",
                    "id": "u1",
                    "name": "Alice",
                    "posts": .array([
                        .object(["__typename": "Post", "id": "p1", "title": "Post 1"]),
                        .object(["__typename": "Post", "id": "p2", "title": "Post 2"]),
                    ]),
                ])
            ]))

        let fragPlan = try Compiler.compilePlan(
            source: """
                fragment UserWithPosts on User {
                    id
                    name
                    posts { id title }
                }
                """)
        let res = documents.materialize(plan: fragPlan, variables: [:], options: MaterializeOptions(rootId: "User:u1", preferCache: false))
        XCTAssertNotEqual(res.source, .none)
        let obj = res.data.object ?? [:]
        XCTAssertEqual(obj["name"]?.string, "Alice")
        let posts = obj["posts"]?.array ?? []
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0]["id"]?.string, "p1")
        XCTAssertEqual(posts[0]["title"]?.string, "Post 1")
        XCTAssertEqual(posts[1]["id"]?.string, "p2")
        XCTAssertEqual(posts[1]["title"]?.string, "Post 2")
    }
}
