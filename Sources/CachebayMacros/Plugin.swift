import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct CachebayMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        CachebayDataMacro.self,
        CachebayDefaultMacro.self,
        CachebayInterfaceMacro.self,
        CachebayUnionMacro.self,
    ]
}
