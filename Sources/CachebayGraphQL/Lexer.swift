import Foundation

public enum TokenKind: Hashable, Sendable {
    case name
    case int
    case float
    case string
    case blockString
    case dollar
    case bang
    case amp
    case paren(open: Bool)
    case bracket(open: Bool)
    case brace(open: Bool)
    case colon
    case equals
    case at
    case pipe
    case spread      // "..."
    case eof
}

public struct Token: Hashable, Sendable {
    public let kind: TokenKind
    public let value: String
    public let start: Int
    public let end: Int
    public let line: Int
    public let column: Int

    public var location: SourceLocation {
        SourceLocation(start: start, end: end, line: line, column: column)
    }
}

public struct SyntaxError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public let line: Int
    public let column: Int
    public var description: String { "SyntaxError at \(line):\(column): \(message)" }
}

/// Minimal GraphQL lexer. Input is UTF-8; operates on `String.UnicodeScalarView` for perf.
public struct Lexer {
    private let source: [UInt8]
    private var offset: Int = 0
    private var line: Int = 1
    private var lineStart: Int = 0

    public init(source: String) {
        self.source = Array(source.utf8)
    }

    public mutating func next() throws -> Token {
        try skipIgnored()
        if offset >= source.count {
            return Token(kind: .eof, value: "", start: offset, end: offset, line: line, column: column())
        }

        let b = source[offset]
        let startOffset = offset
        let startColumn = column()

        switch b {
        case UInt8(ascii: "!"):
            offset += 1
            return Token(kind: .bang, value: "!", start: startOffset, end: offset, line: line, column: startColumn)
        case UInt8(ascii: "$"):
            offset += 1
            return Token(kind: .dollar, value: "$", start: startOffset, end: offset, line: line, column: startColumn)
        case UInt8(ascii: "&"):
            offset += 1
            return Token(kind: .amp, value: "&", start: startOffset, end: offset, line: line, column: startColumn)
        case UInt8(ascii: "("):
            offset += 1
            return Token(kind: .paren(open: true), value: "(", start: startOffset, end: offset, line: line, column: startColumn)
        case UInt8(ascii: ")"):
            offset += 1
            return Token(kind: .paren(open: false), value: ")", start: startOffset, end: offset, line: line, column: startColumn)
        case UInt8(ascii: "["):
            offset += 1
            return Token(kind: .bracket(open: true), value: "[", start: startOffset, end: offset, line: line, column: startColumn)
        case UInt8(ascii: "]"):
            offset += 1
            return Token(kind: .bracket(open: false), value: "]", start: startOffset, end: offset, line: line, column: startColumn)
        case UInt8(ascii: "{"):
            offset += 1
            return Token(kind: .brace(open: true), value: "{", start: startOffset, end: offset, line: line, column: startColumn)
        case UInt8(ascii: "}"):
            offset += 1
            return Token(kind: .brace(open: false), value: "}", start: startOffset, end: offset, line: line, column: startColumn)
        case UInt8(ascii: ":"):
            offset += 1
            return Token(kind: .colon, value: ":", start: startOffset, end: offset, line: line, column: startColumn)
        case UInt8(ascii: "="):
            offset += 1
            return Token(kind: .equals, value: "=", start: startOffset, end: offset, line: line, column: startColumn)
        case UInt8(ascii: "@"):
            offset += 1
            return Token(kind: .at, value: "@", start: startOffset, end: offset, line: line, column: startColumn)
        case UInt8(ascii: "|"):
            offset += 1
            return Token(kind: .pipe, value: "|", start: startOffset, end: offset, line: line, column: startColumn)
        case UInt8(ascii: "."):
            if offset + 2 < source.count, source[offset + 1] == UInt8(ascii: "."), source[offset + 2] == UInt8(ascii: ".") {
                offset += 3
                return Token(kind: .spread, value: "...", start: startOffset, end: offset, line: line, column: startColumn)
            }
            throw syntax("Unexpected character '.'")
        case UInt8(ascii: "\""):
            return try readString(startOffset: startOffset, startColumn: startColumn)
        case UInt8(ascii: "_"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"):
            return readName(startOffset: startOffset, startColumn: startColumn)
        case UInt8(ascii: "-"),
             UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try readNumber(startOffset: startOffset, startColumn: startColumn)
        default:
            throw syntax("Unexpected character '\(Character(UnicodeScalar(b)))'")
        }
    }

    private mutating func column() -> Int { offset - lineStart + 1 }

    private mutating func skipIgnored() throws {
        while offset < source.count {
            let b = source[offset]
            if b == 0xEF && offset + 2 < source.count && source[offset + 1] == 0xBB && source[offset + 2] == 0xBF {
                offset += 3 // BOM
                continue
            }
            switch b {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: ","):
                offset += 1
            case UInt8(ascii: "\n"):
                offset += 1
                line += 1
                lineStart = offset
            case UInt8(ascii: "\r"):
                offset += 1
                if offset < source.count, source[offset] == UInt8(ascii: "\n") { offset += 1 }
                line += 1
                lineStart = offset
            case UInt8(ascii: "#"):
                while offset < source.count, source[offset] != UInt8(ascii: "\n"), source[offset] != UInt8(ascii: "\r") {
                    offset += 1
                }
            default:
                return
            }
        }
    }

