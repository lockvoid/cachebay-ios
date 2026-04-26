import XCTest
@testable import CachebayGraphQL

final class LexerTests: XCTestCase {
    private func tokens(_ source: String) throws -> [Token] {
        var l = Lexer(source: source)
        var out: [Token] = []
        while true {
            let tok = try l.next()
            out.append(tok)
            if tok.kind == .eof { break }
        }
        return out
    }

    func test_names_punctuation() throws {
        let t = try tokens("query Foo { user(id: 1) @cached }")
        XCTAssertEqual(t.map(\.kind), [
            .name, .name, .brace(open: true),
            .name, .paren(open: true), .name, .colon, .int, .paren(open: false),
            .at, .name,
            .brace(open: false),
            .eof,
        ])
    }

    func test_string_with_escapes() throws {
        let t = try tokens(#""hello\n\t\"world\"""#)
        XCTAssertEqual(t[0].kind, .string)
        XCTAssertEqual(t[0].value, "hello\n\t\"world\"")
    }

    func test_block_string_indent_strip() throws {
        let source = """
        \"\"\"
          hello
            world
        \"\"\"
        """
        let t = try tokens(source)
        XCTAssertEqual(t[0].kind, .blockString)
        XCTAssertEqual(t[0].value, "hello\n  world")
    }

    func test_numbers() throws {
        let t = try tokens("-1 2.5 3e2 -4.5e-3 0")
        XCTAssertEqual(t.map(\.kind), [.int, .float, .float, .float, .int, .eof])
    }

    func test_ellipsis_and_dollar() throws {
        let t = try tokens("...$x")
        XCTAssertEqual(t.map(\.kind), [.spread, .dollar, .name, .eof])
    }

    func test_comments_and_comma_whitespace() throws {
        let source = """
        # this is a comment
        { a, b }
        """
        let t = try tokens(source)
        XCTAssertEqual(t.map(\.kind), [.brace(open: true), .name, .name, .brace(open: false), .eof])
    }
}
