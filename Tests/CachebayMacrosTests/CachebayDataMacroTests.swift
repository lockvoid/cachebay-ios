import XCTest
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import CachebayMacros

final class CachebayDataMacroTests: XCTestCase {
    let macros: [String: any Macro.Type] = [
        "CachebayData": CachebayDataMacro.self,
        "CachebayDefault": CachebayDefaultMacro.self,
    ]

    // A8 — diagnostics: @CachebayData on a non-struct emits a clear error (Risk #2 mitigation).
    func test_diagnostic_onClass() {
        assertMacroExpansion(
            #"""
            @CachebayData(typename: "X")
            class X {
                let id: String
            }
            """#,
            expandedSource: #"""
            class X {
                let id: String
            }
            """#,
            diagnostics: [
                DiagnosticSpec(message: "@CachebayData can only be applied to a struct.", line: 1, column: 1)
            ],
            macros: macros
        )
    }

    // A1/A3 — minimal struct: full member surface (init, eager init?(_dataDict:),
    // __dataDict round-trip, CachebayValue, KeyPath field-name table). Content is at
    // column 0 so the golden is a verbatim paste of the macro's output.
    func test_minimalStruct_fullExpansion() {
        assertMacroExpansion(
#"""
@CachebayData(typename: "Cook")
struct Cook {
    let __typename: String
    let id: String
    let title: String
}
"""#,
            expandedSource:
#"""
struct Cook {
    let __typename: String
    let id: String
    let title: String

    public static let __cachebayTypename: String = "Cook"

    public init(__typename: String = "Cook", id: String, title: String) {
        self.__typename = __typename
        self.id = id
        self.title = title
    }

    @_spi(Cachebay) public init?(_dataDict dict: [String: Cachebay.JSONValue]) {
        guard let __typename = String(cachebayJSON: dict["__typename"] ?? .undefined) else {
            return nil
        }
        guard __typename == "Cook" else {
            return nil
        }
        guard let id = String(cachebayJSON: dict["id"] ?? .undefined) else {
            return nil
        }
        guard let title = String(cachebayJSON: dict["title"] ?? .undefined) else {
            return nil
        }
        self.__typename = __typename
        self.id = id
        self.title = title
    }

    @_spi(Cachebay) public func __dataDict() -> [String: Cachebay.JSONValue] {
        var d: [String: Cachebay.JSONValue] = [:]
        d["__typename"] = self.__typename.cachebayJSON
        d["id"] = self.id.cachebayJSON
        d["title"] = self.title.cachebayJSON
        return d
    }

    public init?(cachebayJSON json: Cachebay.JSONValue) {
        guard case .object(let d) = json else {
            return nil
        }
        self.init(_dataDict: d)
    }

    public var cachebayJSON: Cachebay.JSONValue {
        .object(self.__dataDict())
    }

    nonisolated(unsafe) public static let __cachebayFieldNames: [AnyKeyPath: String] = [\Self.__typename: "__typename", \Self.id: "id", \Self.title: "title"]
}
"""#,
            macros: macros
        )
    }

    // A2/A4 — defaults (@CachebayDefault literal, optional -> nil) + optional decode.
    func test_defaults_and_optional_expansion() {
        assertMacroExpansion(
#"""
@CachebayData(typename: "VideoElement")
struct Video {
    let __typename: String
    let id: String
    @CachebayDefault("a0") let rank: String
    let intent: String?
}
"""#,
            expandedSource:
#"""
struct Video {
    let __typename: String
    let id: String
    let rank: String
    let intent: String?

    public static let __cachebayTypename: String = "VideoElement"

    public init(__typename: String = "VideoElement", id: String, rank: String = "a0", intent: String? = nil) {
        self.__typename = __typename
        self.id = id
        self.rank = rank
        self.intent = intent
    }

    @_spi(Cachebay) public init?(_dataDict dict: [String: Cachebay.JSONValue]) {
        guard let __typename = String(cachebayJSON: dict["__typename"] ?? .undefined) else {
            return nil
        }
        guard __typename == "VideoElement" else {
            return nil
        }
        guard let id = String(cachebayJSON: dict["id"] ?? .undefined) else {
            return nil
        }
        guard let rank = String(cachebayJSON: dict["rank"] ?? .undefined) else {
            return nil
        }
        guard let intent = String?(cachebayJSON: dict["intent"] ?? .undefined) else {
            return nil
        }
        self.__typename = __typename
        self.id = id
        self.rank = rank
        self.intent = intent
    }

    @_spi(Cachebay) public func __dataDict() -> [String: Cachebay.JSONValue] {
        var d: [String: Cachebay.JSONValue] = [:]
        d["__typename"] = self.__typename.cachebayJSON
        d["id"] = self.id.cachebayJSON
        d["rank"] = self.rank.cachebayJSON
        d["intent"] = self.intent.cachebayJSON
        return d
    }

    public init?(cachebayJSON json: Cachebay.JSONValue) {
        guard case .object(let d) = json else {
            return nil
        }
        self.init(_dataDict: d)
    }

    public var cachebayJSON: Cachebay.JSONValue {
        .object(self.__dataDict())
    }

    nonisolated(unsafe) public static let __cachebayFieldNames: [AnyKeyPath: String] = [\Self.__typename: "__typename", \Self.id: "id", \Self.rank: "rank", \Self.intent: "intent"]
}
"""#,
            macros: macros
        )
    }
}