    private mutating func readName(startOffset: Int, startColumn: Int) -> Token {
        while offset < source.count {
            let b = source[offset]
            if b == UInt8(ascii: "_")
                || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
                || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
                || (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
            {
                offset += 1
            } else {
                break
            }
        }
        let value = String(decoding: source[startOffset..<offset], as: UTF8.self)
        return Token(kind: .name, value: value, start: startOffset, end: offset, line: line, column: startColumn)
    }

    private mutating func readNumber(startOffset: Int, startColumn: Int) throws -> Token {
        var isFloat = false
        if source[offset] == UInt8(ascii: "-") { offset += 1 }
        if offset < source.count, source[offset] == UInt8(ascii: "0") {
            offset += 1
        } else {
            guard offset < source.count, (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(source[offset]) else {
                throw syntax("Invalid number")
            }
            offset += 1
            while offset < source.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(source[offset]) { offset += 1 }
        }
        if offset < source.count, source[offset] == UInt8(ascii: ".") {
            isFloat = true
            offset += 1
            while offset < source.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(source[offset]) { offset += 1 }
        }
        if offset < source.count, source[offset] == UInt8(ascii: "e") || source[offset] == UInt8(ascii: "E") {
            isFloat = true
            offset += 1
            if offset < source.count, source[offset] == UInt8(ascii: "+") || source[offset] == UInt8(ascii: "-") { offset += 1 }
            while offset < source.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(source[offset]) { offset += 1 }
        }
        let value = String(decoding: source[startOffset..<offset], as: UTF8.self)
        return Token(kind: isFloat ? .float : .int, value: value, start: startOffset, end: offset, line: line, column: startColumn)
    }

    private mutating func readString(startOffset: Int, startColumn: Int) throws -> Token {
        // Check for block string """..."""
        if offset + 2 < source.count,
           source[offset] == UInt8(ascii: "\""),
           source[offset + 1] == UInt8(ascii: "\""),
           source[offset + 2] == UInt8(ascii: "\"")
        {
            offset += 3
            var body: [UInt8] = []
            while offset < source.count {
                if offset + 2 < source.count,
                   source[offset] == UInt8(ascii: "\""),
                   source[offset + 1] == UInt8(ascii: "\""),
                   source[offset + 2] == UInt8(ascii: "\"")
                {
                    offset += 3
                    let raw = String(decoding: body, as: UTF8.self)
                    let unescaped = blockStringValue(raw)
                    return Token(kind: .blockString, value: unescaped, start: startOffset, end: offset, line: line, column: startColumn)
                }
                if source[offset] == UInt8(ascii: "\\") && offset + 3 < source.count
                    && source[offset + 1] == UInt8(ascii: "\"")
                    && source[offset + 2] == UInt8(ascii: "\"")
                    && source[offset + 3] == UInt8(ascii: "\"") {
                    body.append(UInt8(ascii: "\""))
                    body.append(UInt8(ascii: "\""))
                    body.append(UInt8(ascii: "\""))
                    offset += 4
                    continue
                }
                if source[offset] == UInt8(ascii: "\n") {
                    body.append(UInt8(ascii: "\n"))
                    offset += 1
                    line += 1
                    lineStart = offset
                    continue
                }
                body.append(source[offset])
                offset += 1
            }
            throw syntax("Unterminated block string")
        }

        // Regular string "..."
        offset += 1
        var bytes: [UInt8] = []
        while offset < source.count {
            let b = source[offset]
            if b == UInt8(ascii: "\"") {
                offset += 1
                let value = String(decoding: bytes, as: UTF8.self)
                return Token(kind: .string, value: value, start: startOffset, end: offset, line: line, column: startColumn)
            }
            if b == UInt8(ascii: "\n") || b == UInt8(ascii: "\r") { throw syntax("Unterminated string") }
            if b == UInt8(ascii: "\\") {
                offset += 1
                if offset >= source.count { throw syntax("Invalid escape") }
                let esc = source[offset]
                switch esc {
                case UInt8(ascii: "\""): bytes.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): bytes.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): bytes.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): bytes.append(0x08)
                case UInt8(ascii: "f"): bytes.append(0x0C)
                case UInt8(ascii: "n"): bytes.append(UInt8(ascii: "\n"))
                case UInt8(ascii: "r"): bytes.append(UInt8(ascii: "\r"))
                case UInt8(ascii: "t"): bytes.append(UInt8(ascii: "\t"))
                case UInt8(ascii: "u"):
                    guard offset + 4 < source.count else { throw syntax("Invalid unicode escape") }
                    let hex = String(decoding: source[(offset + 1)...(offset + 4)], as: UTF8.self)
                    guard let code = UInt32(hex, radix: 16), let scalar = UnicodeScalar(code) else { throw syntax("Invalid unicode escape") }
                    let str = String(scalar)
                    bytes.append(contentsOf: str.utf8)
                    offset += 4
                default:
                    throw syntax("Invalid escape \\\(Character(UnicodeScalar(esc)))")
                }
                offset += 1
                continue
            }
            bytes.append(b)
            offset += 1
        }
        throw syntax("Unterminated string")
    }

    private func syntax(_ msg: String) -> SyntaxError {
        SyntaxError(message: msg, line: line, column: offset - lineStart + 1)
    }
}

/// Canonicalise block-string value per GraphQL spec.
@inlinable func blockStringValue(_ raw: String) -> String {
    // Split into lines
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    // Determine common indent (excluding first line)
    var commonIndent = Int.max
    for i in 1..<lines.count {
        let line = lines[i]
        var indent = 0
        for c in line {
            if c == " " || c == "\t" { indent += 1 } else { break }
        }
        if indent < line.count {
            commonIndent = Swift.min(commonIndent, indent)
        }
    }
    // Remove common indent from every non-first line
    var result: [String] = []
    for (i, line) in lines.enumerated() {
        if i == 0 {
            result.append(line)
        } else if commonIndent != .max && line.count >= commonIndent {
            result.append(String(line.dropFirst(commonIndent)))
        } else {
            result.append(line)
        }
    }
    // Trim leading and trailing blank lines
    while let first = result.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
        result.removeFirst()
    }
    while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        result.removeLast()
    }
    return result.joined(separator: "\n")
}
