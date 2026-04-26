import XCTest
@testable import CachebayGraphQL

final class ParserTests: XCTestCase {
    func test_simple_query() throws {
        let doc = try Parser.parse("""
        query Foo($id: ID!) {
            post(id: $id) {
                id
                title
            }
        }
        """)
        XCTAssertEqual(doc.operations.count, 1)
        let op = doc.operations[0]
        XCTAssertEqual(op.operation, .query)
        XCTAssertEqual(op.name, "Foo")
        XCTAssertEqual(op.variableDefinitions.count, 1)
        XCTAssertEqual(op.variableDefinitions[0].name, "id")
        guard case .nonNull(.named("ID")) = op.variableDefinitions[0].type else {
            return XCTFail("Expected ID!")
        }
        guard case .field(let postField) = op.selectionSet[0] else { return XCTFail() }
        XCTAssertEqual(postField.name, "post")
        XCTAssertEqual(postField.arguments.count, 1)
        XCTAssertEqual(postField.selectionSet.count, 2)
    }

    func test_shorthand_query() throws {
        let doc = try Parser.parse("{ me { id } }")
        XCTAssertEqual(doc.operations[0].operation, .query)
        XCTAssertNil(doc.operations[0].name)
    }

    func test_fragment() throws {
        let doc = try Parser.parse("""
        fragment PostFields on Post {
            id
            title
            author { id name }
        }
        """)
        XCTAssertEqual(doc.fragments.count, 1)
        XCTAssertEqual(doc.fragments[0].name, "PostFields")
        XCTAssertEqual(doc.fragments[0].typeCondition, "Post")
    }

    func test_inline_fragment_and_spread() throws {
        let doc = try Parser.parse("""
        query Foo {
            node {
                ... on Post { id }
                ...OtherFields
            }
        }
        """)
        let op = doc.operations[0]
        guard case .field(let nodeF) = op.selectionSet[0] else { return XCTFail() }
        XCTAssertEqual(nodeF.selectionSet.count, 2)
        guard case .inlineFragment(let ifr) = nodeF.selectionSet[0] else { return XCTFail() }
        XCTAssertEqual(ifr.typeCondition, "Post")
        guard case .fragmentSpread(let sp) = nodeF.selectionSet[1] else { return XCTFail() }
        XCTAssertEqual(sp.name, "OtherFields")
    }

    func test_directive_with_args() throws {
        let doc = try Parser.parse("""
        query Q {
            posts @connection(key: "Feed", filters: ["category"], mode: "infinite") {
                edges { node { id } }
            }
        }
        """)
        guard case .field(let f) = doc.operations[0].selectionSet[0] else { return XCTFail() }
        XCTAssertEqual(f.directives.count, 1)
        XCTAssertEqual(f.directives[0].name, "connection")
        XCTAssertEqual(f.directives[0].arguments.count, 3)
    }

    func test_sdl_object_type() throws {
        let doc = try Parser.parse("""
        type Post {
            id: ID!
            title: String
            author: User
        }

        type User {
            id: ID!
            name: String!
        }
        """)
        // Should produce a schema definition collecting types
        let schemas = doc.definitions.compactMap { if case .schema(let s) = $0 { return s } else { return nil } }
        XCTAssertEqual(schemas.count, 1)
        XCTAssertEqual(schemas[0].types.count, 2)
    }

    func test_roundtrip_print() throws {
        let source = "query Q { user(id: 1) { id name } }"
        let doc = try Parser.parse(source)
        let printed = Printer.print(doc)
        let reparsed = try Parser.parse(printed)
        XCTAssertEqual(reparsed.operations.count, 1)
        XCTAssertEqual(reparsed.operations[0].name, "Q")
    }
}
