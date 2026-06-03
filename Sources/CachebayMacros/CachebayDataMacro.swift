import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// `@CachebayData(typename:)` — generates the typed-struct member surface.
///
/// Phase A1: public memberwise init with per-field defaults
/// (`__typename` -> typename literal, `@CachebayDefault(x)` -> x, optional -> nil).
public struct CachebayDataMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.diagnose(
                Diagnostic(
                    node: node,
                    message: CachebayMacroDiagnostic.dataOnlyOnStruct
                )
            )
            return []
        }

        let typename = Self.extractTypename(node) ?? ""
        let props = Self.storedProperties(of: structDecl)

        var members: [DeclSyntax] = []
        if !typename.isEmpty {
            // Lets a `@CachebayInterface` enum dispatch by `__typename` without
            // needing cross-type knowledge (it references `Video.__cachebayTypename`).
            members.append("public static let __cachebayTypename: String = \"\(raw: typename)\"")
        }
        members.append(DeclSyntax(try Self.makeMemberwiseInit(props: props, typename: typename)))
        members.append(Self.makeDictInit(props: props, typename: typename))
        members.append(Self.makeDataDict(props: props))
        members.append(contentsOf: Self.makeCachebayValueConformance())
        members.append(Self.makeFieldNamesMap(props: props))
        // Codable (persistence / interop) — only when the type opts in by
        // declaring `Codable`/`Decodable`/`Encodable`. We emit it ourselves
        // (rather than relying on synthesis) so `init(from:)` can honor
        // `@CachebayDefault` (`decodeIfPresent ?? default`), keeping persisted
        // blobs decodable across additive schema bumps.
        if Self.declaresCodable(structDecl) {
            members.append(contentsOf: Self.makeCodable(props: props, typename: typename))
        }
        return members
    }
}

// MARK: - Shared model

/// A stored property as seen by the macro.
struct CachebayProperty {
    let name: String
    let type: TypeSyntax
    let isOptional: Bool
    /// The `@CachebayDefault(...)` value expression, if present.
    let defaultExpr: ExprSyntax?
}

extension CachebayDataMacro {
    /// Extracts the `typename:` string-literal argument from the attribute.
    static func extractTypename(_ node: AttributeSyntax) -> String? {
        guard let args = node.arguments?.as(LabeledExprListSyntax.self) else { return nil }
        for arg in args where arg.label?.text == "typename" {
            if let str = arg.expression.as(StringLiteralExprSyntax.self) {
                return str.representedLiteralValue
            }
        }
        return nil
    }

