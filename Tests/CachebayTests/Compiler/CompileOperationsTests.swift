import XCTest
@testable import Cachebay

/// Port of `cachebay-web/test/unit/compiler/compile-operations.test.ts`.
final class CompileOperationsTests: XCTestCase {

    private func findField(_ fields: [PlanField], _ responseKey: String) -> PlanField? {
        return fields.first { $0.responseKey == responseKey }
    }

    func test_compiles_USER_QUERY_flattens_fragments_and_builds_arg_pickers() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.userQuery)
        XCTAssertEqual(plan.operation, .query)
        XCTAssertEqual(plan.rootTypename, "Query")

        let userField = try XCTUnwrap(findField(plan.root, "user"))
        XCTAssertEqual(userField.fieldName, "user")
        XCTAssertFalse(userField.isConnection)

        let userArgs = userField.buildArgs(["id": .string("u1")])
        XCTAssertEqual(userArgs, ["id": .string("u1")])

        XCTAssertEqual(userField.expectedArgNames, ["id"])

        let id = findField(userField.selectionSet ?? [], "id")
        let email = findField(userField.selectionSet ?? [], "email")
        XCTAssertNotNil(id)
        XCTAssertNotNil(email)

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_compiles_USERS_QUERY_marks_users_as_connection_filters_and_default_mode() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.usersQuery)

        let users = try XCTUnwrap(findField(plan.root, "users"))
        XCTAssertTrue(users.isConnection)
        XCTAssertEqual(users.connectionKey, "users")
        XCTAssertEqual(users.connectionFilters, ["role"])
        XCTAssertNil(users.connectionMode)

        // `undefined` web sentinel maps to `.undefined` in iOS — treat it as
        // missing on the variables dict.
        let usersArgs = users.buildArgs([
            "role": .string("admin"),
            "first": .int(2),
        ])
        XCTAssertEqual(usersArgs, [
            "role": .string("admin"),
            "first": .int(2),
        ])

        XCTAssertEqual(users.expectedArgNames, ["role", "first", "after", "last", "before"])

        let edges = findField(users.selectionSet ?? [], "edges")
        let pageInfo = findField(users.selectionSet ?? [], "pageInfo")
        XCTAssertNotNil(edges)
        XCTAssertNotNil(pageInfo)

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_compiles_USER_POSTS_QUERY_nested_posts_as_connection_with_filters_default_mode() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.userPostsQuery)

        let user = try XCTUnwrap(findField(plan.root, "user"))
        let posts = try XCTUnwrap(findField(user.selectionSet ?? [], "posts"))
        XCTAssertTrue(posts.isConnection)
        XCTAssertEqual(posts.connectionKey, "posts")
        XCTAssertEqual(posts.connectionFilters, ["category", "sort"])
        XCTAssertNil(posts.connectionMode)

        XCTAssertEqual(user.buildArgs(["id": .string("u1")]), ["id": .string("u1")])
        XCTAssertEqual(user.expectedArgNames, ["id"])

        let postsArgs = posts.buildArgs([
            "postsCategory": .string("tech"),
            "postsFirst": .int(2),
            "postsAfter": .null,
        ])
        XCTAssertEqual(postsArgs, [
            "category": .string("tech"),
            "first": .int(2),
            "after": .null,
        ])

        XCTAssertEqual(posts.expectedArgNames, ["category", "sort", "first", "after", "last", "before"])

        let edges = try XCTUnwrap(findField(posts.selectionSet ?? [], "edges"))
        let node = try XCTUnwrap(findField(edges.selectionSet ?? [], "node"))
        XCTAssertNotNil(findField(node.selectionSet ?? [], "id"))
        XCTAssertNotNil(findField(node.selectionSet ?? [], "title"))
        XCTAssertNotNil(findField(node.selectionSet ?? [], "flags"))
        XCTAssertNotNil(findField(node.selectionSet ?? [], "author"))

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_compiles_USERS_POSTS_COMMENTS_QUERY_users_posts_comments_marked_with_filters_and_default_mode() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.usersPostsCommentsQuery)

        let users = try XCTUnwrap(findField(plan.root, "users"))
        XCTAssertTrue(users.isConnection)
        XCTAssertEqual(users.connectionKey, "users")
        XCTAssertEqual(users.connectionFilters, ["role"])
        XCTAssertNil(users.connectionMode)

        let userEdges = try XCTUnwrap(findField(users.selectionSet ?? [], "edges"))
        let userNode = try XCTUnwrap(findField(userEdges.selectionSet ?? [], "node"))

        let posts = try XCTUnwrap(findField(userNode.selectionSet ?? [], "posts"))
        XCTAssertTrue(posts.isConnection)
        XCTAssertEqual(posts.connectionKey, "posts")
        XCTAssertEqual(posts.connectionFilters, ["category"])
        XCTAssertNil(posts.connectionMode)

        let postEdges = try XCTUnwrap(findField(posts.selectionSet ?? [], "edges"))
        let postNode = try XCTUnwrap(findField(postEdges.selectionSet ?? [], "node"))

        let comments = try XCTUnwrap(findField(postNode.selectionSet ?? [], "comments"))
        XCTAssertTrue(comments.isConnection)
        XCTAssertEqual(comments.connectionKey, "comments")
        // No filters declared, no non-pagination args → empty inferred filters.
        XCTAssertEqual(comments.connectionFilters, [])
        XCTAssertNil(comments.connectionMode)

        let usersArgs = users.buildArgs([
            "usersRole": .string("dj"),
            "usersFirst": .int(2),
            "usersAfter": .string("u1"),
        ])
        XCTAssertEqual(usersArgs, [
            "role": .string("dj"),
            "first": .int(2),
            "after": .string("u1"),
        ])

        let postsArgs = posts.buildArgs([
            "postsCategory": .string("tech"),
            "postsFirst": .int(1),
            "postsAfter": .null,
        ])
        XCTAssertEqual(postsArgs, [
            "category": .string("tech"),
            "first": .int(1),
            "after": .null,
        ])

        let commentsArgs = comments.buildArgs([
            "commentsFirst": .int(3),
            "commentsAfter": .string("c2"),
        ])
        XCTAssertEqual(commentsArgs, [
            "first": .int(3),
            "after": .string("c2"),
        ])

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_preserves_alias_as_responseKey_and_field_name_as_fieldName() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.userWithAliasQuery)

        let currentUser = try XCTUnwrap(findField(plan.root, "currentUser"))
        XCTAssertEqual(currentUser.responseKey, "currentUser")
        XCTAssertEqual(currentUser.fieldName, "user")
        XCTAssertEqual(currentUser.buildArgs(["id": .string("u1")]), ["id": .string("u1")])

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_multiple_distinct_type_conditions_falls_back_for_child_parent_inference() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.multipleUserFragment)

        let user = try XCTUnwrap(findField(plan.root, "user"))
        XCTAssertNotNil(findField(user.selectionSet ?? [], "id"))
        XCTAssertNotNil(findField(user.selectionSet ?? [], "role"))

        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_inline_fragments_on_implementors_set_typeCondition_on_fields() throws {
        let src = """
        query Query {
          posts(first: 10) @connection {
            edges {
              node {
                id
                title

                ... on VideoPost {
                  video { key mediaUrl }
                }

                ... on AudioPost {
                  audio { key mediaUrl }
                }
              }
            }
            pageInfo { hasNextPage }
            totalCount
          }
        }
        """
        let plan = try Compiler.compilePlan(source: src)

        XCTAssertEqual(plan.operation, .query)
        XCTAssertTrue(hasTypenames(plan.networkQuery))
        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])

        let posts = try XCTUnwrap(plan.rootSelectionMap["posts"])
        XCTAssertNotNil(posts.selectionMap?[CachebayConstants.typenameField])

        let edges = try XCTUnwrap(posts.selectionMap?["edges"])
        let node = try XCTUnwrap(edges.selectionMap?["node"])
        XCTAssertEqual(node.fieldName, "node")

        let id = try XCTUnwrap(node.selectionMap?["id"])
        let title = try XCTUnwrap(node.selectionMap?["title"])
        XCTAssertNil(id.typeCondition)
        XCTAssertNil(title.typeCondition)

        let video = try XCTUnwrap(node.selectionMap?["video"])
        let audio = try XCTUnwrap(node.selectionMap?["audio"])
        XCTAssertEqual(video.typeCondition, "VideoPost")
        XCTAssertEqual(audio.typeCondition, "AudioPost")

        let videoKey = try XCTUnwrap(video.selectionMap?["key"])
        let videoUrl = try XCTUnwrap(video.selectionMap?["mediaUrl"])
        XCTAssertEqual(videoKey.typeCondition, "VideoPost")
        XCTAssertEqual(videoUrl.typeCondition, "VideoPost")

        let audioKey = try XCTUnwrap(audio.selectionMap?["key"])
        let audioUrl = try XCTUnwrap(audio.selectionMap?["mediaUrl"])
        XCTAssertEqual(audioKey.typeCondition, "AudioPost")
        XCTAssertEqual(audioUrl.typeCondition, "AudioPost")
    }

    func test_fragment_spreads_on_implementors_set_typeCondition_on_fields() throws {
        let src = """
        fragment VideoFrag on VideoPost {
          video { key mediaUrl }
        }

        fragment AudioFrag on AudioPost {
          audio { key mediaUrl }
        }

        query Query {
          posts(first: 5) @connection {
            edges {
              node {
                id
                ...VideoFrag
                ...AudioFrag
              }
            }
          }
        }
        """
        let plan = try Compiler.compilePlan(source: src)
        XCTAssertTrue(hasTypenames(plan.networkQuery))
        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])

        let posts = try XCTUnwrap(plan.rootSelectionMap["posts"])
        let edges = try XCTUnwrap(posts.selectionMap?["edges"])
        let node = try XCTUnwrap(edges.selectionMap?["node"])

        let id = try XCTUnwrap(node.selectionMap?["id"])
        let video = try XCTUnwrap(node.selectionMap?["video"])
        let audio = try XCTUnwrap(node.selectionMap?["audio"])

        XCTAssertNil(id.typeCondition)
        XCTAssertEqual(video.typeCondition, "VideoPost")
        XCTAssertEqual(audio.typeCondition, "AudioPost")

        XCTAssertEqual(video.selectionMap?["key"]?.typeCondition, "VideoPost")
        XCTAssertEqual(audio.selectionMap?["key"]?.typeCondition, "AudioPost")
    }

    func test_includes_typename_in_pageInfo_when_using_fragment_spreads() throws {
        let src = """
        fragment PageInfoFields on PageInfo {
          startCursor
          endCursor
          hasNextPage
          hasPreviousPage
        }

        query Posts($first: Int) {
          posts(first: $first) @connection {
            pageInfo { ...PageInfoFields }
            edges {
              cursor
              node { id title }
            }
          }
        }
        """
        let plan = try Compiler.compilePlan(source: src)

        let posts = try XCTUnwrap(plan.rootSelectionMap["posts"])
        XCTAssertTrue(posts.isConnection)

        let pageInfo = try XCTUnwrap(posts.selectionMap?["pageInfo"])
        XCTAssertNotNil(pageInfo.selectionMap?[CachebayConstants.typenameField])
        XCTAssertTrue(hasTypenames(plan.networkQuery))
    }

    func test_stringifyArgs_produces_stable_keys_using_expectedArgNames_order() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.usersQuery)
        let users = try XCTUnwrap(findField(plan.root, "users"))

        let key1 = users.stringifyArgs([
            "role": .string("admin"),
            "first": .int(10),
            "after": .string("cursor1"),
        ])
        let key2 = users.stringifyArgs([
            "after": .string("cursor1"),
            "role": .string("admin"),
            "first": .int(10),
        ])
        let key3 = users.stringifyArgs([
            "first": .int(10),
            "after": .string("cursor1"),
            "role": .string("admin"),
        ])

        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key2, key3)
        XCTAssertEqual(key1, #"{"role":"admin","first":10,"after":"cursor1"}"#)
    }

    func test_compiles_UPDATE_USER_MUTATION_parses_mutation_type_and_adds_typename() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.updateUserMutation)

        XCTAssertEqual(plan.operation, .mutation)
        XCTAssertEqual(plan.rootTypename, "Mutation")

        let updateUser = try XCTUnwrap(findField(plan.root, "updateUser"))
        XCTAssertEqual(updateUser.fieldName, "updateUser")

        let user = try XCTUnwrap(findField(updateUser.selectionSet ?? [], "user"))
        XCTAssertNotNil(findField(user.selectionSet ?? [], "id"))
        XCTAssertNotNil(findField(user.selectionSet ?? [], "email"))

        let posts = try XCTUnwrap(findField(user.selectionSet ?? [], "posts"))
        XCTAssertTrue(posts.isConnection)
        XCTAssertEqual(posts.connectionKey, "posts")

        XCTAssertTrue(hasTypenames(plan.networkQuery))
        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
    }

    func test_compiles_USER_UPDATED_SUBSCRIPTION_parses_subscription_type_and_adds_typename() throws {
        let plan = try Compiler.compilePlan(source: CompilerOps.userUpdatedSubscription)

        XCTAssertEqual(plan.operation, .subscription)
        XCTAssertEqual(plan.rootTypename, "Subscription")

        let userUpdated = try XCTUnwrap(findField(plan.root, "userUpdated"))
        XCTAssertEqual(userUpdated.fieldName, "userUpdated")

        let userUpdatedArgs = userUpdated.buildArgs(["id": .string("u1")])
        XCTAssertEqual(userUpdatedArgs, ["id": .string("u1")])
        XCTAssertEqual(userUpdated.expectedArgNames, ["id"])

        let user = try XCTUnwrap(findField(userUpdated.selectionSet ?? [], "user"))
        XCTAssertNotNil(findField(user.selectionSet ?? [], "id"))
        XCTAssertNotNil(findField(user.selectionSet ?? [], "email"))

        XCTAssertTrue(hasTypenames(plan.networkQuery))
        XCTAssertEqual(collectConnectionDirectives(plan.networkQuery), [])
    }
}
