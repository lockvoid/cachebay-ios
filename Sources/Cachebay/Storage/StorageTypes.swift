import Foundation

/// Debug snapshot returned by `StorageAdapter.inspect()`.
public struct StorageInspection: Sendable, Hashable {
    public let recordCount: Int
    public let journalCount: Int
    public let lastSeenSeq: Int64
    public let instanceID: String

    public init(recordCount: Int, journalCount: Int, lastSeenSeq: Int64, instanceID: String) {
        self.recordCount = recordCount
        self.journalCount = journalCount
        self.lastSeenSeq = lastSeenSeq
        self.instanceID = instanceID
    }
}

/// Context passed to a `StorageAdapterFactory` when a `CachebayClient` spins up
/// a storage adapter. The callbacks let a storage adapter push remote changes
/// back into the graph — useful for multi-process / multi-WebView scenarios
/// on iOS (e.g. Capacitor), but optional for single-process apps.
public struct StorageContext: Sendable {
    public let instanceID: String
    public let onUpdate: @Sendable (_ records: [(CacheKey, [String: JSONValue])]) -> Void
    public let onRemove: @Sendable (_ ids: [CacheKey]) -> Void
    public let onEvictAll: (@Sendable () -> Void)?

    public init(
        instanceID: String,
        onUpdate: @escaping @Sendable (_ records: [(CacheKey, [String: JSONValue])]) -> Void,
        onRemove: @escaping @Sendable (_ ids: [CacheKey]) -> Void,
        onEvictAll: (@Sendable () -> Void)? = nil
    ) {
        self.instanceID = instanceID
        self.onUpdate = onUpdate
        self.onRemove = onRemove
        self.onEvictAll = onEvictAll
    }
}

/// The storage adapter contract. Every cache write flows through `put`/`remove`;
/// `load` is called once at init to warm the in-memory graph; the rest is for
/// debugging and explicit sync points.
///
/// Writes are fire-and-forget by design — the in-memory graph is the source of
/// truth for readers, and the adapter drains its own write queue. Call
/// `flush()` before you need a persistent write guarantee (e.g. before app
/// backgrounding in tight scenarios).
public protocol StorageAdapter: Sendable {
    /// Persist changed record snapshots.
    func put(_ records: [(CacheKey, [String: JSONValue])])

    /// Remove records by id.
    func remove(_ ids: [CacheKey])

    /// Load all persisted records at init (async).
    func load() async throws -> [(CacheKey, [String: JSONValue])]

    /// Synchronous bulk load on the calling thread. Used by
    /// `CachebayClient.warmup()` to hydrate the in-memory graph
    /// without crossing a Task boundary, so the caller knows the
    /// graph is fully populated by the time `warmup()` returns.
    /// Implementations should serialize against any pending writes
    /// (i.e. dispatch on the storage's own worker queue *synchronously*
    /// rather than concurrently) so the load reflects every committed
    /// write up to the call site.
    func loadSync() throws -> [(CacheKey, [String: JSONValue])]

    /// Drain all pending writes.
    func flush() async throws

    /// Manually evict journal entries older than the configured max-age.
    func evictJournal() async throws

    /// Clear all persisted records and journal entries, plus signal other
    /// instances via the journal.
    func evictAll() async throws

    /// Debug inspection.
    func inspect() async throws -> StorageInspection

    /// Cleanup: close connections, stop any polling.
    func dispose()
}

/// Factory that creates a `StorageAdapter` bound to a specific `CachebayClient`
/// via the `StorageContext`.
public typealias StorageAdapterFactory = @Sendable (_ ctx: StorageContext) -> StorageAdapter
