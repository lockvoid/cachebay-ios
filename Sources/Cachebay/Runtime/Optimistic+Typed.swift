import Foundation

/// Typed overloads layered on top of the JSON-shaped `OptimisticBuilder` /
/// `ConnectionAPI` surface. Consumers should not be writing `[String:
/// JSONValue]` literals or `__typename` strings inside `modifyOptimistic`
/// closures — the codegen has the types, so use them.
///
/// All overloads are protocol extensions: they delegate to the JSON-shaped
/// methods on `OptimisticBuilder` / `ConnectionAPI`, so behaviour (layer
/// recording, dedup, two-cycle commit semantics) is identical to the
/// JSON path.

public extension OptimisticBuilder {
    /// Typed entity patch via a closure-builder. The cache key is built
    /// from the fragment's `onTypename` + the bare `id` argument
    /// (`"\(F.onTypename):\(id)"`); callers don't repeat the typename.
    ///
    /// The builder yields an `inout F.Data` draft seeded with an empty
    /// `__data` dict; only fields the closure touches end up in the
    /// patch — accessor setters write through to the underlying dict,
    /// so a one-line edit produces a single-field patch.
    ///
    /// ```swift
    /// b.patch(fragment: PostFields.self, id: "p1") { draft in
    ///     draft.title = "renamed"
    /// }
    /// ```
    ///
    /// `mode: .merge` (default) shallow-merges the touched fields into the
    /// existing snapshot; `.replace` writes exactly the touched fields and
    /// drops everything else.
    func patch<F: Fragment, ID: LosslessStringConvertible>(
        fragment: F.Type,
        id: ID,
        mode: EntityPatchMode = .merge,
        _ build: (inout F.Data) -> Void
    ) {
        var draft = F.Data(__data: [:])
        build(&draft)
        if draft.__data.isEmpty { return }
        // Route via the canonical interface namespace when `F.onTypename`
        // is a registered impl (e.g. `SpeechClip` → `TimelineClip`),
        // otherwise use it as-is. Keeps a typed patch on a variant
        // fragment landing on the same cache record as patches on the
        // interface fragment.
        patch(.key("\(canonicalTypename(F.onTypename)):\(id)"), draft.__data, mode: mode)
    }

    /// Typed entity delete keyed by bare id — fragment supplies the
    /// typename. Wraps `delete(_ target: EntityRef)`.
    func delete<F: Fragment, ID: LosslessStringConvertible>(
        fragment: F.Type,
        id: ID
    ) {
        delete(.key("\(canonicalTypename(F.onTypename)):\(id)"))
    }

    /// Typed plan-aware optimistic write. Pass the fragment, the bare
    /// entity id, optional variables, and a typed `F.Data` containing
    /// the entity tree to normalize. Nested entity-shaped fields
    /// (single + list) become their own cache records linked by
    /// `.ref` / `.refList`. The cache key is built as
    /// `"\(canonicalTypename(F.onTypename)):\(id)"`.
    ///
    /// ```swift
    /// b.writeFragment(fragment: ProjectMessageFields.self, id: userId,
    ///                 data: messageData)
    /// ```
    func writeFragment<F: Fragment, ID: LosslessStringConvertible>(
        fragment: F.Type,
        id: ID,
        variables: F.Variables,
        data: F.Data
    ) {
        let cacheKey: CacheKey = "\(canonicalTypename(F.onTypename)):\(id)"
        writeFragment(
            document: F.document,
            fragmentName: F.fragmentName,
            rootId: cacheKey,
            variables: variables.__cachebay,
            data: data.__data
        )
    }

    /// Variable-less convenience overload — most fragments don't take
    /// variables, so callers shouldn't have to write `.init()`.
    func writeFragment<F: Fragment, ID: LosslessStringConvertible>(
        fragment: F.Type,
        id: ID,
        data: F.Data
    ) where F.Variables == EmptyVariables {
        writeFragment(fragment: fragment, id: id, variables: .init(), data: data)
    }
}

