import Foundation

/// Context passed to an `EntityReducer` at the moment of an entity write.
/// Carries both the currently-stored record (`prev`, `nil` if the entity is
/// new) and the merge candidate (`next`, the result of the default
/// field-wise merge that would happen if no reducer were registered).
///
/// Reducers return one of:
/// - `ctx.next` — accept the default merge (no-op reducer)
/// - `ctx.prev ?? ctx.next` — reject the incoming write (skip)
/// - any other dict — install a custom merged record
///
/// When the returned dict is equal to `prev`, the differ produces zero
/// field changes and the watcher fanout naturally short-circuits — no
/// emit fires for the rejected write.
public struct EntityMergeContext: Sendable {
    /// The entity's identity string (the part after the colon in the
    /// cache key — e.g. `"1"` for `"Chat:1"`). The typename is implicit
    /// from the dictionary key the reducer was registered under.
    public let id: String
    /// The record as currently stored in the cache. `nil` if no record
    /// exists yet (new entity).
    public let prev: [String: JSONValue]?
    /// The merge candidate — what the cache *would* store if no reducer
    /// were registered. This is the field-wise merge of `prev` and the
    /// incoming wire patch (incoming fields layered over prev). Includes
    /// fields the wire payload didn't carry, so reducers can read
    /// previously-stored fields like `updatedAt` without worrying about
    /// the payload being partial.
    public let next: [String: JSONValue]

    public init(id: String, prev: [String: JSONValue]?, next: [String: JSONValue]) {
        self.id = id
        self.prev = prev
        self.next = next
    }
}

/// Per-type reducer fired at every wire-side entity write (query
/// responses, mutation responses, subscription frames, fragment writes).
/// Optimistic writes (`modifyOptimistic`, layer apply/commit/replay) do
/// **not** invoke reducers — they take a separate path that bypasses the
/// normalize entity hook.
///
/// The reducer receives both sides of the write and returns the dict to
/// store. See `EntityMergeContext`.
///
/// ## Performance contract
///
/// - When no reducers are registered, the entire mechanism compiles to a
///   single empty-dict check per entity write. No closure dispatch, no
///   getRecord snapshot, no allocations.
/// - When a reducer is registered for type T, every entity write for T
///   pays: two `getRecord` calls (prev snapshot + next snapshot) and one
///   closure invocation. Writes for *other* types pay only the dict
///   lookup miss.
public typealias EntityReducer = @Sendable (EntityMergeContext) -> [String: JSONValue]
