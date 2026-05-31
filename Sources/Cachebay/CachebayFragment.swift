import Foundation

/// A v1.0 typed-struct GraphQL fragment — the write-unit for the KeyPath patch
/// builder. Like `CachebayOperation`, its `Data` is a real struct decoded via
/// `CachebayValue` (not a dict wrapper).
///
/// The `@CachebayData` macro emits `Data.__cachebayFieldNames` (a KeyPath ->
/// GraphQL field-name table for the type's own top-level fields), which the patch
/// builder uses to turn `set(\.title, …)` into a `[String: JSONValue]` patch.
public protocol CachebayFragment: Sendable {
    associatedtype Data: CachebayValue & Sendable
    static var fragmentName: String { get }
    static var onTypename: String { get }
    static var document: QueryDocument { get }
    /// KeyPath -> field-name table for the fragment's own top-level fields.
    static var __cachebayFieldNames: [AnyKeyPath: String] { get }
}

/// A KeyPath-driven patch accumulator. `set(\.field, value)` records a single
/// field write; the result is the same `[String: JSONValue]` patch the dict API
/// builds — type-safe at the call site, scoped to the fragment's own fields.
///
/// Deep paths (`\.author.name`) are intentionally unsupported: patch the nested
/// entity by its own fragment + id instead. The cache write-target stays a single
/// record by id, on a single field — matching the entity-keyed cache structure.
public struct CachebayPatch<F: CachebayFragment> {
    public private(set) var fields: [String: JSONValue] = [:]
    public init() {}

    /// Record a single top-level field write. `keyPath` is used only as a field
    /// *identifier* (read-only); the value is encoded via `CachebayValue`.
    public mutating func set<V: CachebayValue>(_ keyPath: KeyPath<F.Data, V>, _ value: V) {
        guard let name = F.__cachebayFieldNames[keyPath] else {
            assertionFailure(
                "\(keyPath) is not one of \(F.self)'s top-level fields — only a fragment's own fields are patchable (patch nested entities via their own fragment)."
            )
            return
        }
        fields[name] = value.cachebayJSON
    }
}

public extension OptimisticBuilder {
    /// Typed KeyPath patch:
    /// ```swift
    /// b.patch(fragment: CookFields.self, id: "c1") { patch in
    ///     patch.set(\.title, "Renamed")
    ///     patch.set(\.likes, 42)
    /// }
    /// ```
    /// Produces exactly the `[String: JSONValue]` patch the dict API produces and
    /// routes it through `patchFragment` — identical layer/merge/revert semantics.
    func patch<F: CachebayFragment, ID: LosslessStringConvertible>(
        fragment: F.Type,
        id: ID,
        mode: EntityPatchMode = .merge,
        _ build: (inout CachebayPatch<F>) -> Void
    ) {
        var patch = CachebayPatch<F>()
        build(&patch)
        if patch.fields.isEmpty { return }
        patchFragment(
            document: F.document,
            fragmentName: F.fragmentName,
            rootId: "\(canonicalTypename(F.onTypename)):\(id)",
            variables: [:],
            data: patch.fields,
            mode: mode
        )
    }
}
