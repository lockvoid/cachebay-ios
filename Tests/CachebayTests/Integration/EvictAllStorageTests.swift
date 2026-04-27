import XCTest
@testable import Cachebay

/// `CachebayClient.evictAll` must clear persistent storage too.
///
/// **Bug shape (web parity).** `cachebay-web`'s `evictAll` calls
/// `storageAdapter.evictAll()` BEFORE the in-memory clear / refetch loop
/// (see `client.ts`: `storageAdapter.evictAll() → evictInMemoryAndRefetch()`).
/// The iOS port previously skipped the storage clear entirely — only
/// the in-memory graph was wiped. On next launch, `storage.load()`
/// re-hydrates the same records that were "evicted" and they reappear,
/// silently undoing the eviction.
final class EvictAllStorageTests: XCTestCase {

    /// Records every call into the storage adapter so the test can
    /// assert exactly which lifecycle hooks fired.
    private final class RecordingStorage: StorageAdapter, @unchecked Sendable {
        let lock = NSLock()
        private(set) var evictAllCallCount = 0
        private(set) var puts: [(CacheKey, [String: JSONValue])] = []
        private(set) var removes: [CacheKey] = []
        private(set) var flushed = false
        private(set) var disposed = false

        func put(_ records: [(CacheKey, [String: JSONValue])]) {
            lock.lock(); defer { lock.unlock() }
            puts.append(contentsOf: records)
        }
        func remove(_ ids: [CacheKey]) {
            lock.lock(); defer { lock.unlock() }
            removes.append(contentsOf: ids)
        }
        func load() async throws -> [(CacheKey, [String: JSONValue])] { [] }
        func flush() async throws { setFlushed() }
        func evictJournal() async throws {}
        func inspect() async throws -> StorageInspection {
            StorageInspection(recordCount: 0, journalCount: 0, lastSeenSeq: 0, instanceID: "test")
        }
        func dispose() { setDisposed() }
        func evictAll() async throws { incrementEvictAll() }

        // Sync helpers — `NSLock` isn't usable inside `async` contexts
        // under strict concurrency, so we hop through these.
        private func setFlushed() {
            lock.lock(); defer { lock.unlock() }
            flushed = true
        }
        private func setDisposed() {
            lock.lock(); defer { lock.unlock() }
            disposed = true
        }
        private func incrementEvictAll() {
            lock.lock(); defer { lock.unlock() }
            evictAllCallCount += 1
        }
    }

    func test_evictAll_clearsPersistentStorage() async throws {
        let recorder = RecordingStorage()
        let factory: StorageAdapterFactory = { _ in recorder }

        let client = CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0,
            storage: factory
        ))

        // Pre-condition: storage hasn't been evicted yet.
        XCTAssertEqual(recorder.evictAllCallCount, 0)

        await client.evictAll()

        // The fix: `evictAll` must invoke `storage.evictAll()`. Without
        // it, evicted records resurrect from SQLite on next launch.
        XCTAssertEqual(
            recorder.evictAllCallCount, 1,
            "CachebayClient.evictAll must call storage.evictAll() so persistent records don't resurrect on next launch (matches cachebay-web's evictInMemoryAndRefetch flow)."
        )
    }
}
