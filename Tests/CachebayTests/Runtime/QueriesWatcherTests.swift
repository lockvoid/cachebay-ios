import XCTest
@testable import Cachebay

/// Black-box behavioural coverage for `Queries.watchQuery`'s emission
/// pipeline — port of `cachebay-web/test/unit/core/queries.test.ts` plus
/// the cache-invalidation invariants from `queries-refcount.test.ts` that
/// aren't already covered by `QueriesRefcountTests`.
///
/// These tests verify the watcher fanout *behaviour* (does it fire? with
/// what data? skip when nothing changed? recycle unchanged subtrees?)
/// without poking internal state. Internal accounting tests already live
/// in `QueriesRefcountTests`.
final class QueriesWatcherTests: XCTestCase {

    private func makeClient() -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
    }

    private let userQuery = "query GetUser($id: ID!) { user(id: $id) { id name email } }"
    private let userWithProfile = """
        query GetUserWithProfile($id: ID!) {
            user(id: $id) { id name profile { id bio avatar } }
        }
        """
    private let userWithPosts = """
        query GetUserPosts($id: ID!) {
            user(id: $id) { id posts { id title content } }
        }
        """
    private let deeplyNested = """
        query GetUserNested($id: ID!) {
            user(id: $id) {
                id name
                profile {
                    id bio
                    settings {
                        id theme
                        notifications { id email push }
                    }
                }
            }
        }
        """

    // MARK: - readQuery / writeQuery

    /// Mirrors web `readQuery / writeQuery: writes and reads query data`.
    func test_writeQuery_then_readQuery_roundtrips_full_object() throws {
        let client = makeClient()
        try client.writeQuery(
            query: userQuery, variables: ["id": "1"],
            data: .object([
                "user": .object([
                    "__typename": "User",
                    "id": "1",
                    "name": "Alice",
                    "email": "alice@example.com",
                ])
            ]))

        let read = client.readQuery(query: userQuery, variables: ["id": "1"])
        XCTAssertEqual(read?["user"]?["id"]?.string, "1")
        XCTAssertEqual(read?["user"]?["name"]?.string, "Alice")
        XCTAssertEqual(read?["user"]?["email"]?.string, "alice@example.com")
    }

    /// Mirrors web `returns no data but provides deps for missing data`:
    /// reading a never-written record must return nil (no synthetic
    /// stub data leaks back to callers).
    func test_readQuery_missingEntity_returnsNil() {
        let client = makeClient()
        let read = client.readQuery(query: userQuery, variables: ["id": "999"])
        XCTAssertNil(read)
    }

    // MARK: - watchQuery: nested entity update

    /// Mirrors web `triggers when nested entity (User->Profile) is
    /// updated`. Writing only the nested Profile entity must cause the
    /// parent watcher to refire — the dep index has to register the
    /// nested key so a write to `Profile:p1` triggers the user query.
    func test_watcher_fires_when_nested_entity_updated() async throws {
        let client = makeClient()
        try client.writeQuery(
            query: userWithProfile, variables: ["id": "1"],
            data: .object([
                "user": .object([
                    "__typename": "User",
                    "id": "1",
                    "name": "Alice",
                    "profile": .object([
                        "__typename": "Profile",
                        "id": "p1",
                        "bio": "Original bio",
                        "avatar": "avatar1.jpg",
                    ]),
                ])
            ]))

        let captured = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userWithProfile,
            options: WatchQueryOptions(
                variables: ["id": "1"],
                immediate: true,
                onData: { captured.append($0) }
            )
        )
        XCTAssertEqual(captured.value.count, 1)
        XCTAssertEqual(captured.value[0]["user"]?["profile"]?["bio"]?.string, "Original bio")

        // Update only the Profile entity directly via low-level putRecord.
        client.graph.putRecord(
            "Profile:p1",
            [
                "__typename": "Profile",
                "id": "p1",
                "bio": "Updated bio",
                "avatar": "avatar2.jpg",
            ])
        client.graph.flush()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertGreaterThanOrEqual(captured.value.count, 2, "watcher must re-fire when nested Profile changes")
        let last = captured.value.last
        XCTAssertEqual(last?["user"]?["profile"]?["bio"]?.string, "Updated bio")
        XCTAssertEqual(last?["user"]?["profile"]?["avatar"]?.string, "avatar2.jpg")
        // User scalar unchanged.
        XCTAssertEqual(last?["user"]?["name"]?.string, "Alice")

        handle.unsubscribe()
    }

    /// Mirrors web `supports refetch` — a low-level `graph.putRecord`
    /// against the User entity must propagate to the user watcher.
    func test_watcher_fires_when_root_entity_putRecord_updated() async throws {
        let client = makeClient()
        try client.writeQuery(
            query: userQuery, variables: ["id": "1"],
            data: .object([
                "user": .object([
                    "__typename": "User", "id": "1",
                    "name": "Alice", "email": "a@x.com",
                ])
            ]))

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"],
                immediate: true,
                onData: { received.append($0) }
            )
        )
        XCTAssertEqual(received.value.count, 1)

        // Bypass the query API: directly mutate the record.
        client.graph.putRecord(
            "User:1",
            [
                "__typename": "User", "id": "1",
                "name": "Bob", "email": "a@x.com",
            ])
        client.graph.flush()
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertGreaterThanOrEqual(received.value.count, 2)
        XCTAssertEqual(received.value.last?["user"]?["name"]?.string, "Bob")

        handle.unsubscribe()
    }

    /// Mirrors web `triggers when mutation updates entity`. A second
    /// `writeQuery` (modeling a mutation response that returns the
    /// User entity) must update the cache and trigger the existing
    /// watcher.
    func test_watcher_fires_when_writeQuery_updates_entity() async throws {
        let client = makeClient()
        try client.writeQuery(
            query: userQuery, variables: ["id": "1"],
            data: .object([
                "user": .object([
                    "__typename": "User", "id": "1",
                    "name": "Alice", "email": "alice@example.com",
                ])
            ]))

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"],
                immediate: true,
                onData: { received.append($0) }
            )
        )
        XCTAssertEqual(received.value.count, 1)

        // Simulated mutation payload: writeQuery against an "updateUser"
        // operation which still resolves to User:1 in the graph.
        let updateUserMutation = """
            mutation UpdateUser($id: ID!, $name: String!, $email: String!) {
                updateUser(id: $id, name: $name, email: $email) { id name email }
            }
            """
        try client.writeQuery(
            query: updateUserMutation,
            variables: ["id": "1", "name": "Alice Updated", "email": "alice.u@example.com"],
            data: .object([
                "updateUser": .object([
                    "__typename": "User", "id": "1",
                    "name": "Alice Updated", "email": "alice.u@example.com",
                ])
            ])
        )
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertGreaterThanOrEqual(received.value.count, 2)
        let last = received.value.last
        XCTAssertEqual(last?["user"]?["name"]?.string, "Alice Updated")
        XCTAssertEqual(last?["user"]?["email"]?.string, "alice.u@example.com")

        handle.unsubscribe()
    }

    // MARK: - recycleSnapshots / no-op write

    /// Mirrors web `does not emit when data is structurally identical`.
    /// A second `writeQuery` with deep-equal payload must not produce a
    /// fresh emission — `recycleSnapshots` + `isDataDeepEqual` should
    /// suppress it. Without this, every refetch (even empty) would re-
    /// render the entire watcher subtree.
    func test_watcher_doesNotEmit_whenDataStructurallyIdentical() async throws {
        let client = makeClient()
        try client.writeQuery(
            query: userQuery, variables: ["id": "1"],
            data: .object([
                "user": .object([
                    "__typename": "User", "id": "1",
                    "name": "Alice", "email": "alice@example.com",
                ])
            ]))

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"],
                immediate: true,
                onData: { received.append($0) }
            )
        )
        XCTAssertEqual(received.value.count, 1)

        // Re-write the same data — must not emit.
        try client.writeQuery(
            query: userQuery, variables: ["id": "1"],
            data: .object([
                "user": .object([
                    "__typename": "User", "id": "1",
                    "name": "Alice", "email": "alice@example.com",
                ])
            ]))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(received.value.count, 1, "no emission for structurally-identical write")
        handle.unsubscribe()
    }

    /// Mirrors web `recycleSnapshots: reuses unchanged nested objects
    /// when only one field changes`. Top-level `user.name` changes; the
    /// `user.profile` subtree must remain deep-equal across emissions
    /// because the underlying Profile entity wasn't touched. This is the
    /// shallow analog of `test_watcher_recycles_deeplyNested...`.
    func test_watcher_recyclesUnchangedNestedObject_whenSiblingFieldChanges() async throws {
        let client = makeClient()
        try client.writeQuery(
            query: userWithProfile, variables: ["id": "1"],
            data: .object([
                "user": .object([
                    "__typename": "User", "id": "1", "name": "Alice",
                    "profile": .object([
                        "__typename": "Profile", "id": "p1",
                        "bio": "Software Engineer", "avatar": "avatar1.jpg",
                    ]),
                ])
            ]))

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userWithProfile,
            options: WatchQueryOptions(
                variables: ["id": "1"],
                immediate: true,
                onData: { received.append($0) }
            )
        )
        XCTAssertEqual(received.value.count, 1)
        let firstProfile = received.value[0]["user"]?["profile"]

        // Update only user.name through a "mutation"-shaped writeQuery
        // resolving to User:1.
        try client.writeQuery(
            query: "mutation UpdateUserName($id: ID!, $name: String!) { updateUser(id: $id, name: $name) { id name } }",
            variables: ["id": "1", "name": "Alice Updated"],
            data: .object([
                "updateUser": .object([
                    "__typename": "User", "id": "1", "name": "Alice Updated",
                ])
            ])
        )
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(received.value.count, 2, "name change must trigger one fresh emission")
        XCTAssertEqual(received.value.last?["user"]?["name"]?.string, "Alice Updated")
        let secondProfile = received.value[1]["user"]?["profile"]
        // Nested Profile object must still be deep-equal — recycleSnapshots
        // should preserve the unchanged subtree.
        XCTAssertEqual(firstProfile, secondProfile, "profile subtree unchanged ⇒ deep-equal across emissions")
        handle.unsubscribe()
    }

    /// Mirrors web `recycles deeply nested unchanged structures`. Even
    /// when a top-level field changes, the unchanged settings/
    /// notifications subtrees should retain identity — i.e. emit must
    /// happen, but only because of the changed field; the deep
    /// substructures must structurally match the previous snapshot.
    func test_watcher_recycles_deeplyNested_unchangedSubtrees_uponShallowChange() async throws {
        let client = makeClient()
        try client.writeQuery(
            query: deeplyNested, variables: ["id": "1"],
            data: .object([
                "user": .object([
                    "__typename": "User", "id": "1", "name": "Alice",
                    "profile": .object([
                        "__typename": "Profile", "id": "p1", "bio": "Engineer",
                        "settings": .object([
                            "__typename": "Settings", "id": "s1", "theme": "dark",
                            "notifications": .object([
                                "__typename": "Notifications", "id": "n1",
                                "email": .bool(true), "push": .bool(false),
                            ]),
                        ]),
                    ]),
                ])
            ]))

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: deeplyNested,
            options: WatchQueryOptions(
                variables: ["id": "1"],
                immediate: true,
                onData: { received.append($0) }
            )
        )
        XCTAssertEqual(received.value.count, 1)
        let firstSettings = received.value[0]["user"]?["profile"]?["settings"]
        let firstNotifications = received.value[0]["user"]?["profile"]?["settings"]?["notifications"]

        // Update ONLY user.name. profile.settings + notifications subtree
        // must remain deep-equal across emissions.
        let updateMutation = "mutation UpdateName($id: ID!, $name: String!) { updateUser(id: $id, name: $name) { id name } }"
        try client.writeQuery(
            query: updateMutation,
            variables: ["id": "1", "name": "Alice Updated"],
            data: .object([
                "updateUser": .object([
                    "__typename": "User", "id": "1",
                    "name": "Alice Updated",
                ])
            ])
        )
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(received.value.count, 2, "name change must trigger one fresh emission")
        XCTAssertEqual(received.value.last?["user"]?["name"]?.string, "Alice Updated")

        let secondSettings = received.value[1]["user"]?["profile"]?["settings"]
        let secondNotifications = received.value[1]["user"]?["profile"]?["settings"]?["notifications"]

        // Deep-equal — recycleSnapshots should keep these subtrees
        // unchanged when the inputs were unchanged.
        XCTAssertEqual(firstSettings, secondSettings, "settings subtree must be deep-equal across emissions")
        XCTAssertEqual(firstNotifications, secondNotifications, "notifications subtree must be deep-equal across emissions")

        handle.unsubscribe()
    }

    /// Mirrors web `reuses unchanged array elements when only one
    /// element changes`. Updating Post:p2 must change only the second
    /// edge; the first and third must remain deep-equal across
    /// emissions. Without per-element recycling every paginated list
    /// would force a full re-render on every node update.
    func test_watcher_recyclesUnchangedArrayElements_whenSingleElementChanges() async throws {
        let client = makeClient()
        try client.writeQuery(
            query: userWithPosts, variables: ["id": "1"],
            data: .object([
                "user": .object([
                    "__typename": "User", "id": "1",
                    "posts": .array([
                        .object(["__typename": "Post", "id": "p1", "title": "Post 1", "content": "Content 1"]),
                        .object(["__typename": "Post", "id": "p2", "title": "Post 2", "content": "Content 2"]),
                        .object(["__typename": "Post", "id": "p3", "title": "Post 3", "content": "Content 3"]),
                    ]),
                ])
            ]))

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: userWithPosts,
            options: WatchQueryOptions(
                variables: ["id": "1"],
                immediate: true,
                onData: { received.append($0) }
            )
        )
        XCTAssertEqual(received.value.count, 1)
        let initialPosts = received.value[0]["user"]?["posts"]?.array ?? []
        XCTAssertEqual(initialPosts.count, 3)
        let initialP1 = initialPosts[0]
        let initialP3 = initialPosts[2]

        // Update only Post:p2 via a "mutation"-style writeQuery.
        try client.writeQuery(
            query: "mutation UpdatePost($id: ID!, $title: String!) { updatePost(id: $id, title: $title) { id title } }",
            variables: ["id": "p2", "title": "Post 2 Updated"],
            data: .object([
                "updatePost": .object([
                    "__typename": "Post", "id": "p2", "title": "Post 2 Updated",
                ])
            ])
        )
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(received.value.count, 2)
        let updatedPosts = received.value[1]["user"]?["posts"]?.array ?? []
        XCTAssertEqual(updatedPosts.count, 3)
        XCTAssertEqual(updatedPosts[0], initialP1, "p1 must remain deep-equal across emissions")
        XCTAssertEqual(updatedPosts[2], initialP3, "p3 must remain deep-equal across emissions")
        XCTAssertEqual(updatedPosts[1]["title"]?.string, "Post 2 Updated")

        handle.unsubscribe()
    }

    // MARK: - update(variables:) for pagination

    /// Mirrors web `recycles data with update method for pagination`.
    /// The watcher is rotated from page-1 vars to page-2 vars; the new
    /// data must come from the second writeQuery, not the first.
    func test_watcher_update_rotatesToDifferentPaginationPage() throws {
        let client = makeClient()
        let pagedQuery = """
            query GetPosts($first: Int!, $after: String) {
                posts(first: $first, after: $after) {
                    edges { cursor node { id title } }
                    pageInfo { hasNextPage endCursor }
                }
            }
            """

        // Page 1
        try client.writeQuery(
            query: pagedQuery,
            variables: ["first": .int(2), "after": .null],
            data: .object([
                "posts": .object([
                    "__typename": "PostConnection",
                    "edges": .array([
                        .object([
                            "__typename": "PostEdge", "cursor": "c1",
                            "node": .object(["__typename": "Post", "id": "1", "title": "Post 1"]),
                        ]),
                        .object([
                            "__typename": "PostEdge", "cursor": "c2",
                            "node": .object(["__typename": "Post", "id": "2", "title": "Post 2"]),
                        ]),
                    ]),
                    "pageInfo": .object([
                        "__typename": "PageInfo",
                        "hasNextPage": true,
                        "endCursor": "c2",
                    ]),
                ])
            ])
        )

        // Page 2
        try client.writeQuery(
            query: pagedQuery,
            variables: ["first": .int(2), "after": .string("c2")],
            data: .object([
                "posts": .object([
                    "__typename": "PostConnection",
                    "edges": .array([
                        .object([
                            "__typename": "PostEdge", "cursor": "c3",
                            "node": .object(["__typename": "Post", "id": "3", "title": "Post 3"]),
                        ]),
                        .object([
                            "__typename": "PostEdge", "cursor": "c4",
                            "node": .object(["__typename": "Post", "id": "4", "title": "Post 4"]),
                        ]),
                    ]),
                    "pageInfo": .object([
                        "__typename": "PageInfo",
                        "hasNextPage": false,
                        "endCursor": "c4",
                    ]),
                ])
            ])
        )

        let received = CaptureBox<[JSONValue]>(value: [])
        let handle = try client.watchQuery(
            query: pagedQuery,
            options: WatchQueryOptions(
                variables: ["first": .int(2), "after": .null],
                immediate: true,
                onData: { received.append($0) }
            )
        )
        XCTAssertEqual(received.value.count, 1, "initial emission for page-1 vars")

        // Rotate to page-2 vars.
        handle.update(["first": .int(2), "after": .string("c2")], true)
        XCTAssertEqual(received.value.count, 2, "rotation must emit page-2 data")
        let lastEdges = received.value.last?["posts"]?["edges"]?.array ?? []
        XCTAssertEqual(lastEdges.count, 2)
        XCTAssertEqual(lastEdges.first?["node"]?["id"]?.string, "3")
        XCTAssertEqual(lastEdges.last?["node"]?["id"]?.string, "4")

        handle.unsubscribe()
    }

    // MARK: - Cache invalidation on last unsubscribe

    /// Mirrors web `invalidates cache when last watcher unsubscribes`
    /// behavioural variant. After every watcher for a signature is
    /// gone, the materialize cache for that signature must be invalid;
    /// this is verified by mutating the entity post-unsubscribe and
    /// then reading via `readQuery` — readQuery would short-circuit on
    /// a stale materialize cache.
    func test_lastUnsubscribe_invalidatesMaterializeCache() async throws {
        let client = makeClient()
        try client.writeQuery(
            query: userQuery, variables: ["id": "1"],
            data: .object([
                "user": .object([
                    "__typename": "User", "id": "1",
                    "name": "Alice", "email": "a@x.com",
                ])
            ]))

        let handle = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(
                variables: ["id": "1"],
                immediate: true,
                onData: { _ in }
            )
        )
        // Force the materialize cache to populate.
        _ = client.readQuery(query: userQuery, variables: ["id": "1"])
        handle.unsubscribe()

        // Mutate the underlying record directly. If the materialize
        // cache wasn't invalidated, readQuery would return the stale
        // pre-mutation snapshot.
        client.graph.putRecord(
            "User:1",
            [
                "__typename": "User", "id": "1",
                "name": "Alice Mutated", "email": "a@x.com",
            ])
        client.graph.flush()

        let read = client.readQuery(query: userQuery, variables: ["id": "1"])
        XCTAssertEqual(read?["user"]?["name"]?.string, "Alice Mutated", "materialize cache must reflect post-unsubscribe writes")
    }

    /// Mirrors web `does not invalidate cache while watchers remain`.
    /// Two watchers on the same signature; unsubscribe one — cache for
    /// the surviving watcher must continue to behave correctly (writes
    /// are observed via dep fanout).
    func test_unsubscribeOneOfTwoSiblings_secondStillReceivesUpdates() async throws {
        let client = makeClient()
        try client.writeQuery(
            query: userQuery, variables: ["id": "1"],
            data: .object([
                "user": .object([
                    "__typename": "User", "id": "1",
                    "name": "Alice", "email": "a@x.com",
                ])
            ]))

        let r1 = CaptureBox<[JSONValue]>(value: [])
        let r2 = CaptureBox<[JSONValue]>(value: [])
        let h1 = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(variables: ["id": "1"], immediate: true, onData: { r1.append($0) })
        )
        let h2 = try client.watchQuery(
            query: userQuery,
            options: WatchQueryOptions(variables: ["id": "1"], immediate: true, onData: { r2.append($0) })
        )
        XCTAssertEqual(r1.value.count, 1)
        XCTAssertEqual(r2.value.count, 1)

        h1.unsubscribe()
        // Mutate via writeQuery — h2 must still receive the update.
        try client.writeQuery(
            query: userQuery, variables: ["id": "1"],
            data: .object([
                "user": .object([
                    "__typename": "User", "id": "1",
                    "name": "Bob", "email": "a@x.com",
                ])
            ]))
        try await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(r1.value.count, 1, "h1 must not fire after unsubscribe")
        XCTAssertGreaterThanOrEqual(r2.value.count, 2, "h2 must still fire after sibling unsubscribed")
        XCTAssertEqual(r2.value.last?["user"]?["name"]?.string, "Bob")

        h2.unsubscribe()
    }
}
