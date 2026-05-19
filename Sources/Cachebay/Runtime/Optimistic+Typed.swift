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
        //
        // Go through `patchFragment` so the runtime walks the fragment
        // plan + draft in tandem and translates inline-container /
        // entity / list values into graph-shape (`.ref` / `.refList` +
        // synthetic or canonical sub-records). The raw JSON
        // `patch(_ target:_:mode:)` path is plan-agnostic and would
        // shove an `.object` straight into a selection-set field —
        // which the strict materializer rejects.
        patchFragment(
            document: F.document,
            fragmentName: F.fragmentName,
            rootId: "\(canonicalTypename(F.onTypename)):\(id)",
            variables: [:],
            data: draft.__data,
            mode: mode
        )
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
    /// Typed link — pass a typed `OperationData` payload (e.g. a server
    /// response from `result.data?.createPost?.post`); Cachebay extracts
    /// `__typename` + `id` and forwards an `EntityRef` to the JSON-shaped
    /// `linkNode`. The entity record is NOT written by this call —
    /// entity scalars are owned by `documents.normalize` (already wrote
    /// when the response was processed) or by an explicit
    /// `b.writeFragment(...)`. Same idempotency guarantees as the raw
    /// path: re-linking refreshes edge meta in place without reordering.
    ///
    /// ```swift
    /// b.connection(ConnectionSelector(key: "posts"))
    ///   .linkNode(node: created, options: .init(position: .start))
    /// ```
    func linkNode<N: OperationData>(node: N, options: LinkNodeOptions = .init()) {
        linkNode(.object(node.__data), options: options)
    }

    /// Typed link keyed by bare id — fragment supplies the typename,
    /// canonicalised through the interfaces map so a variant fragment
    /// targets the right canonical entity record. Use this in
    /// optimistic-create flows after `writeFragment` has bootstrapped
    /// the entity:
    ///
    /// ```swift
    /// let tempId = UUID().uuidString
    /// b.writeFragment(fragment: PostFields.self, id: tempId, data: draft)
    /// b.connection(key: key)
    ///   .linkNode(fragment: PostFields.self, id: tempId,
    ///             options: .init(position: .start))
    /// ```
    func linkNode<F: Fragment, ID: LosslessStringConvertible>(
        fragment: F.Type,
        id: ID,
        options: LinkNodeOptions = .init()
    ) {
        linkNode(.key("\(canonicalTypename(F.onTypename)):\(id)"), options: options)
    }

    /// Typed unlink keyed by bare id — fragment supplies the typename,
    /// canonicalised through the interfaces map so a variant fragment
    /// targets the right canonical entity record.
    func unlinkNode<F: Fragment, ID: LosslessStringConvertible>(
        fragment: F.Type,
        id: ID
    ) {
        unlinkNode(.key("\(canonicalTypename(F.onTypename)):\(id)"))
    }
}
