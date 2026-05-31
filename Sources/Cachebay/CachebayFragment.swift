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

public extension CachebayClient {
    /// Synchronous typed fragment read from the cache, keyed by bare entity id.
    /// `nil` on miss or if a required field fails to decode (§7).
    func readFragment<F: CachebayFragment, ID: LosslessStringConvertible>(
        fragment frag: F.Type,
        id: ID
    ) -> F.Data? {
        let cacheKey = "\(graph.canonicalTypename(F.onTypename)):\(id)"
        guard let plan = try? planner.getPlan(F.document, fragmentName: F.fragmentName) else { return nil }
        guard let raw = fragments.readFragment(plan: plan, rootId: cacheKey, variables: [:]) else { return nil }
        return F.Data(cachebayJSON: raw)
    }

    /// Subscribe to a typed fragment view of an entity, keyed by bare id. Fires
    /// `onData` with a typed `F.Data` whenever the entity's relevant fields change.
    @discardableResult
    func watchFragment<F: CachebayFragment, ID: LosslessStringConvertible>(
        fragment frag: F.Type,
        id: ID,
        immediate: Bool = true,
        onData: @escaping @Sendable (F.Data) -> Void,
        onError: (@Sendable (CombinedError) -> Void)? = nil
    ) throws -> WatchFragmentHandle {
        let cacheKey = "\(graph.canonicalTypename(F.onTypename)):\(id)"
        let plan = try planner.getPlan(F.document, fragmentName: F.fragmentName)
        return fragments.watchFragment(
            plan: plan,
            document: F.document,
            fragmentName: F.fragmentName,
            rootId: cacheKey,
            options: WatchFragmentOptions(
                variables: [:],
                immediate: immediate,
                onData: { json in if let d = F.Data(cachebayJSON: json) { onData(d) } },
                onError: onError
            )
        )
    }

    /// Typed fragment write keyed by bare entity id. Round-trips `data` through the
    /// JSON-shaped runtime so the writer normalises like a network response.
    func writeFragment<F: CachebayFragment, ID: LosslessStringConvertible>(
        fragment frag: F.Type,
        id: ID,
        data: F.Data
    ) throws {
        let cacheKey = "\(graph.canonicalTypename(F.onTypename)):\(id)"
        let plan = try planner.getPlan(F.document, fragmentName: F.fragmentName)
        fragments.writeFragment(plan: plan, rootId: cacheKey, variables: [:], data: data.cachebayJSON)
        graph.flush()
    }
}

public extension OptimisticBuilder {
    /// Typed plan-aware optimistic write — normalises a typed `F.Data` entity tree
    /// into the optimistic layer (nested entities become their own records).
    func writeFragment<F: CachebayFragment, ID: LosslessStringConvertible>(
        fragment: F.Type,
        id: ID,
        data: F.Data
    ) {
        guard case .object(let dict) = data.cachebayJSON else { return }
        writeFragment(
            document: F.document,
            fragmentName: F.fragmentName,
            rootId: "\(canonicalTypename(F.onTypename)):\(id)",
            variables: [:],
            data: dict
        )
    }

    /// Typed optimistic delete keyed by bare id — fragment supplies the typename.
    func delete<F: CachebayFragment, ID: LosslessStringConvertible>(fragment: F.Type, id: ID) {
        delete(.key("\(canonicalTypename(F.onTypename)):\(id)"))
    }
}

public extension ConnectionAPI {
    /// Typed link — pass a typed node payload (e.g. a server response's node);
    /// Cachebay extracts `__typename` + `id`. The entity record is NOT written here.
    func linkNode<N: CachebayValue>(node: N, options: LinkNodeOptions = .init()) {
        guard case .object(let dict) = node.cachebayJSON else { return }
        linkNode(.object(dict), options: options)
    }

    /// Typed link keyed by bare id — fragment supplies the (canonicalised) typename.
    func linkNode<F: CachebayFragment, ID: LosslessStringConvertible>(
        fragment: F.Type,
        id: ID,
        options: LinkNodeOptions = .init()
    ) {
        linkNode(.key("\(canonicalTypename(F.onTypename)):\(id)"), options: options)
    }

    /// Typed unlink keyed by bare id.
    func unlinkNode<F: CachebayFragment, ID: LosslessStringConvertible>(fragment: F.Type, id: ID) {
        unlinkNode(.key("\(canonicalTypename(F.onTypename)):\(id)"))
    }
}
