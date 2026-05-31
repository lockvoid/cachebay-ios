// Public macro declarations for the v1.0 typed-structs codegen.
//
// Implementations live in the `CachebayMacros` compiler plugin. Generated
// code references the fully-qualified `Cachebay.JSONValue`, so this declaration
// module deliberately has no runtime dependency on `Cachebay` (no dependency
// cycle). Consumers import these via `import Cachebay` (re-exported) or directly.

/// Generates the typed-struct surface for a Cachebay data type:
/// - a public memberwise `init` with per-field defaults,
/// - an eager `@_spi(Cachebay) init?(_dataDict:)` that decodes from a cache record,
/// - a `@_spi(Cachebay) __dataDict()` round-trip bridge back to `[String: JSONValue]`.
///
/// `typename` is the GraphQL `__typename` this struct represents (e.g. `"VideoElement"`).
/// Pass `""` for an interface's shared-fields struct, whose `__typename` varies per record.
///
/// The macro is `@attached(member)` only — conformances (`Sendable`, `Hashable`,
/// `Equatable`, `Codable`, `Identifiable`) are declared on the type itself and
/// compiler-synthesized, so the type may be nested inside an enum or a namespace.
@attached(member, names: arbitrary)
public macro CachebayData(typename: String) =
    #externalMacro(module: "CachebayMacros", type: "CachebayDataMacro")

/// Per-field construction default, read by `@CachebayData`. A no-op marker on its own.
@attached(peer)
public macro CachebayDefault<T>(_ value: T) =
    #externalMacro(module: "CachebayMacros", type: "CachebayDefaultMacro")

/// Generates a sum-type interface enum from `case`s plus nested `@CachebayData` structs:
/// lifted shared accessors (working on every variant incl. `.unknown(Shared)`), and an
/// eager `@_spi(Cachebay) init?(_dataDict:)` that dispatches to the matching variant.
@attached(member, names: arbitrary)
public macro CachebayInterface() =
    #externalMacro(module: "CachebayMacros", type: "CachebayInterfaceMacro")

/// Like `@CachebayInterface`, but for unions: the only lifted shared field is `__typename`.
@attached(member, names: arbitrary)
public macro CachebayUnion() =
    #externalMacro(module: "CachebayMacros", type: "CachebayUnionMacro")
