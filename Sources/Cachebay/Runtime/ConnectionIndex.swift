import Foundation

/// Per-canonical-connection auxiliary indices stored as sibling graph records:
///
///   - `<canonical>::cursorIndex` — cursor → edge position (array index).
///     Maintained by `Canonical`.
///   - `<canonical>::nodeIndex`   — canonical node key → edge record key.
///     Maintained by both `Canonical` (merge path) and `Optimistic`
///     (addNode/removeNode). Turns the dedup-by-entity and remove-by-entity
///     paths from O(N) to O(1) regardless of connection size.
enum ConnectionIndex {
    @inlinable
    static func nodeIndexKey(_ canonicalKey: CacheKey) -> CacheKey {
        "\(canonicalKey)::nodeIndex"
    }

    /// Look up the edge record key for a given entity in this connection, or
    /// nil if the entity isn't part of this connection's edges.
    @inlinable
    static func edgeKey(graph: Graph, canonicalKey: CacheKey, nodeKey: CacheKey) -> CacheKey? {
        graph.getField(nodeIndexKey(canonicalKey), nodeKey)?.string
    }

    /// Upsert a (nodeKey → edgeKey) entry. Safe to call with an already-present
    /// nodeKey; the value is replaced.
    @inlinable
    static func insert(graph: Graph, canonicalKey: CacheKey, nodeKey: CacheKey, edgeKey: CacheKey) {
        graph.putRecord(nodeIndexKey(canonicalKey), [nodeKey: .string(edgeKey)])
    }

    /// Remove a single (nodeKey → edgeKey) entry. Relies on `putRecord`'s
    /// `.undefined`-as-delete semantics to drop the field without walking the
    /// rest of the record.
    @inlinable
    static func remove(graph: Graph, canonicalKey: CacheKey, nodeKey: CacheKey) {
        graph.putRecord(nodeIndexKey(canonicalKey), [nodeKey: .undefined])
    }

    /// Replace the entire node index with a freshly-computed map. Used after
    /// `Canonical` rewrites the whole edge list (page-mode, or infinite-mode
    /// with reordering).
    @inlinable
    static func rebuild(graph: Graph, canonicalKey: CacheKey, edgeRefs: [CacheKey]) {
        var idx: [String: JSONValue] = [:]
        idx.reserveCapacity(edgeRefs.count)
        for ek in edgeRefs {
            if let edge = graph.getRecord(ek), let nodeRef = edge[CachebayConstants.connectionNodeField]?.ref {
                idx[nodeRef] = .string(ek)
            }
        }
        graph.replaceRecord(nodeIndexKey(canonicalKey), idx)
    }

    /// Clear the node index entirely. Called on connection reset / evict.
    @inlinable
    static func clear(graph: Graph, canonicalKey: CacheKey) {
        graph.replaceRecord(nodeIndexKey(canonicalKey), [:])
    }
}
