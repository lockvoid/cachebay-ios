import XCTest
@testable import Cachebay

/// Hand-port of cachebay-web's `documents-materialize-queries.test.ts`,
/// scoped to behaviors that map cleanly to iOS:
///   * source/OK/dependencies tracking on hits and misses
///   * primitives (string/number/bool/null/JSON) round-trip
///   * aliases + arg-keyed fields
///   * follow `__ref` to child entities (single + array)
///   * canonical/strict mode interaction
///   * fingerprinting basics (root version present, changes propagate)
///   * invalidate / preferCache / updateCache / evictAll
final class DocumentsMaterializeTests: XCTestCase {
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

    private func plan(_ source: String) throws -> CachePlan {
        return try Compiler.compilePlan(source: source)
    }

    // MARK: - source/OK/dependencies

    func test_fulfilled_for_fully_present_entity_selection() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])
            ]))
        let res = documents.materialize(plan: p, variables: ["id": "u1"])
        XCTAssertNotEqual(res.source, .none)
        XCTAssertTrue(res.canonicalOK)

        let user = res.data["user"]?.object ?? [:]
        XCTAssertEqual(user["id"]?.string, "u1")
        XCTAssertEqual(user["email"]?.string, "u1@example.com")
        XCTAssertEqual(user["__typename"]?.string, "User")

        // Dependencies cover root-field key + entity id.
        XCTAssertTrue(res.dependencies.contains("@.user({\"id\":\"u1\"})"))
        XCTAssertTrue(res.dependencies.contains("User:u1"))
    }

    func test_missing_when_required_link_target_is_absent() throws {
        let (graph, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")

        // Wire a stale link to a target record that does not exist.
        graph.putRecord("@", ["user({\"id\":\"u2\"})": .ref("User:u2")])

        let res = documents.materialize(plan: p, variables: ["id": "u2"])
        XCTAssertEqual(res.source, .none)
        XCTAssertFalse(res.canonicalOK)
        if case .undefined = res.data { /* ok */
        } else {
            XCTFail("expected undefined data, got \(res.data)")
        }
        // Watcher dependency on missing entity is still reported so that a
        // later write to that record can wake the watcher.
        XCTAssertTrue(res.dependencies.contains("User:u2"))
    }

    func test_aliases_and_args_map_to_response_keys() throws {
        let (_, documents) = makeStack(keys: ["Media": { _, obj in obj["key"]?.string }])
        let p = try plan(
            """
            query MediaView {
                media(key: "m1") {
                    key
                    dataUrl
                    previewUrl: dataUrl(variant: "preview")
                }
            }
            """)
        documents.normalize(
            plan: p, variables: [:],
            data: .object([
                "media": .object([
                    "__typename": "Media",
                    "key": "m1",
                    "dataUrl": "raw-1",
                    "previewUrl": "raw-2",
                ])
            ]))

        let res = documents.materialize(plan: p, variables: [:])
        XCTAssertNotEqual(res.source, .none)
        let media = res.data["media"]?.object ?? [:]
        XCTAssertEqual(media["dataUrl"]?.string, "raw-1")
        XCTAssertEqual(media["previewUrl"]?.string, "raw-2")
    }

    func test_dependencies_include_canonical_connection_keys() throws {
        let (_, documents) = makeStack()
        let p = try plan(
            """
            query Posts($first: Int, $after: String) {
                posts(first: $first, after: $after) @connection(mode: "infinite") {
                    pageInfo { endCursor hasNextPage }
                    edges { cursor node { id title } }
                }
            }
            """)
        let vars: [String: JSONValue] = ["first": 2, "after": .null]
        documents.normalize(
            plan: p, variables: vars,
            data: .object([
                "posts": .object([
                    "__typename": "PostConnection",
                    "pageInfo": .object(["__typename": "PageInfo", "endCursor": "p2", "hasNextPage": true]),
                    "edges": .array([
                        .object(["__typename": "PostEdge", "cursor": "p1", "node": .object(["__typename": "Post", "id": "p1", "title": "A"])]),
                        .object(["__typename": "PostEdge", "cursor": "p2", "node": .object(["__typename": "Post", "id": "p2", "title": "B"])]),
                    ]),
                ])
            ]))

        let res = documents.materialize(plan: p, variables: vars)
        XCTAssertEqual(res.source, .canonical)

        let canonicalKey = "@connection.posts({})"
        XCTAssertTrue(res.dependencies.contains(canonicalKey))
        XCTAssertTrue(res.dependencies.contains("\(canonicalKey).pageInfo"))
        XCTAssertTrue(res.dependencies.contains("Post:p1"))
        XCTAssertTrue(res.dependencies.contains("Post:p2"))
    }

    // MARK: - primitives

    func test_reads_string_scalar() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { entity(id: $id) { id data } }")
        documents.normalize(
            plan: p, variables: ["id": "e1"],
            data: .object([
                "entity": .object(["__typename": "Entity", "id": "e1", "data": "string"])
            ]))
        let res = documents.materialize(plan: p, variables: ["id": "e1"])
        XCTAssertEqual(res.data["entity"]?["data"]?.string, "string")
    }

    func test_reads_number_scalar() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { entity(id: $id) { id data } }")
        documents.normalize(
            plan: p, variables: ["id": "e1"],
            data: .object([
                "entity": .object(["__typename": "Entity", "id": "e1", "data": .int(123)])
            ]))
        let res = documents.materialize(plan: p, variables: ["id": "e1"])
        if case .int(let v) = res.data["entity"]?["data"] ?? .undefined {
            XCTAssertEqual(v, 123)
        } else {
            XCTFail("expected int data")
        }
    }

    func test_reads_boolean_scalar() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { entity(id: $id) { id data } }")
        documents.normalize(
            plan: p, variables: ["id": "e1"],
            data: .object([
                "entity": .object(["__typename": "Entity", "id": "e1", "data": .bool(true)])
            ]))
        let res = documents.materialize(plan: p, variables: ["id": "e1"])
        XCTAssertEqual(res.data["entity"]?["data"]?.bool, true)
    }

    func test_reads_null_scalar() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { entity(id: $id) { id data } }")
        documents.normalize(
            plan: p, variables: ["id": "e1"],
            data: .object([
                "entity": .object(["__typename": "Entity", "id": "e1", "data": .null])
            ]))
        let res = documents.materialize(plan: p, variables: ["id": "e1"])
        if case .null = res.data["entity"]?["data"] ?? .undefined { /* ok */
        } else {
            XCTFail("expected null data")
        }
    }

    func test_reads_inline_json_object() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { entity(id: $id) { id data } }")
        documents.normalize(
            plan: p, variables: ["id": "e1"],
            data: .object([
                "entity": .object([
                    "__typename": "Entity", "id": "e1",
                    "data": .object(["foo": .object(["bar": "baz"])]),
                ])
            ]))
        let res = documents.materialize(plan: p, variables: ["id": "e1"])
        XCTAssertEqual(res.data["entity"]?["data"]?["foo"]?["bar"]?.string, "baz")
    }

    // MARK: - entities and refs

    func test_follows_ref_in_array_of_child_entities() throws {
        let (_, documents) = makeStack()
        let p = try plan(
            """
            query Q($id: ID!) {
                post(id: $id) {
                    id
                    title
                    tags { id name }
                }
            }
            """)
        documents.normalize(
            plan: p, variables: ["id": "p1"],
            data: .object([
                "post": .object([
                    "__typename": "Post", "id": "p1", "title": "Post 1",
                    "tags": .array([
                        .object(["__typename": "Tag", "id": "t1", "name": "Tag 1"]),
                        .object(["__typename": "Tag", "id": "t2", "name": "Tag 2"]),
                    ]),
                ])
            ]))
        let res = documents.materialize(plan: p, variables: ["id": "p1"])
        let tags = res.data["post"]?["tags"]?.array ?? []
        XCTAssertEqual(tags.count, 2)
        XCTAssertEqual(tags[0]["id"]?.string, "t1")
        XCTAssertEqual(tags[0]["name"]?.string, "Tag 1")
        XCTAssertEqual(tags[1]["id"]?.string, "t2")
        XCTAssertEqual(tags[1]["name"]?.string, "Tag 2")
    }

    func test_explicit_null_link_is_valid_data_not_a_miss() throws {
        let (_, documents) = makeStack()
        let p = try plan(
            """
            query Q($id: ID!) {
                post(id: $id) { id author { id email } }
            }
            """)
        documents.normalize(
            plan: p, variables: ["id": "p1"],
            data: .object([
                "post": .object(["__typename": "Post", "id": "p1", "author": .null])
            ]))
        let res = documents.materialize(plan: p, variables: ["id": "p1"])
        XCTAssertNotEqual(res.source, .none)
        if case .null = res.data["post"]?["author"] ?? .undefined { /* ok */
        } else {
            XCTFail("expected explicit null author")
        }
    }

    func test_hydrates_in_place_when_record_appears_after_initial_null() throws {
        let (_, documents) = makeStack()
        let p = try plan(
            """
            query Q($id: ID!) {
                post(id: $id) { id author { id email } }
            }
            """)
        documents.normalize(
            plan: p, variables: ["id": "p1"],
            data: .object([
                "post": .object(["__typename": "Post", "id": "p1", "author": .null])
            ]))
        let r1 = documents.materialize(plan: p, variables: ["id": "p1"])
        XCTAssertNotEqual(r1.source, .none)
        if case .null = r1.data["post"]?["author"] ?? .undefined { /* ok */
        } else {
            XCTFail("expected null author at first read")
        }

        documents.normalize(
            plan: p, variables: ["id": "p1"],
            data: .object([
                "post": .object([
                    "__typename": "Post", "id": "p1",
                    "author": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"]),
                ])
            ]))
        let r2 = documents.materialize(plan: p, variables: ["id": "p1"], options: MaterializeOptions(preferCache: false))
        XCTAssertEqual(r2.data["post"]?["author"]?["id"]?.string, "u1")
        XCTAssertEqual(r2.data["post"]?["author"]?["email"]?.string, "u1@example.com")
    }

    func test_returns_consistent_data_for_same_query() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])
            ]))
        let r1 = documents.materialize(plan: p, variables: ["id": "u1"])
        let r2 = documents.materialize(plan: p, variables: ["id": "u1"])
        XCTAssertEqual(r1.data["user"]?["id"]?.string, r2.data["user"]?["id"]?.string)
        XCTAssertEqual(r1.data["user"]?["email"]?.string, r2.data["user"]?["email"]?.string)
    }

    // MARK: - canonical/strict

    func test_strict_read_when_canonical_false_finds_per_page_data() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])
            ]))
        let res = documents.materialize(plan: p, variables: ["id": "u1"], options: MaterializeOptions(canonical: false, preferCache: false))
        XCTAssertEqual(res.source, .strict)
        XCTAssertTrue(res.strictOK)
        XCTAssertEqual(res.data["user"]?["email"]?.string, "u1@example.com")
    }

    func test_canonical_read_succeeds_for_normalized_entity() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: p, variables: ["id": "u2"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u2", "email": "u2@example.com"])
            ]))
        let res = documents.materialize(plan: p, variables: ["id": "u2"])
        XCTAssertEqual(res.source, .canonical)
        XCTAssertTrue(res.canonicalOK)
        XCTAssertTrue(res.strictOK)
        XCTAssertEqual(res.data["user"]?["email"]?.string, "u2@example.com")
    }

    // MARK: - fingerprinting

    func test_root_fingerprint_present_when_fingerprint_enabled() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])
            ]))
        let res = documents.materialize(plan: p, variables: ["id": "u1"])
        let fps = res.fingerprints.object ?? [:]
        if case .int(let v) = fps[CachebayConstants.fingerprintKey] ?? .undefined {
            XCTAssertGreaterThan(v, 0)
        } else {
            XCTFail("expected root __version int")
        }
        let userFp = fps["user"]?.object ?? [:]
        if case .int(let v) = userFp[CachebayConstants.fingerprintKey] ?? .undefined {
            XCTAssertGreaterThan(v, 0)
        } else {
            XCTFail("expected user.__version int")
        }
    }

    func test_same_fingerprint_for_unchanged_data() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])
            ]))
        let r1 = documents.materialize(plan: p, variables: ["id": "u1"])
        let r2 = documents.materialize(plan: p, variables: ["id": "u1"])
        let fp1 = r1.fingerprints.object?[CachebayConstants.fingerprintKey]
        let fp2 = r2.fingerprints.object?[CachebayConstants.fingerprintKey]
        XCTAssertEqual(fp1, fp2)
    }

    func test_different_fingerprint_after_data_changes() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])
            ]))
        let r1 = documents.materialize(plan: p, variables: ["id": "u1"])

        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1+updated@example.com"])
            ]))
        let r2 = documents.materialize(plan: p, variables: ["id": "u1"], options: MaterializeOptions(preferCache: false))
        let fp1 = r1.fingerprints.object?[CachebayConstants.fingerprintKey]
        let fp2 = r2.fingerprints.object?[CachebayConstants.fingerprintKey]
        XCTAssertNotEqual(fp1, fp2)
    }

    func test_disable_fingerprinting_does_not_emit_versions() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])
            ]))
        let res = documents.materialize(plan: p, variables: ["id": "u1"], options: MaterializeOptions(fingerprint: false, preferCache: false))
        let fps = res.fingerprints.object ?? [:]
        // No __version emitted when fingerprint disabled.
        XCTAssertNil(fps[CachebayConstants.fingerprintKey])
        // And no __version on the data — only declared selection fields plus __typename.
        let user = res.data["user"]?.object ?? [:]
        XCTAssertNil(user[CachebayConstants.fingerprintKey])
    }

    // MARK: - invalidate / preferCache / updateCache / evictAll

    func test_invalidate_drops_cached_result() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])
            ]))
        let opts = MaterializeOptions(preferCache: true, updateCache: true)
        let r1 = documents.materialize(plan: p, variables: ["id": "u1"], options: opts)
        XCTAssertFalse(r1.hot)

        let r2 = documents.materialize(plan: p, variables: ["id": "u1"], options: opts)
        XCTAssertTrue(r2.hot)

        documents.invalidate(plan: p, variables: ["id": "u1"])

        let r3 = documents.materialize(plan: p, variables: ["id": "u1"], options: opts)
        XCTAssertFalse(r3.hot, "invalidate should clear the cache hit")
    }

    func test_invalidate_specific_entry_does_not_affect_others() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        for (id, email) in [("u1", "u1@x.com"), ("u2", "u2@x.com")] {
            documents.normalize(
                plan: p, variables: ["id": .string(id)],
                data: .object([
                    "user": .object(["__typename": "User", "id": .string(id), "email": .string(email)])
                ]))
        }
        let opts = MaterializeOptions(preferCache: true, updateCache: true)
        _ = documents.materialize(plan: p, variables: ["id": "u1"], options: opts)
        _ = documents.materialize(plan: p, variables: ["id": "u2"], options: opts)
        XCTAssertTrue(documents.materialize(plan: p, variables: ["id": "u1"], options: opts).hot)
        XCTAssertTrue(documents.materialize(plan: p, variables: ["id": "u2"], options: opts).hot)

        documents.invalidate(plan: p, variables: ["id": "u1"])

        XCTAssertFalse(documents.materialize(plan: p, variables: ["id": "u1"], options: opts).hot)
        XCTAssertTrue(documents.materialize(plan: p, variables: ["id": "u2"], options: opts).hot)
    }

    func test_invalidate_unknown_key_does_not_throw() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        // Has data but never materialized.
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])
            ]))
        documents.invalidate(plan: p, variables: ["id": "u1"])  // no throw

        let res = documents.materialize(plan: p, variables: ["id": "u1"])
        XCTAssertFalse(res.hot)
        XCTAssertNotEqual(res.source, .none)
    }

    func test_invalidate_respects_canonical_flag() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])
            ]))
        let canonOpts = MaterializeOptions(canonical: true, preferCache: true, updateCache: true)
        let strictOpts = MaterializeOptions(canonical: false, preferCache: true, updateCache: true)
        _ = documents.materialize(plan: p, variables: ["id": "u1"], options: canonOpts)
        _ = documents.materialize(plan: p, variables: ["id": "u1"], options: strictOpts)
        XCTAssertTrue(documents.materialize(plan: p, variables: ["id": "u1"], options: canonOpts).hot)
        XCTAssertTrue(documents.materialize(plan: p, variables: ["id": "u1"], options: strictOpts).hot)

        documents.invalidate(plan: p, variables: ["id": "u1"], canonical: true)

        XCTAssertFalse(documents.materialize(plan: p, variables: ["id": "u1"], options: canonOpts).hot)
        XCTAssertTrue(documents.materialize(plan: p, variables: ["id": "u1"], options: strictOpts).hot)
    }

    func test_invalidate_respects_fingerprint_flag() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])
            ]))
        let fpOpts = MaterializeOptions(fingerprint: true, preferCache: true, updateCache: true)
        let plainOpts = MaterializeOptions(fingerprint: false, preferCache: true, updateCache: true)
        _ = documents.materialize(plan: p, variables: ["id": "u1"], options: fpOpts)
        _ = documents.materialize(plan: p, variables: ["id": "u1"], options: plainOpts)
        XCTAssertTrue(documents.materialize(plan: p, variables: ["id": "u1"], options: fpOpts).hot)
        XCTAssertTrue(documents.materialize(plan: p, variables: ["id": "u1"], options: plainOpts).hot)

        documents.invalidate(plan: p, variables: ["id": "u1"], fingerprint: true)

        XCTAssertFalse(documents.materialize(plan: p, variables: ["id": "u1"], options: fpOpts).hot)
        XCTAssertTrue(documents.materialize(plan: p, variables: ["id": "u1"], options: plainOpts).hot)
    }

    func test_invalidate_respects_rootId() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])
            ]))
        let entityOpts = MaterializeOptions(rootId: "User:u1", preferCache: true, updateCache: true)
        let rootOpts = MaterializeOptions(preferCache: true, updateCache: true)
        _ = documents.materialize(plan: p, variables: ["id": "u1"], options: entityOpts)
        _ = documents.materialize(plan: p, variables: ["id": "u1"], options: rootOpts)
        XCTAssertTrue(documents.materialize(plan: p, variables: ["id": "u1"], options: entityOpts).hot)
        XCTAssertTrue(documents.materialize(plan: p, variables: ["id": "u1"], options: rootOpts).hot)

        documents.invalidate(plan: p, variables: ["id": "u1"], rootId: "User:u1")

        XCTAssertFalse(documents.materialize(plan: p, variables: ["id": "u1"], options: entityOpts).hot)
        XCTAssertTrue(documents.materialize(plan: p, variables: ["id": "u1"], options: rootOpts).hot)
    }

    func test_default_options_do_not_pollute_cache() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])
            ]))
        // Default updateCache = false.
        let r1 = documents.materialize(plan: p, variables: ["id": "u1"])
        XCTAssertFalse(r1.hot)
        let r2 = documents.materialize(plan: p, variables: ["id": "u1"])
        XCTAssertFalse(r2.hot, "default updateCache=false must not seed the cache")
    }

    func test_preferCache_returns_cached_result() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])
            ]))
        let r1 = documents.materialize(plan: p, variables: ["id": "u1"], options: MaterializeOptions(preferCache: true, updateCache: true))
        XCTAssertFalse(r1.hot)
        let r2 = documents.materialize(plan: p, variables: ["id": "u1"], options: MaterializeOptions(preferCache: true))
        XCTAssertTrue(r2.hot)
    }

    func test_preferCache_falls_back_to_materialization_on_miss() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])
            ]))
        let res = documents.materialize(plan: p, variables: ["id": "u1"], options: MaterializeOptions(preferCache: true, updateCache: true))
        XCTAssertFalse(res.hot)
        XCTAssertNotEqual(res.source, .none)
    }

    func test_updateCache_explicit_true_caches_result() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        documents.normalize(
            plan: p, variables: ["id": "u1"],
            data: .object([
                "user": .object(["__typename": "User", "id": "u1", "email": "u1@example.com"])
            ]))
        _ = documents.materialize(plan: p, variables: ["id": "u1"], options: MaterializeOptions(preferCache: true, updateCache: true))
        let r2 = documents.materialize(plan: p, variables: ["id": "u1"])  // defaults to preferCache: true
        XCTAssertTrue(r2.hot)
    }

    func test_evictAll_clears_all_cached_results() throws {
        let (_, documents) = makeStack()
        let p = try plan("query Q($id: ID!) { user(id: $id) { id email } }")
        for id in ["u1", "u2"] {
            documents.normalize(
                plan: p, variables: ["id": .string(id)],
                data: .object([
                    "user": .object(["__typename": "User", "id": .string(id), "email": .string("\(id)@x.com")])
                ]))
            _ = documents.materialize(plan: p, variables: ["id": .string(id)], options: MaterializeOptions(updateCache: true))
        }
        XCTAssertTrue(documents.materialize(plan: p, variables: ["id": "u1"]).hot)
        XCTAssertTrue(documents.materialize(plan: p, variables: ["id": "u2"]).hot)

        documents.evictAll()

        XCTAssertFalse(documents.materialize(plan: p, variables: ["id": "u1"]).hot)
        XCTAssertFalse(documents.materialize(plan: p, variables: ["id": "u2"]).hot)
    }
}
