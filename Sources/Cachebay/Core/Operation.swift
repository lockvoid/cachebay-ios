import Foundation

/// Describes a generated GraphQL operation (query, mutation, subscription,
/// or fragment) — the entry point the typed `CachebayClient` overloads
/// dispatch on.
///
/// `cachebay-cli` emits one struct per operation that conforms to this
/// protocol along with `OperationData` / `OperationVariables` on the
/// nested `Data` / `Variables` types it generates. Consumers then call
/// e.g. `client.executeMutation(UpdateClip.self, variables: .init(...))`
/// and get back `OperationResult<UpdateClip.Data>` — the runtime owns the
/// `JSONValue` ↔ typed-struct unwrap, the codegen knows the shape, and
/// the call site reads as Swift instead of dictionary-prodding.
public protocol Operation: Sendable {
    /// Variables struct — must be encodable to a Cachebay JSON dict.
    associatedtype Variables: OperationVariables
    /// Typed response shape — must be constructible from a JSON dict.
    associatedtype Data: OperationData
    /// GraphQL source string sent to the network. Includes the operation
    /// itself and every fragment it transitively references.
    static var networkQuery: String { get }
    /// Pre-compiled `CachePlan` (or fall-back source). The typed runtime
    /// overloads pass this to `planner.getPlan` so production builds skip
    /// the GraphQL parse on every call.
    static var document: QueryDocument { get }
}

/// Marker protocol the codegen attaches to every generated typed selection
/// struct (operation `Data`, nested `Data.Foo`, polymorphic `AsX`, …). The
/// requirements are the two members the codegen already emits:
/// `init(__data:)` so the runtime can lift a JSON dict into the typed
/// shape, and `var __data` so the runtime — and codegen-emitted helpers
/// like connection `prepend(node:)` — can read/write the underlying
/// dict without a `Mirror` round-trip.
public protocol OperationData: Sendable {
    var __data: [String: JSONValue] { get }
    init(__data: [String: JSONValue])
}

/// Marker protocol for generated `Variables` structs. Surfaces the
/// `__cachebay` accessor the codegen emits as the canonical wire-shape
/// of variables (`[String: JSONValue]`), so the typed runtime overloads
/// can forward variables without each caller flattening them by hand.
public protocol OperationVariables: Sendable {
    var __cachebay: [String: JSONValue] { get }
}

/// Convenience for variable-less operations. The codegen still emits a
/// `Variables` struct in some cases (just empty); for operations that
/// don't have variables at all, callers can pass `EmptyVariables()`.
public struct EmptyVariables: OperationVariables {
    public init() {}
    public var __cachebay: [String: JSONValue] { [:] }
}

public extension OperationData {
    /// Reinterpret this typed selection struct as a fragment's `Data`
    /// shape, sharing the underlying `__data`. Use this when a query
    /// or subscription's typed nested struct shares its selection set
    /// with a fragment (`...PostFields` spread):
    ///
    /// ```swift
    /// let msg = event.data?.projectMessageCreated?.as(ProjectMessageFields.self)
    /// ```
    ///
    /// Both ends MUST select the same fields — the runtime trusts the
    /// caller and just lifts the dict into `F.Data`. Mismatched shapes
    /// would surface as missing/wrong-typed accessors at read time, not
    /// as a compile error here.
    func `as`<F: Fragment>(_ fragment: F.Type) -> F.Data {
        F.Data(__data: __data)
    }
}

/// Mirror of `Operation` for GraphQL fragment definitions. Fragments
/// aren't executed against the network; they describe a sub-shape of
/// some entity that can be read/written/watched against the cache by
/// the entity's id (e.g. `client.readFragment(fragment: ProjectFields.self,
/// id: "Project:42")`). `cachebay-cli` emits one struct per fragment
/// conforming to this protocol; consumers get the same typed ergonomics
/// the operation overloads provide for queries/mutations/subscriptions.
public protocol Fragment: Sendable {
    associatedtype Variables: OperationVariables
    associatedtype Data: OperationData
    /// Source string for the fragment definition. Passed to the
    /// underlying JSON-shaped runtime when the typed overload needs
    /// to compile the document on-demand.
    static var networkQuery: String { get }
    /// Pre-compiled fragment plan. Operations + fragments share the
    /// `QueryDocument` shape so the planner can hand the same hashed
    /// plan back regardless of which protocol came in.
    static var document: QueryDocument { get }
    /// Fragment definition name in the source document — used by the
    /// runtime to disambiguate when the source declares more than one
    /// fragment in the same string.
    static var fragmentName: String { get }
    /// The GraphQL type the fragment is declared on (`fragment X on Y { … }`
    /// → `"Y"`). Typed APIs use this to build the canonical cache key
    /// from a bare entity id (`"\(onTypename):\(id)"`), so callers don't
    /// have to repeat the typename at every call site.
    static var onTypename: String { get }
}
