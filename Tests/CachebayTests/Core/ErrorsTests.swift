import XCTest
@testable import Cachebay

/// Port of `cachebay-web/test/unit/core/errors.test.ts`.
///
/// The web side ships two distinct error classes (`CacheMissError`,
/// `StaleResponseError`); iOS folds both into the `CombinedError`
/// surface (network message + GraphQL errors) plus a richer
/// `CachebayError` enum for internal failure classes. These tests
/// cover the equivalent behaviours: factory shape, message defaults,
/// and the catch-and-classify pattern.
final class ErrorsTests: XCTestCase {

    // MARK: - CombinedError.cacheMiss factory

    func test_cacheMiss_defaultMessage() {
        let err = CombinedError.cacheMiss()
        XCTAssertEqual(err.networkError, "Cache miss: no data available for cache-only query")
        XCTAssertTrue(err.graphqlErrors.isEmpty)
    }

    func test_cacheMiss_customMessage() {
        let custom = "Custom cache miss message"
        let err = CombinedError.cacheMiss(custom)
        XCTAssertEqual(err.networkError, custom)
    }

    // MARK: - CombinedError.stale factory

    func test_stale_defaultMessage() {
        let err = CombinedError.stale()
        XCTAssertEqual(err.networkError, "Response ignored: newer request in flight")
        XCTAssertTrue(err.graphqlErrors.isEmpty)
    }

    // MARK: - CombinedError shape and equality

    func test_combinedError_networkOnly_description() {
        let err = CombinedError(networkMessage: "boom")
        XCTAssertTrue(err.description.contains("[Network]"))
        XCTAssertTrue(err.description.contains("boom"))
    }

    func test_combinedError_graphqlOnly_description() {
        let err = CombinedError(graphqlErrors: [GraphQLResponseError(message: "field bad")])
        XCTAssertTrue(err.description.contains("[GraphQL]"))
        XCTAssertTrue(err.description.contains("field bad"))
    }

    func test_combinedError_unspecified_description() {
        let err = CombinedError(networkError: nil, graphqlErrors: [])
        XCTAssertTrue(err.description.contains("[Error]"))
    }

    func test_combinedError_isCatchable() {
        // Drop into a typical do/catch and verify we can introspect the
        // network message — equivalent to JS `instanceof` discrimination.
        do {
            throw CombinedError.cacheMiss()
        } catch let err as CombinedError {
            XCTAssertNotNil(err.networkError)
            XCTAssertEqual(err.networkError, "Cache miss: no data available for cache-only query")
        } catch {
            XCTFail("expected CombinedError, got \(error)")
        }
    }

    func test_combinedError_classification_pattern() {
        // The web suite filters mixed errors into "cacheMiss" / "stale" /
        // "other"; on iOS the classification is by message content.
        let errs: [Error] = [
            CombinedError.cacheMiss(),
            CombinedError.stale(),
            CachebayError.networkError("Generic"),
        ]

        let cacheMiss = errs.compactMap { $0 as? CombinedError }.filter {
            ($0.networkError ?? "").contains("Cache miss")
        }
        let stale = errs.compactMap { $0 as? CombinedError }.filter {
            ($0.networkError ?? "").contains("newer request")
        }
        let others = errs.compactMap { $0 as? CachebayError }

        XCTAssertEqual(cacheMiss.count, 1)
        XCTAssertEqual(stale.count, 1)
        XCTAssertEqual(others.count, 1)
    }

    // MARK: - CachebayError enum

    func test_cachebayError_descriptions() {
        XCTAssertEqual(CachebayError.cacheMiss("none").description, "[cache-miss] none")
        XCTAssertEqual(
            CachebayError.staleResponse.description,
            "[stale] a newer request superseded this one")
        XCTAssertEqual(CachebayError.invalidPlan("bad").description, "[invalid-plan] bad")
        XCTAssertEqual(CachebayError.networkError("oops").description, "[network] oops")
        let g = CachebayError.graphql(messages: ["x", "y"])
        XCTAssertEqual(g.description, "[graphql] x; y")
    }

    // MARK: - GraphQLResponseError shape

    func test_graphqlResponseError_holdsAllFields() {
        let err = GraphQLResponseError(
            message: "Boom",
            path: ["root", "post"],
            locations: [.init(line: 1, column: 2)],
            extensions: ["code": .string("INTERNAL")]
        )
        XCTAssertEqual(err.message, "Boom")
        XCTAssertEqual(err.path, ["root", "post"])
        XCTAssertEqual(err.locations?.count, 1)
        XCTAssertEqual(err.locations?.first?.line, 1)
        XCTAssertEqual(err.extensions?["code"], .string("INTERNAL"))
    }

    func test_combinedError_isHashable_andEquatable() {
        // The Hashable conformance is load-bearing for inserting into Sets
        // (e.g. for de-duping watcher emissions).
        let a = CombinedError(networkMessage: "x", graphqlErrors: [GraphQLResponseError(message: "y")])
        let b = CombinedError(networkMessage: "x", graphqlErrors: [GraphQLResponseError(message: "y")])
        XCTAssertEqual(a, b)
        let s: Set<CombinedError> = [a, b]
        XCTAssertEqual(s.count, 1)
    }
}
