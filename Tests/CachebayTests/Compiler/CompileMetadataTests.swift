import XCTest
@testable import Cachebay

/// Port of `cachebay-web/test/unit/compiler/compile-metadata.test.ts`.
///
/// Notes vs the JS version:
/// - `plan.id` is a `UInt32` on iOS (FNV1a32), not a string. All identity
///   comparisons still hold.
/// - `getDependencies(canonical:variables:)` mirrors the JS counterpart but
///   in iOS the strict mode emits keys under `@.field(...)` and canonical
///   under `@connection.field(...)` — see `Keys.swift`.
final class CompileMetadataTests: XCTestCase {

    // MARK: - Plan ID

    func test_computes_stable_plan_id_from_selection_shape() throws {
        let plan1 = try Compiler.compilePlan(source: CompilerOps.userPostsQuery)
        let plan2 = try Compiler.compilePlan(source: CompilerOps.userPostsQuery)
        let plan3 = try Compiler.compilePlan(source: CompilerOps.userWithAliasQuery)

        XCTAssertEqual(plan1.id, plan2.id)
        XCTAssertNotEqual(plan1.id, plan3.id)
    }

    // MARK: - Window args

    func test_collects_window_args_from_connection_fields() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsQuery)

        XCTAssertTrue(plan.windowArgs.contains("first"))
        XCTAssertTrue(plan.windowArgs.contains("after"))
        XCTAssertTrue(plan.windowArgs.contains("last"))
        XCTAssertTrue(plan.windowArgs.contains("before"))
        XCTAssertFalse(plan.windowArgs.contains("category"))
        XCTAssertFalse(plan.windowArgs.contains("sort"))
    }

    // MARK: - Var masks

    func test_computes_strict_and_canonical_variable_masks() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsQuery)

        let strict = Set(plan.varMask.strict)
        XCTAssertTrue(strict.isSuperset(of: ["category", "sort", "first", "after", "last", "before"]))

        let canonical = Set(plan.varMask.canonical)
        XCTAssertTrue(canonical.contains("category"))
        XCTAssertTrue(canonical.contains("sort"))
        XCTAssertFalse(canonical.contains("first"))
        XCTAssertFalse(canonical.contains("after"))
        XCTAssertFalse(canonical.contains("last"))
        XCTAssertFalse(canonical.contains("before"))
    }

    // MARK: - makeVarsKey

    func test_makeVarsKey_generates_stable_keys_for_strict_mode() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsQuery)

        let vars1: [String: JSONValue] = ["category": .string("tech"), "sort": .string("hot"), "first": .int(10), "after": .string("c1")]
        let vars2: [String: JSONValue] = ["first": .int(10), "category": .string("tech"), "after": .string("c1"), "sort": .string("hot")]
        let vars3: [String: JSONValue] = ["category": .string("tech"), "sort": .string("hot"), "first": .int(20), "after": .string("c1")]

        let key1 = plan.makeVarsKey(canonical: false, variables: vars1)
        let key2 = plan.makeVarsKey(canonical: false, variables: vars2)
        let key3 = plan.makeVarsKey(canonical: false, variables: vars3)

        XCTAssertEqual(key1, key2)
        XCTAssertNotEqual(key1, key3)
    }

    func test_makeVarsKey_generates_stable_keys_for_canonical_mode() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsQuery)

        let vars1: [String: JSONValue] = ["category": .string("tech"), "sort": .string("hot"), "first": .int(10), "after": .string("cursor1")]
        let vars2: [String: JSONValue] = ["category": .string("tech"), "sort": .string("hot"), "first": .int(20), "after": .string("cursor2")]
        let vars3: [String: JSONValue] = ["category": .string("news"), "sort": .string("hot"), "first": .int(10), "after": .string("cursor1")]

        let key1 = plan.makeVarsKey(canonical: true, variables: vars1)
        let key2 = plan.makeVarsKey(canonical: true, variables: vars2)
        let key3 = plan.makeVarsKey(canonical: true, variables: vars3)

        XCTAssertEqual(key1, key2)
        XCTAssertNotEqual(key1, key3)
    }

    // MARK: - selId

    func test_computes_selId_for_each_field() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.userPostsQuery)

        let userField = plan.root.first { $0.fieldName == "user" }
        XCTAssertNotNil(userField?.selId)
        XCTAssertFalse(userField?.selId.isEmpty ?? true)

        let postsField = userField?.selectionSet?.first { $0.fieldName == "posts" }
        XCTAssertNotNil(postsField?.selId)
        XCTAssertFalse(postsField?.selId.isEmpty ?? true)
    }

    // MARK: - pageArgs

    func test_marks_pageArgs_on_connection_fields() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postCommentsQuery)

        let postField = plan.root.first { $0.fieldName == "post" }
        let commentsField = postField?.selectionSet?.first { $0.fieldName == "comments" }

        XCTAssertEqual(commentsField?.isConnection, true)
        XCTAssertNotNil(commentsField?.pageArgs)
        XCTAssertTrue(commentsField?.pageArgs?.contains("first") ?? false)
        XCTAssertTrue(commentsField?.pageArgs?.contains("after") ?? false)
        XCTAssertTrue(commentsField?.pageArgs?.contains("last") ?? false)
        XCTAssertTrue(commentsField?.pageArgs?.contains("before") ?? false)
    }

    // MARK: - Selection fingerprint

    func test_generates_selection_fingerprint() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.userQuery)

        XCTAssertFalse(plan.selectionFingerprint.isEmpty)
    }

    // MARK: - Fragment & no-connection metadata

    func test_handles_fragments_correctly_metadata() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.userPostsFragment, fragmentName: "UserPosts")

        // id is UInt32 on iOS — non-zero is the equivalent of "defined".
        XCTAssertNotEqual(plan.id, 0)
        XCTAssertFalse(plan.selectionFingerprint.isEmpty)
        XCTAssertGreaterThan(plan.windowArgs.count, 0)
    }

    func test_handles_queries_without_connections() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsWithoutConnectionQuery)

        XCTAssertNotEqual(plan.id, 0)
        XCTAssertEqual(plan.windowArgs.count, 0)
        XCTAssertEqual(Set(plan.varMask.strict), Set(plan.varMask.canonical))
    }

    // MARK: - Nested connections

    func test_handles_nested_connections_with_aggregations() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsWithAggregationsQuery)

        XCTAssertNotEqual(plan.id, 0)
        XCTAssertTrue(plan.windowArgs.contains("first"))
        XCTAssertTrue(plan.windowArgs.contains("after"))

        let postsField = plan.root.first { $0.fieldName == "posts" }
        XCTAssertEqual(postsField?.isConnection, true)
        XCTAssertNotNil(postsField?.selId)

        let edgesField = postsField?.selectionSet?.first { $0.fieldName == "edges" }
        let nodeField = edgesField?.selectionSet?.first { $0.fieldName == "node" }
        let aggregationsField = nodeField?.selectionSet?.first { $0.fieldName == "aggregations" }
        let moderationTagsField = aggregationsField?.selectionSet?.first { $0.responseKey == "moderationTags" }

        XCTAssertEqual(moderationTagsField?.fieldName, "tags")
        XCTAssertEqual(moderationTagsField?.responseKey, "moderationTags")
        XCTAssertEqual(moderationTagsField?.isConnection, true)
        XCTAssertEqual(moderationTagsField?.connectionKey, "ModerationTags")
        XCTAssertNotNil(moderationTagsField?.selId)

        let topAggregationsField = postsField?.selectionSet?.first { $0.fieldName == "aggregations" }
        let baseTagsField = topAggregationsField?.selectionSet?.first { $0.fieldName == "tags" }
        XCTAssertEqual(baseTagsField?.isConnection, true)
        XCTAssertEqual(baseTagsField?.connectionKey, "BaseTags")
        XCTAssertNotNil(baseTagsField?.selId)
    }

    func test_handles_deeply_nested_connections_user_posts_comments() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.userPostsCommentsQuery)

        XCTAssertNotEqual(plan.id, 0)
        XCTAssertTrue(plan.windowArgs.contains("first"))
        XCTAssertTrue(plan.windowArgs.contains("after"))

        let userField = plan.root.first { $0.fieldName == "user" }
        let postsField = userField?.selectionSet?.first { $0.fieldName == "posts" }
        XCTAssertEqual(postsField?.isConnection, true)
        XCTAssertNotNil(postsField?.selId)

        let postsEdgesField = postsField?.selectionSet?.first { $0.fieldName == "edges" }
        let postNodeField = postsEdgesField?.selectionSet?.first { $0.fieldName == "node" }
        let commentsField = postNodeField?.selectionSet?.first { $0.fieldName == "comments" }

        XCTAssertEqual(commentsField?.isConnection, true)
        XCTAssertNotNil(commentsField?.selId)
        XCTAssertEqual(commentsField?.connectionFilters, [])
    }

    func test_handles_multiple_nested_connections_users_posts_comments() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.usersPostsCommentsQuery)

        XCTAssertNotEqual(plan.id, 0)
        XCTAssertTrue(plan.windowArgs.contains("first"))
        XCTAssertTrue(plan.windowArgs.contains("after"))

        let usersField = plan.root.first { $0.fieldName == "users" }
        XCTAssertEqual(usersField?.isConnection, true)
        XCTAssertTrue(usersField?.connectionFilters?.contains("role") ?? false)
        XCTAssertNotNil(usersField?.selId)

        let usersEdgesField = usersField?.selectionSet?.first { $0.fieldName == "edges" }
        let userNodeField = usersEdgesField?.selectionSet?.first { $0.fieldName == "node" }
        let postsField = userNodeField?.selectionSet?.first { $0.fieldName == "posts" }
        XCTAssertEqual(postsField?.isConnection, true)
        XCTAssertTrue(postsField?.connectionFilters?.contains("category") ?? false)
        XCTAssertNotNil(postsField?.selId)

        let postsEdgesField = postsField?.selectionSet?.first { $0.fieldName == "edges" }
        let postNodeField = postsEdgesField?.selectionSet?.first { $0.fieldName == "node" }
        let commentsField = postNodeField?.selectionSet?.first { $0.fieldName == "comments" }
        XCTAssertEqual(commentsField?.isConnection, true)
        XCTAssertNotNil(commentsField?.selId)

        // All three levels should have unique selIds.
        let selIds: Set<String> = Set(
            [
                usersField?.selId,
                postsField?.selId,
                commentsField?.selId,
            ].compactMap { $0 })
        XCTAssertEqual(selIds.count, 3)
    }

    // MARK: - Plan ID stability across orderings & op kinds

    func test_produces_same_plan_id_for_queries_differing_only_by_field_order() throws {
        let q1 = """
            query GetUser($id: ID!) {
              user(id: $id) {
                id
                name
                email
              }
            }
            """
        let q2 = """
            query GetUser($id: ID!) {
              user(id: $id) {
                email
                id
                name
              }
            }
            """
        let plan1 = try Compiler.compilePlan(source: q1)
        let plan2 = try Compiler.compilePlan(source: q2)
        XCTAssertEqual(plan1.id, plan2.id)
        XCTAssertEqual(plan1.selectionFingerprint, plan2.selectionFingerprint)
    }

    func test_produces_different_plan_id_for_different_operations_with_same_fields() throws {
        let q = """
            query GetUser($id: ID!) {
              user(id: $id) { id email }
            }
            """
        let m = """
            mutation UpdateUser($id: ID!) {
              user(id: $id) { id email }
            }
            """
        let plan1 = try Compiler.compilePlan(source: q)
        let plan2 = try Compiler.compilePlan(source: m)
        XCTAssertNotEqual(plan1.id, plan2.id)
    }

    // MARK: - makeSignature

    func test_makeSignature_convenience_helper_works_correctly() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsQuery)
        let vars: [String: JSONValue] = [
            "category": .string("tech"),
            "sort": .string("hot"),
            "first": .int(10),
            "after": .string("c1"),
        ]
        let strictSig = plan.makeSignature(canonical: false, variables: vars)
        let canonicalSig = plan.makeSignature(canonical: true, variables: vars)

        XCTAssertEqual(strictSig, "\(plan.id)|strict|\(plan.makeVarsKey(canonical: false, variables: vars))")
        XCTAssertEqual(canonicalSig, "\(plan.id)|canonical|\(plan.makeVarsKey(canonical: true, variables: vars))")
        XCTAssertNotEqual(strictSig, canonicalSig)
    }

    // MARK: - Canonical key direction-insensitivity

    func test_canonical_key_same_for_first_after_vs_last_before_with_same_filters() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsQuery)

        let vars1: [String: JSONValue] = ["category": .string("tech"), "sort": .string("hot"), "first": .int(10), "after": .string("c1")]
        let vars2: [String: JSONValue] = ["category": .string("tech"), "sort": .string("hot"), "last": .int(10), "before": .string("c2")]
        let vars3: [String: JSONValue] = ["category": .string("news"), "sort": .string("hot"), "first": .int(10), "after": .string("c1")]

        let key1 = plan.makeVarsKey(canonical: true, variables: vars1)
        let key2 = plan.makeVarsKey(canonical: true, variables: vars2)
        let key3 = plan.makeVarsKey(canonical: true, variables: vars3)

        XCTAssertEqual(key1, key2)
        XCTAssertNotEqual(key1, key3)
    }

    func test_varMask_canonical_equals_strict_when_windowArgs_is_empty() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsWithoutConnectionQuery)

        XCTAssertEqual(plan.windowArgs.count, 0)
        XCTAssertEqual(Set(plan.varMask.canonical), Set(plan.varMask.strict))
    }

    // MARK: - Inline fragment selIds

    func test_selId_includes_typeCondition_for_inline_fragments() throws {
        let src = """
            query GetPosts($first: Int!) {
              posts(first: $first) @connection {
                edges {
                  node {
                    id
                    title
                    ... on VideoPost {
                      video { url }
                    }
                    ... on AudioPost {
                      audio { url }
                    }
                  }
                }
              }
            }
            """
        let plan = try Compiler.compilePlan(source: src)
        let postsField = plan.root.first { $0.fieldName == "posts" }
        let edgesField = postsField?.selectionSet?.first { $0.fieldName == "edges" }
        let nodeField = edgesField?.selectionSet?.first { $0.fieldName == "node" }

        let videoFragment = nodeField?.selectionSet?.first { $0.typeCondition == "VideoPost" }
        let audioFragment = nodeField?.selectionSet?.first { $0.typeCondition == "AudioPost" }

        XCTAssertEqual(videoFragment?.typeCondition, "VideoPost")
        XCTAssertEqual(audioFragment?.typeCondition, "AudioPost")

        XCTAssertNotNil(videoFragment?.selId)
        XCTAssertNotNil(audioFragment?.selId)
        XCTAssertNotEqual(videoFragment?.selId, audioFragment?.selId)
    }

    // MARK: - pageArgs all window args

    func test_pageArgs_includes_all_window_args_for_connection_field() throws {
        let src = """
            query GetPosts($first: Int, $after: String, $last: Int, $before: String) {
              posts(first: $first, after: $after, last: $last, before: $before) @connection {
                edges {
                  node { id }
                }
              }
            }
            """
        let plan = try Compiler.compilePlan(source: src)
        let postsField = plan.root.first { $0.fieldName == "posts" }

        XCTAssertEqual(postsField?.isConnection, true)
        XCTAssertNotNil(postsField?.pageArgs)
        XCTAssertTrue(postsField?.pageArgs?.contains("first") ?? false)
        XCTAssertTrue(postsField?.pageArgs?.contains("after") ?? false)
        XCTAssertTrue(postsField?.pageArgs?.contains("last") ?? false)
        XCTAssertTrue(postsField?.pageArgs?.contains("before") ?? false)

        for arg in postsField?.pageArgs ?? [] {
            XCTAssertTrue(plan.windowArgs.contains(arg))
        }
    }

    // MARK: - getDependencies

    func test_getDependencies_returns_empty_for_queries_without_args_or_connections() throws {
        let src = """
            query GetPosts {
              posts {
                id
                title
              }
            }
            """
        let plan = try Compiler.compilePlan(source: src)
        let deps = plan.getDependencies(canonical: true, variables: [:])
        XCTAssertEqual(deps.count, 0)
    }

    func test_getDependencies_extracts_field_keys_from_id_arguments() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.userQuery)
        let deps = plan.getDependencies(canonical: true, variables: ["id": .string("u123")])
        XCTAssertTrue(deps.contains(#"user({"id":"u123"})"#))
        XCTAssertEqual(deps.count, 1)
    }

    func test_getDependencies_handles_multiple_fields_with_id_arguments() throws {
        let src = """
            query GetUserAndPost($userId: ID!, $postId: ID!) {
              user(id: $userId) { id name }
              post(id: $postId) { id title }
            }
            """
        let plan = try Compiler.compilePlan(source: src)
        let deps = plan.getDependencies(
            canonical: true,
            variables: [
                "userId": .string("u1"),
                "postId": .string("p1"),
            ])
        XCTAssertTrue(deps.contains(#"user({"id":"u1"})"#))
        XCTAssertTrue(deps.contains(#"post({"id":"p1"})"#))
        XCTAssertEqual(deps.count, 2)
    }

    func test_getDependencies_handles_nested_fields_with_id_arguments_and_connections() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.userPostsQuery)
        let deps = plan.getDependencies(canonical: true, variables: ["id": .string("u1"), "first": .int(10)])

        XCTAssertTrue(deps.contains(#"user({"id":"u1"})"#))
        XCTAssertTrue(deps.contains(#"@connection.posts({})"#))
        XCTAssertEqual(deps.count, 2)
    }

    func test_getDependencies_tracks_parent_context_for_root_connections() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsQuery)
        let deps = plan.getDependencies(
            canonical: true,
            variables: [
                "category": .string("tech"),
                "first": .int(10),
            ])
        XCTAssertTrue(deps.contains(#"@connection.posts({"category":"tech"})"#))
        XCTAssertEqual(deps.count, 1)
    }

    func test_getDependencies_canonical_excludes_window_args_strict_includes_them() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.postsQuery)
        let strictDeps = plan.getDependencies(
            canonical: false,
            variables: [
                "category": .string("tech"),
                "sort": .string("hot"),
                "first": .int(10),
                "after": .string("c1"),
            ])
        let canonicalDeps = plan.getDependencies(
            canonical: true,
            variables: [
                "category": .string("tech"),
                "sort": .string("hot"),
                "first": .int(10),
                "after": .string("c1"),
            ])

        XCTAssertTrue(strictDeps.contains(#"@.posts({"category":"tech","sort":"hot","first":10,"after":"c1"})"#))
        XCTAssertEqual(strictDeps.count, 1)
        XCTAssertTrue(canonicalDeps.contains(#"@connection.posts({"category":"tech","sort":"hot"})"#))
        XCTAssertEqual(canonicalDeps.count, 1)

        XCTAssertFalse(strictDeps.contains(#"@connection.posts({"category":"tech","sort":"hot"})"#))
        XCTAssertFalse(canonicalDeps.contains(#"@.posts({"category":"tech","sort":"hot","first":10,"after":"c1"})"#))
    }

    func test_getDependencies_includes_fields_even_when_arguments_are_null() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.userQuery)
        let deps = plan.getDependencies(canonical: true, variables: ["id": .null])
        XCTAssertTrue(deps.contains(#"user({"id":null})"#))
        XCTAssertEqual(deps.count, 1)
    }

    func test_getDependencies_handles_fragments() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.userPostsFragment, fragmentName: "UserPosts")
        let deps = plan.getDependencies(canonical: true, variables: ["first": .int(10)])
        XCTAssertTrue(deps.contains(#"@connection.posts({})"#))
        XCTAssertEqual(deps.count, 1)
    }
}
