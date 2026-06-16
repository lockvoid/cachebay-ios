import XCTest
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import CachebayMacros

final class CachebayInterfaceMacroTests: XCTestCase {
    // Only the interface macro, so the golden shows just its own output (lifted shared
    // accessors, typename-directed init?, __dataDict, CachebayValue). The references to
    // `Video.__cachebayTypename` / `v.__dataDict()` are the contract @CachebayData fulfils.
    let macros: [String: any Macro.Type] = [
        "CachebayInterface": CachebayInterfaceMacro.self
    ]

    func test_interfaceExpansion() {
        assertMacroExpansion(
            #"""
            @CachebayInterface
            enum Element {
                case video(Video)
                case unknown(Shared)
                struct Shared {
                    let __typename: String
                    let id: String
                }
                struct Video {
                    let __typename: String
                    let id: String
                    let url: URL
                }
            }
            """#,
            expandedSource: #"""
                enum Element {
                    case video(Video)
                    case unknown(Shared)
                    struct Shared {
                        let __typename: String
                        let id: String
                    }
                    struct Video {
                        let __typename: String
                        let id: String
                        let url: URL
                    }

                    public var __typename: String {
                        switch self {
                        case .video(let v):
                            return v.__typename
                        case .unknown(let v):
                            return v.__typename
                        }
                    }

                    public var id: String {
                        switch self {
                        case .video(let v):
                            return v.id
                        case .unknown(let v):
                            return v.id
                        }
                    }

                    @_spi(Cachebay) public init?(_dataDict dict: [String: Cachebay.JSONValue]) {
                        let __typename = dict["__typename"]?.string
                        if __typename == Video.__cachebayTypename {
                            guard let v = Video(_dataDict: dict) else {
                                return nil
                            }
                            self = .video(v);
                            return
                        }
                        guard let v = Shared(_dataDict: dict) else {
                            return nil
                        }
                        self = .unknown(v)
                    }

                    @_spi(Cachebay) public func __dataDict() -> [String: Cachebay.JSONValue] {
                        switch self {
                        case .video(let v):
                            return v.__dataDict()
                        case .unknown(let v):
                            return v.__dataDict()
                        }
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

                    nonisolated(unsafe) public static let __cachebayFieldNames: [AnyKeyPath: String] = [\Self.__typename: "__typename", \Self.id: "id"]
                }
                """#,
            macros: macros
        )
    }
}
