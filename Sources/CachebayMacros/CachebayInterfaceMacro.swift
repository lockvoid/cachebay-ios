import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

/// `@CachebayInterface` / `@CachebayUnion` — sum-type enum for a GraphQL interface/union.
///
/// Given:
/// ```swift
/// @CachebayInterface
/// enum Element {
///     case video(Video)
///     case audio(Audio)
///     case unknown(Shared)     // fallback; carries interface-level shared fields (§3.1)
///     @CachebayData(typename: "VideoElement") struct Video { ... }
///     @CachebayData(typename: "") struct Shared { let __typename: String; let id: String }
/// }
/// ```
/// emits:
/// - lifted shared accessors (one per `Shared` field) that switch over every variant,
///   including `.unknown` — so `element.id` works with no optional/force-unwrap;
/// - `@_spi(Cachebay) init?(_dataDict:)` that tries each concrete variant's initializer
///   (each self-guards on its own `__typename`) and falls back to `.unknown(Shared)`;
/// - `__dataDict()` and the `CachebayValue` conformance members.
public struct CachebayInterfaceMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try CachebayEnumExpansion.expand(node: node, declaration: declaration, in: context)
    }
}

/// `@CachebayUnion` — identical mechanics; a union's `Shared` simply has only `__typename`.
public struct CachebayUnionMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try CachebayEnumExpansion.expand(node: node, declaration: declaration, in: context)
    }
}

enum CachebayEnumExpansion {
    struct Variant {
        let caseName: String
        let typeName: String
        var isUnknown: Bool { caseName == "unknown" }
    }

    static func expand(
        node: AttributeSyntax,
        declaration: some DeclGroupSyntax,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
            context.diagnose(Diagnostic(node: node, message: CachebayMacroDiagnostic.interfaceOnlyOnEnum))
            return []
        }

        var variants: [Variant] = []
        var nestedStructs: [String: StructDeclSyntax] = [:]
        for member in enumDecl.memberBlock.members {
            if let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) {
                for element in caseDecl.elements {
                    let typeName = element.parameterClause?.parameters.first?.type.trimmedDescription ?? ""
                    variants.append(Variant(caseName: element.name.text, typeName: typeName))
                }
            } else if let structDecl = member.decl.as(StructDeclSyntax.self) {
                nestedStructs[structDecl.name.text] = structDecl
            }
        }

        let unknown = variants.first(where: { $0.isUnknown })
        let sharedProps: [CachebayProperty] = unknown
            .flatMap { nestedStructs[$0.typeName] }
            .map { CachebayDataMacro.storedProperties(of: $0) } ?? []

        var members: [DeclSyntax] = []
        members.append(contentsOf: makeLiftedAccessors(variants: variants, sharedProps: sharedProps))
        members.append(makeDictInit(variants: variants))
        members.append(makeDataDict(variants: variants))
        members.append(contentsOf: makeConformance())
        // KeyPath -> field-name table over the lifted shared accessors. Mirrors
        // `@CachebayData` so an interface-rooted fragment's
        // `Data.__cachebayFieldNames` (emitted for every fragment by the CLI)
        // resolves, and `b.patch(fragment:id:) { $0.set(\.sharedField, …) }`
        // works for the interface's common fields.
        members.append(CachebayDataMacro.makeFieldNamesMap(props: sharedProps))
        return members
    }

    /// One computed accessor per shared field, switching over every variant.
    static func makeLiftedAccessors(variants: [Variant], sharedProps: [CachebayProperty]) -> [DeclSyntax] {
        sharedProps.map { p in
            let arms = variants.map { v in
                "case .\(v.caseName)(let v): return v.\(p.name)"
            }.joined(separator: "\n")
            return """
            public var \(raw: p.name): \(raw: p.type.trimmedDescription) {
            switch self {
            \(raw: arms)
            }
            }
            """
        }
    }

    /// Dispatch by `__typename`: a known typename selects its variant (a record miss
    /// if that variant fails to decode — §7), an unrecognized typename falls back to
    /// `.unknown(Shared)` (§3.1, schema evolution / un-narrowed variants).
    static func makeDictInit(variants: [Variant]) -> DeclSyntax {
        var lines: [String] = ["let __typename = dict[\"__typename\"]?.string"]
        for v in variants where !v.isUnknown {
            lines.append("if __typename == \(v.typeName).__cachebayTypename {")
            lines.append("guard let v = \(v.typeName)(_dataDict: dict) else { return nil }")
            lines.append("self = .\(v.caseName)(v); return")
            lines.append("}")
        }
        if let unknown = variants.first(where: { $0.isUnknown }) {
            lines.append("guard let v = \(unknown.typeName)(_dataDict: dict) else { return nil }")
            lines.append("self = .\(unknown.caseName)(v)")
        } else {
            lines.append("return nil")
        }
        let body = lines.joined(separator: "\n")
        return """
        @_spi(Cachebay) public init?(_dataDict dict: [String: Cachebay.JSONValue]) {
        \(raw: body)
        }
        """
    }

    static func makeDataDict(variants: [Variant]) -> DeclSyntax {
        let arms = variants.map { v in
            "case .\(v.caseName)(let v): return v.__dataDict()"
        }.joined(separator: "\n")
        return """
        @_spi(Cachebay) public func __dataDict() -> [String: Cachebay.JSONValue] {
        switch self {
        \(raw: arms)
        }
        }
        """
    }

    static func makeConformance() -> [DeclSyntax] {
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
