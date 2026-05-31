import SwiftSyntax
import SwiftSyntaxMacros

/// A marker macro: it emits nothing. Its value is read off the property's
/// attribute by `@CachebayData` when synthesizing the memberwise init and the
/// dict initializer.
public struct CachebayDefaultMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}