    /// Stored `let`/`var` properties in declaration order. Skips `static` and computed.
    static func storedProperties(of decl: StructDeclSyntax) -> [CachebayProperty] {
        var out: [CachebayProperty] = []
        for member in decl.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            if varDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) { continue }
            for binding in varDecl.bindings {
                guard let idPattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                if binding.accessorBlock != nil { continue } // computed property
                guard let type = binding.typeAnnotation?.type else { continue }
                let isOptional = type.is(OptionalTypeSyntax.self)
                    || (type.as(IdentifierTypeSyntax.self)?.name.text == "Optional")
                out.append(
                    CachebayProperty(
                        name: idPattern.identifier.text,
                        type: type,
                        isOptional: isOptional,
                        defaultExpr: Self.defaultValue(from: varDecl)
                    )
                )
            }
        }
        return out
    }

    /// The `@CachebayDefault(<expr>)` value attached to a property, if any.
    static func defaultValue(from varDecl: VariableDeclSyntax) -> ExprSyntax? {
        for attr in varDecl.attributes {
            guard let attribute = attr.as(AttributeSyntax.self) else { continue }
            let name = attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.text
            guard name == "CachebayDefault" else { continue }
            if let args = attribute.arguments?.as(LabeledExprListSyntax.self), let first = args.first {
                return first.expression
            }
        }
        return nil
    }

    /// Builds `public init(...)` with per-field defaults.
    static func makeMemberwiseInit(props: [CachebayProperty], typename: String) throws -> InitializerDeclSyntax {
        let params: [String] = props.map { p in
            let suffix: String
            if p.name == "__typename" && !typename.isEmpty {
                suffix = " = \"\(typename)\""
            } else if let d = p.defaultExpr {
                suffix = " = \(d.trimmedDescription)"
            } else if p.isOptional {
                suffix = " = nil"
            } else {
                suffix = ""
            }
            return "\(p.name): \(p.type.trimmedDescription)\(suffix)"
        }
        let paramList = params.joined(separator: ", ")

        return try InitializerDeclSyntax(
            "public init(\(raw: paramList))" as SyntaxNodeString,
            bodyBuilder: {
                for p in props {
                    "self.\(raw: p.name) = \(raw: p.name)"
                }
            }
        )
    }

    /// Builds the eager `@_spi(Cachebay) init?(_dataDict:)`. Each required field
    /// decodes via the uniform `CachebayValue` hook; a nil → whole-record miss.
    /// When `typename` is non-empty, the record's `__typename` must match (so an
    /// interface can dispatch by trying each variant's initializer in turn).
    static func makeDictInit(props: [CachebayProperty], typename: String) -> DeclSyntax {
        var lines: [String] = []
        for p in props {
            let src = "dict[\"\(p.name)\"] ?? .undefined"
            lines.append("guard let \(p.name) = \(p.type.trimmedDescription)(cachebayJSON: \(src)) else { return nil }")
            if p.name == "__typename" && !typename.isEmpty {
                lines.append("guard \(p.name) == \"\(typename)\" else { return nil }")
            }
        }
        for p in props {
            lines.append("self.\(p.name) = \(p.name)")
        }
        let body = lines.joined(separator: "\n")
        return """
        @_spi(Cachebay) public init?(_dataDict dict: [String: Cachebay.JSONValue]) {
        \(raw: body)
        }
        """
    }

    /// Builds the round-trip `@_spi(Cachebay) __dataDict()` bridge.
    static func makeDataDict(props: [CachebayProperty]) -> DeclSyntax {
        var lines: [String] = ["var d: [String: Cachebay.JSONValue] = [:]"]
        for p in props {
            lines.append("d[\"\(p.name)\"] = self.\(p.name).cachebayJSON")
        }
        lines.append("return d")
        let body = lines.joined(separator: "\n")
        return """
        @_spi(Cachebay) public func __dataDict() -> [String: Cachebay.JSONValue] {
        \(raw: body)
        }
        """
    }

    /// True when the struct declares `Codable`/`Decodable`/`Encodable` — the
    /// opt-in trigger for emitting the `Codable` members.
    static func declaresCodable(_ decl: StructDeclSyntax) -> Bool {
        guard let inherited = decl.inheritanceClause?.inheritedTypes else { return false }
        for t in inherited {
            let name = t.type.trimmedDescription
            if name == "Codable" || name == "Decodable" || name == "Encodable"
                || name.hasSuffix(".Codable") || name.hasSuffix(".Decodable") || name.hasSuffix(".Encodable") {
                return true
            }
        }
        return false
    }

    /// The non-optional element type of a (possibly optional) property type.
    static func unwrappedTypeString(_ p: CachebayProperty) -> String {
        if let opt = p.type.as(OptionalTypeSyntax.self) {
            return opt.wrappedType.trimmedDescription
        }
        var s = p.type.trimmedDescription
        if s.hasSuffix("?") { s.removeLast() }
        return s
    }

    /// Emits `CodingKeys` (cases = property names = wire keys), plus a custom
    /// `init(from:)` / `encode(to:)`. Decode honors `@CachebayDefault`
    /// (`decodeIfPresent ?? default`) and optionals (`decodeIfPresent`); encode
    /// writes every field (optionals as explicit `null`, matching a wire payload).
    static func makeCodable(props: [CachebayProperty], typename: String) -> [DeclSyntax] {
        let keyCases = props.map { "case \($0.name)" }.joined(separator: "\n")
        let codingKeys: DeclSyntax = """
        public enum CodingKeys: String, CodingKey {
        \(raw: keyCases)
        }
        """

        var decodeLines: [String] = ["let container = try decoder.container(keyedBy: CodingKeys.self)"]
        for p in props {
            let t = p.type.trimmedDescription
            if p.name == "__typename" && !typename.isEmpty {
                decodeLines.append("self.\(p.name) = try container.decodeIfPresent(String.self, forKey: .\(p.name)) ?? \"\(typename)\"")
            } else if let d = p.defaultExpr {
                decodeLines.append("self.\(p.name) = try container.decodeIfPresent(\(t).self, forKey: .\(p.name)) ?? \(d.trimmedDescription)")
            } else if p.isOptional {
                decodeLines.append("self.\(p.name) = try container.decodeIfPresent(\(Self.unwrappedTypeString(p)).self, forKey: .\(p.name))")
            } else {
                decodeLines.append("self.\(p.name) = try container.decode(\(t).self, forKey: .\(p.name))")
            }
        }
        let initFrom: DeclSyntax = """
        public init(from decoder: any Decoder) throws {
        \(raw: decodeLines.joined(separator: "\n"))
        }
        """

        var encodeLines: [String] = ["var container = encoder.container(keyedBy: CodingKeys.self)"]
        for p in props {
            encodeLines.append("try container.encode(self.\(p.name), forKey: .\(p.name))")
        }
        let encodeTo: DeclSyntax = """
        public func encode(to encoder: any Encoder) throws {
        \(raw: encodeLines.joined(separator: "\n"))
        }
        """

        return [codingKeys, initFrom, encodeTo]
    }

    /// KeyPath -> GraphQL field-name table for this type's own fields, used by the
    /// KeyPath patch builder (`patch.set(\.title, ...)`). Top-level fields only.
    static func makeFieldNamesMap(props: [CachebayProperty]) -> DeclSyntax {
        // `nonisolated(unsafe)`: an immutable table of literal KeyPaths; AnyKeyPath
        // isn't Sendable, but the value is constructed once and never mutated.
        if props.isEmpty {
            return "nonisolated(unsafe) public static let __cachebayFieldNames: [AnyKeyPath: String] = [:]"
        }
        let entries = props.map { "\\Self.\($0.name): \"\($0.name)\"" }.joined(separator: ", ")
        return "nonisolated(unsafe) public static let __cachebayFieldNames: [AnyKeyPath: String] = [\(raw: entries)]"
    }

    /// `CachebayValue` requirements so nested structs decode uniformly. The
    /// conformance itself is declared on the type (CLI-emitted / hand-written).
    static func makeCachebayValueConformance() -> [DeclSyntax] {
        [
            """
            public init?(cachebayJSON json: Cachebay.JSONValue) {
            guard case .object(let d) = json else { return nil }
            self.init(_dataDict: d)
            }
            """,
            """
            public var cachebayJSON: Cachebay.JSONValue { .object(self.__dataDict()) }
            """,
        ]
    }
}
