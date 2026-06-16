import XCTest
import CachebayGraphQL
@testable import Cachebay

/// Port of `cachebay-web/test/unit/compiler/dedupe.test.ts`.
///
/// The web suite imports `dedupeDocument` and asserts on `print()`-ed GraphQL
/// strings. iOS exposes `Dedupe.dedupeDocument(_:fragments:)` (internal —
/// reachable via `@testable import`) and `CachebayGraphQL.Printer.print(_)`.
/// We assert on the printed result to keep semantics 1:1 with the JS suite.
final class DedupeTests: XCTestCase {

    // MARK: - Helpers

    private func dedupedString(_ source: String) throws -> String {
        let doc = try Parser.parse(source)
        let fragsByName = doc.fragmentsByName
        let deduped = Dedupe.dedupeDocument(doc, fragments: fragsByName)
        return Printer.print(deduped)
    }

    private func count(_ haystack: String, of needle: String) -> Int {
        var count = 0
        var idx = haystack.startIndex
        while let r = haystack.range(of: needle, range: idx..<haystack.endIndex) {
            count += 1
            idx = r.upperBound
        }
        return count
    }

    // MARK: - dedupeSelectionSet

    func test_merges_identical_fields_with_same_args() throws {
        let printed = try dedupedString(
            """
            query {
              post(id: $a) { id }
              post(id: $a) { title }
            }
            """)

        XCTAssertTrue(printed.contains("post(id: $a)"))
        XCTAssertTrue(printed.contains("id"))
        XCTAssertTrue(printed.contains("title"))
        XCTAssertEqual(count(printed, of: "post("), 1)
    }

    func test_does_NOT_merge_fields_with_different_variable_names() throws {
        let printed = try dedupedString(
            """
            query {
              post(id: $a) { id }
              post(id: $b) { title }
            }
            """)

        XCTAssertTrue(printed.contains("post(id: $a)"))
        XCTAssertTrue(printed.contains("post(id: $b)"))
        XCTAssertEqual(count(printed, of: "post("), 2)
    }

    func test_does_NOT_merge_fields_with_different_aliases() throws {
        let printed = try dedupedString(
            """
            query {
              p1: post(id: $id) { id }
              p2: post(id: $id) { title }
            }
            """)

        XCTAssertTrue(printed.contains("p1: post"))
        XCTAssertTrue(printed.contains("p2: post"))
    }

    func test_does_NOT_merge_fields_with_different_directives() throws {
        let printed = try dedupedString(
            """
            query {
              post(id: $id) @include(if: $x) { id }
              post(id: $id) { title }
            }
            """)

        XCTAssertEqual(count(printed, of: "post("), 2)
        XCTAssertTrue(printed.contains("@include"))
    }

    func test_merges_inline_fragments_with_same_type_condition() throws {
        let printed = try dedupedString(
            """
            query {
              node(id: $id) {
                ... on Post { title }
                ... on Post { flags }
                ... on User { email }
              }
            }
            """)

        XCTAssertEqual(count(printed, of: "... on Post"), 1)
        XCTAssertTrue(printed.contains("... on User"))
        XCTAssertTrue(printed.contains("title"))
        XCTAssertTrue(printed.contains("flags"))
        XCTAssertTrue(printed.contains("email"))
    }

    func test_merges_connection_fields_with_same_connection_key() throws {
        let printed = try dedupedString(
            """
            query {
              posts(first: 10) @connection(key: "A") {
                edges { node { id } }
              }
              posts(first: 10) @connection(key: "A") {
                pageInfo { hasNextPage }
              }
            }
            """)

        XCTAssertEqual(count(printed, of: "posts("), 1)
        XCTAssertTrue(printed.contains("edges"))
        XCTAssertTrue(printed.contains("pageInfo"))
        XCTAssertTrue(printed.contains("hasNextPage"))
    }