public extension ConnectionAPI {
    /// Typed connection add — pass a typed `OperationData` (e.g. a server
    /// payload from `result.data?.createPost?.post`) and Cachebay forwards
    /// the underlying `__data` into the JSON-shaped `addNode`. Same
    /// idempotency guarantees: re-adding the same entity refreshes edge
    /// meta in place without reordering.
    ///
    /// ```swift
    /// b.connection(ConnectionSelector(key: "posts"))
    ///  .addNode(node: created, options: .init(position: .start))
    /// ```
    func addNode<N: OperationData>(node: N, options: AddNodeOptions) {
        addNode(node.__data, options: options)
    }

    /// Plan-aware typed add — pass the typed entity AND the fragment
    /// that governs its shape. The fragment plan is used to (a)
    /// initialize nested `@connection` canonicals as empty (or from
    /// inline `edges`/`pageInfo` in the node data) and (b) strip
    /// selection-set fields from the entity-record patch so existing
    /// ref/refList links stay intact.
    ///
    /// Use this when adding an entity returned from a mutation
    /// response (e.g. `result.data?.createProject`) to a connection
    /// that watches the same entity through a fragment with
    /// connection-shaped subfields:
    ///
    /// ```swift
    /// b.connection(key: key)
    ///  .addNode(node: created, fragment: ProjectFields.self,
    ///           options: .init(position: .start))
    /// ```
    ///
    /// Mirrors cachebay-web's `addNode(node, { fragment, fragmentName, variables })`
    /// (`optimistic.ts:952`).
    func addNode<N: OperationData, F: Fragment>(
        node: N,
        fragment: F.Type,
        variables: [String: JSONValue] = [:],
        options: AddNodeOptions = AddNodeOptions()
    ) {
        var opts = options
        opts.fragmentDocument = F.document
        opts.fragmentName = F.fragmentName
        opts.fragmentVariables = variables
        addNode(node.__data, options: opts)
    }

    /// Plan-aware typed add for a fragment-shaped entity. Same as the
    /// `OperationData` overload but takes `F.Data` directly.
    func addNode<F: Fragment>(
        node: F.Data,
        fragment: F.Type,
        variables: [String: JSONValue] = [:],
        options: AddNodeOptions = AddNodeOptions()
    ) {
        var opts = options
        opts.fragmentDocument = F.document
        opts.fragmentName = F.fragmentName
        opts.fragmentVariables = variables
        addNode(node.__data, options: opts)
    }

    /// Typed connection add via closure-builder — for optimistic inserts
    /// where you don't have server data yet. Builds a minimal node draft
    /// out of the fragment shape; only fields the closure touches land in
    /// the synthesised entity record. Cachebay seeds the draft's
    /// `__typename` from the fragment's `onTypename` so callers don't
    /// have to remember to set it (and so the entity normalises into
    /// the right cache record by id).
    ///
    /// ```swift
    /// b.connection(ConnectionSelector(key: "posts"))
    ///  .addNode(fragment: PostFields.self, options: .init(position: .start)) { draft in
    ///      draft.id = "tmp:\(UUID())"
    ///      draft.title = "Drafting…"
    ///  }
    /// ```
    func addNode<F: Fragment>(
        fragment: F.Type,
        options: AddNodeOptions,
        _ build: (inout F.Data) -> Void
    ) {
        var draft = F.Data(__data: ["__typename": .string(F.onTypename)])
        build(&draft)
        // Skip if the closure didn't write anything beyond the seeded
        // `__typename` — an empty optimistic node has no value.
        guard draft.__data.count > 1 else { return }
        addNode(draft.__data, options: options)
    }

    /// Typed connection remove keyed by bare id — fragment supplies the
    /// typename, canonicalised through the interfaces map so a variant
    /// fragment targets the right canonical entity record.
    func removeNode<F: Fragment, ID: LosslessStringConvertible>(
        fragment: F.Type,
        id: ID
    ) {
        removeNode(.key("\(canonicalTypename(F.onTypename)):\(id)"))
    }
}
