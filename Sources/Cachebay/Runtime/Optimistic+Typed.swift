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