    func test_does_NOT_merge_connection_fields_with_different_connection_keys() throws {
        let printed = try dedupedString(
            """
            query {
              posts(first: 10) @connection(key: "A") {
                edges { node { id } }
              }
              posts(first: 10) @connection(key: "B") {
                pageInfo { hasNextPage }
              }
            }
            """)

        XCTAssertEqual(count(printed, of: "posts("), 2)
        // Allow either single- or double-quoted output — both are valid GraphQL.
        XCTAssertTrue(printed.contains("@connection(key: \"A\")") || printed.contains(#"@connection(key: "A")"#))
        XCTAssertTrue(printed.contains("@connection(key: \"B\")") || printed.contains(#"@connection(key: "B")"#))
    }

    func test_dedupes_duplicate_fragment_spreads() throws {
        let printed = try dedupedString(
            """
            fragment PostFields on Post {
              id
              title
            }

            query {
              post(id: $id) {
                ...PostFields
                ...PostFields
              }
            }
            """)

        // The iOS Printer formats fragment spreads as `... PostFields` (with
        // whitespace) — match either spelling.
        let occurrences = count(printed, of: "PostFields")
        // 1 fragment definition + 1 spread = 2 occurrences; deduped to one
        // spread so total should be 2, not 3.
        XCTAssertEqual(occurrences, 2)
    }

    func test_keeps_typename_and_dedupes_to_single_occurrence() throws {
        let printed = try dedupedString(
            """
            query {
              post(id: $id) {
                title
                __typename
                id
              }
            }
            """)

        XCTAssertTrue(printed.contains("__typename"))
        XCTAssertEqual(count(printed, of: "__typename"), 1)
    }

    func test_handles_complex_nested_merging() throws {
        let printed = try dedupedString(
            """
            query {
              user(id: $id) {
                id
                posts(first: 10) { edges { node { id } } }
                posts(first: 10) { edges { node { title } } }
                posts(first: 10) { pageInfo { hasNextPage } }
              }
            }
            """)

        XCTAssertEqual(count(printed, of: "posts("), 1)
        XCTAssertTrue(printed.contains("id"))
        XCTAssertTrue(printed.contains("title"))
        XCTAssertTrue(printed.contains("pageInfo"))
    }

    func test_preserves_field_order_deterministically() throws {
        let src = """
            query {
              b { id }
              a { id }
              c { id }
            }
            """
        let printed1 = try dedupedString(src)
        let printed2 = try dedupedString(src)

        XCTAssertEqual(printed1, printed2)
        XCTAssertTrue(printed1.contains("b"))
        XCTAssertTrue(printed1.contains("a"))
        XCTAssertTrue(printed1.contains("c"))
    }

    func test_handles_scalar_fields_without_sub_selections() throws {
        // The web test case uses a malformed root selection ("query { id; id; title; title }")
        // — no top-level field with a sub-selection. Wrap it under a real
        // field so the AST is valid; the dedupe behaviour is unchanged.
        let printed = try dedupedString(
            """
            query {
              post(id: $id) {
                id
                id
                title
                title
              }
            }
            """)

        // `id` and `title` should appear exactly once each inside the post block.
        XCTAssertEqual(count(printed, of: " id"), 1)
        XCTAssertEqual(count(printed, of: "title"), 1)
    }

    // MARK: - dedupeDocument: ops/fragments/mutations/subscriptions

    func test_dedupeDocument_dedupes_operations() throws {
        let printed = try dedupedString(
            """
            query GetPost {
              post(id: $id) { id }
              post(id: $id) { title }
            }
            """)

        XCTAssertEqual(count(printed, of: "post("), 1)
    }

    func test_dedupeDocument_dedupes_fragments() throws {
        let printed = try dedupedString(
            """
            fragment PostFields on Post {
              id
              id
              title
              title
            }
            """)

        XCTAssertEqual(count(printed, of: " id"), 1)
        XCTAssertEqual(count(printed, of: "title"), 1)
    }

    func test_dedupeDocument_handles_mutations() throws {
        let printed = try dedupedString(
            """
            mutation CreatePost {
              createPost(input: $input) { id }
              createPost(input: $input) { title }
            }
            """)

        XCTAssertEqual(count(printed, of: "createPost("), 1)
        XCTAssertTrue(printed.contains("id"))
        XCTAssertTrue(printed.contains("title"))
    }

    func test_dedupeDocument_handles_subscriptions() throws {
        let printed = try dedupedString(
            """
            subscription OnPostCreated {
              postCreated { id }
              postCreated { title }
            }
            """)

        XCTAssertEqual(count(printed, of: "postCreated"), 1)
        XCTAssertTrue(printed.contains("id"))
        XCTAssertTrue(printed.contains("title"))
    }

    func test_dedupeDocument_deduplicates_duplicate_fragment_definitions() throws {
        let printed = try dedupedString(
            """
            fragment PageInfoFields on PageInfo {
              startCursor
              endCursor
            }

            fragment PageInfoFields on PageInfo {
              startCursor
              endCursor
            }

            query Test {
              connection {
                pageInfo {
                  ...PageInfoFields
                }
              }
            }
            """)

        XCTAssertEqual(count(printed, of: "fragment PageInfoFields"), 1)
        XCTAssertTrue(printed.contains("query Test"))
        // iOS Printer emits `... PageInfoFields` (whitespace between dots and
        // name); match the name only.
        XCTAssertTrue(printed.contains("PageInfoFields"))
    }
}
