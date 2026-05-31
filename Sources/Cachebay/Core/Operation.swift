import Foundation

/// Wire-shape marker for generated `Variables` structs. Surfaces the
/// `__cachebay` accessor the codegen emits as the canonical shape of an
/// operation's variables (`[String: JSONValue]`), so the typed runtime
/// can forward variables without each caller flattening them by hand.
///
/// This is the one piece of the original dict-wrapper protocol family that
/// the v1.0 typed surface keeps: `CachebayOperation.Variables` and
/// `CachebayFragment` both constrain to it. The dict-wrapper `Operation` /
/// `OperationData` / `Fragment` / `ConnectionEdge` protocols were removed —
/// typed operations decode eagerly into real structs via `CachebayValue`
/// (see `CachebayOperation` / `CachebayFragment` / the `@CachebayData`
/// macro), so there is no `__data` dict to wrap and no `.as()` /
/// `.nodes(as:)` projection seam to paper over.
public protocol OperationVariables: Sendable {
    var __cachebay: [String: JSONValue] { get }
}

/// Convenience for variable-less operations. Callers pass `EmptyVariables()`
/// (or `.init()`) anywhere a `Variables` argument is required.
public struct EmptyVariables: OperationVariables {
    public init() {}
    public var __cachebay: [String: JSONValue] { [:] }
}
