import Foundation
import SQLite3

/// A fast SQLite-backed replica of the in-memory graph store. The graph is
/// always the source of truth for reads; this adapter write-behinds every
/// change so cold start restores instantly.
///
/// Performance model:
/// - Every `put`/`remove` call enqueues a work item on a serial queue; control
///   returns to the caller immediately.
/// - The queue drains each batch inside a single `BEGIN IMMEDIATE` transaction.
/// - WAL + `synchronous=NORMAL` keeps fsync cost low while preserving integrity.
/// - Snapshots are JSON-encoded bytes (JSONValue → NSNumber/String/…) — we
///   pay decode cost once at load, never at read.
///
/// Concurrency: the adapter owns the sqlite3 handle on its serial queue and
/// exposes it through async methods where callers need to await a drain.
public final class SQLiteStorage: StorageAdapter, @unchecked Sendable {
    public struct Options: Sendable {
        public var path: String
        public var journalMaxAge: TimeInterval
        public init(path: String, journalMaxAge: TimeInterval = 3600) {
            self.path = path
            self.journalMaxAge = journalMaxAge
        }
    }

    public static func factory(options: Options) -> StorageAdapterFactory {
        return { ctx in
            SQLiteStorage(context: ctx, options: options)
        }
    }

    private let context: StorageContext
    private let options: Options
    private let queue = DispatchQueue(label: "cachebay.sqlite.storage", qos: .userInitiated)
    private let lock = NSLock()

    // Guarded by `lock`.
    private var db: OpaquePointer?
    private var putStmt: OpaquePointer?
    private var deleteStmt: OpaquePointer?
    private var journalStmt: OpaquePointer?
    private var disposed = false
    private var openError: Error?

    // Drain tracking: every enqueued work item increments `enqueued`; when
    // it runs to completion, `drained` is incremented. `flush()` waits until
    // the two match.
    private var enqueued: UInt64 = 0
    private var drained: UInt64 = 0
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    public init(context: StorageContext, options: Options) {
        self.context = context
        self.options = options
        // Open + prepare synchronously so first put/remove is already primed.
        queue.sync { openDatabase() }
    }

    // MARK: - Open / close

    private func openDatabase() {
        lock.lock(); defer { lock.unlock() }
        guard db == nil else { return }

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(options.path, &handle, flags, nil)
        if rc != SQLITE_OK {
            openError = SQLiteError(code: rc, message: "sqlite3_open_v2 failed")
            if let handle { sqlite3_close_v2(handle) }
            return
        }
        db = handle

        // Pragmas: WAL, NORMAL sync, larger cache, foreign_keys off.
        _ = sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        _ = sqlite3_exec(handle, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        _ = sqlite3_exec(handle, "PRAGMA temp_store=MEMORY;", nil, nil, nil)
        _ = sqlite3_exec(handle, "PRAGMA cache_size=-8192;", nil, nil, nil)  // ~8MB

        _ = sqlite3_exec(
            handle,
            """
            CREATE TABLE IF NOT EXISTS records(
                id TEXT PRIMARY KEY NOT NULL,
                snapshot BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS journal(
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                client_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                record_id TEXT,
                ts INTEGER NOT NULL
            );
            """, nil, nil, nil)

        // Prepare reused statements.
        sqlite3_prepare_v2(handle, "INSERT OR REPLACE INTO records(id, snapshot) VALUES(?1, ?2);", -1, &putStmt, nil)
        sqlite3_prepare_v2(handle, "DELETE FROM records WHERE id=?1;", -1, &deleteStmt, nil)
        sqlite3_prepare_v2(handle, "INSERT INTO journal(client_id, kind, record_id, ts) VALUES(?1, ?2, ?3, ?4);", -1, &journalStmt, nil)
    }

    private func closeDatabase() {
        lock.lock(); defer { lock.unlock() }
        disposed = true
        if let s = putStmt { sqlite3_finalize(s); putStmt = nil }
        if let s = deleteStmt { sqlite3_finalize(s); deleteStmt = nil }
        if let s = journalStmt { sqlite3_finalize(s); journalStmt = nil }
        if let h = db { sqlite3_close_v2(h); db = nil }
    }

    public func dispose() {
        queue.sync { closeDatabase() }
    }

    // MARK: - Public write API

    public func put(_ records: [(CacheKey, [String: JSONValue])]) {
        if records.isEmpty { return }
        enqueueWork { [weak self] in
            self?.performPut(records)
        }
    }

    public func remove(_ ids: [CacheKey]) {
        if ids.isEmpty { return }
        enqueueWork { [weak self] in
            self?.performRemove(ids)
        }
    }

    // MARK: - Load

    public func load() async throws -> [(CacheKey, [String: JSONValue])] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let result = try self.performLoad()
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous bulk load. Runs on the worker queue via `queue.sync`
    /// so the load serializes against any pending writes — the returned
    /// snapshot reflects every committed write up to the call site.
    /// Used by `CachebayClient.warmup()`.
    public func loadSync() throws -> [(CacheKey, [String: JSONValue])] {
        try queue.sync {
            try self.performLoad()
        }
    }

    // MARK: - Flush / evict

    public func flush() async throws {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if drained == enqueued {
                lock.unlock()
                cont.resume()
                return
            }
            drainWaiters.append(cont)
            lock.unlock()
        }
    }

    public func evictJournal() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.performEvictJournal()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func evictAll() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.performEvictAll()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func inspect() async throws -> StorageInspection {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    let info = try self.performInspect()
                    cont.resume(returning: info)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Queue

    private func enqueueWork(_ block: @escaping @Sendable () -> Void) {
        lock.lock()
        if disposed { lock.unlock(); return }
        enqueued &+= 1
        lock.unlock()
        queue.async {
            block()
            self.markWorkDone()
        }
    }

    private func markWorkDone() {
        lock.lock()
        drained &+= 1
        var waiters: [CheckedContinuation<Void, Never>] = []
        if drained == enqueued {
            waiters = drainWaiters
            drainWaiters.removeAll()
        }
        lock.unlock()
        for w in waiters { w.resume() }
    }

    // MARK: - Performers (on `queue`)

    private func performPut(_ records: [(CacheKey, [String: JSONValue])]) {
        guard let db = self.db, let putStmt = self.putStmt, let journalStmt = self.journalStmt else { return }

        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        let ts = Int64(Date().timeIntervalSince1970 * 1000)

        for (id, record) in records {
            // records upsert
            sqlite3_reset(putStmt)
            sqlite3_bind_text(putStmt, 1, id, -1, SQLITE_TRANSIENT)
            let bytes = encodeRecord(record)
            _ = bytes.withUnsafeBytes { raw -> Int32 in
                if let base = raw.baseAddress {
                    return sqlite3_bind_blob(putStmt, 2, base, Int32(bytes.count), SQLITE_TRANSIENT)
                }
                return sqlite3_bind_zeroblob(putStmt, 2, 0)
            }
            _ = sqlite3_step(putStmt)

            // journal insert
            sqlite3_reset(journalStmt)
            sqlite3_bind_text(journalStmt, 1, context.instanceID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(journalStmt, 2, "put", -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(journalStmt, 3, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(journalStmt, 4, ts)
            _ = sqlite3_step(journalStmt)
        }

        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    private func performRemove(_ ids: [CacheKey]) {
        guard let db = self.db, let deleteStmt = self.deleteStmt, let journalStmt = self.journalStmt else { return }

        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        let ts = Int64(Date().timeIntervalSince1970 * 1000)

        for id in ids {
            sqlite3_reset(deleteStmt)
            sqlite3_bind_text(deleteStmt, 1, id, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(deleteStmt)

            sqlite3_reset(journalStmt)
            sqlite3_bind_text(journalStmt, 1, context.instanceID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(journalStmt, 2, "remove", -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(journalStmt, 3, id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(journalStmt, 4, ts)
            _ = sqlite3_step(journalStmt)
        }

        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    private func performLoad() throws -> [(CacheKey, [String: JSONValue])] {
        if let openError { throw openError }
        guard let db = self.db else { return [] }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "SELECT id, snapshot FROM records;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        if rc != SQLITE_OK { throw SQLiteError(code: rc, message: "prepare load") }

        var out: [(CacheKey, [String: JSONValue])] = []
        out.reserveCapacity(256)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idC)
            let size = sqlite3_column_bytes(stmt, 1)
            guard size > 0, let blob = sqlite3_column_blob(stmt, 1) else {
                out.append((id, [:])); continue
            }
            let data = Data(bytes: blob, count: Int(size))
            if let rec = try? decodeRecord(data) {
                out.append((id, rec))
            }
        }
        return out
    }

    private func performEvictJournal() throws {
        guard let db = self.db else { return }
        let cutoff = Int64((Date().timeIntervalSince1970 - options.journalMaxAge) * 1000)
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, "DELETE FROM journal WHERE ts < ?1;", -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        if rc != SQLITE_OK { throw SQLiteError(code: rc, message: "prepare evictJournal") }
        sqlite3_bind_int64(stmt, 1, cutoff)
        _ = sqlite3_step(stmt)
    }

    private func performEvictAll() throws {
        guard let db = self.db, let journalStmt = self.journalStmt else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM records;", nil, nil, nil)
        sqlite3_exec(db, "DELETE FROM journal;", nil, nil, nil)
        // Write evict-all signal so other processes (if any) can react.
        sqlite3_reset(journalStmt)
        sqlite3_bind_text(journalStmt, 1, context.instanceID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(journalStmt, 2, "evict-all", -1, SQLITE_TRANSIENT)
        sqlite3_bind_null(journalStmt, 3)
        sqlite3_bind_int64(journalStmt, 4, Int64(Date().timeIntervalSince1970 * 1000))
        _ = sqlite3_step(journalStmt)
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    private func performInspect() throws -> StorageInspection {
        guard let db = self.db else {
            return StorageInspection(recordCount: 0, journalCount: 0, lastSeenSeq: 0, instanceID: context.instanceID)
        }
        let recordCount = countQuery(db: db, sql: "SELECT COUNT(*) FROM records;")
        let journalCount = countQuery(db: db, sql: "SELECT COUNT(*) FROM journal;")
        let maxSeq = int64Query(db: db, sql: "SELECT COALESCE(MAX(seq), 0) FROM journal;")
        return StorageInspection(recordCount: recordCount, journalCount: journalCount, lastSeenSeq: maxSeq, instanceID: context.instanceID)
    }

    private func countQuery(db: OpaquePointer, sql: String) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func int64Query(db: OpaquePointer, sql: String) -> Int64 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    // MARK: - Record codec

    /// Encode a record as JSON bytes via the yyjson writer (one pass; `.ref`/
    /// `.refList` written as `__ref`/`__refs` sentinels). Symmetric with the
    /// one-pass `decodeRecord`.
    private func encodeRecord(_ record: [String: JSONValue]) -> Data {
        (try? JSONValue.object(record).encodeYYJSON(sortKeys: false, pretty: false)) ?? Data()
    }

    private func decodeRecord(_ data: Data) throws -> [String: JSONValue] {
        // One pass: yyjson parse + inline `__ref`/`__refs` sentinel restoration.
        // Replaces the prior JSONSerialization parse + `from(any:)` rebuild +
        // separate `restoreRefs` walk (three passes → one).
        try JSONValue.parseYYJSONRecord(data)
    }
}

// MARK: - Errors

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLiteError(\(code)): \(message)" }
}

/// SQLite static/transient binding markers — Swift overlay doesn't expose them.
private let SQLITE_STATIC = unsafeBitCast(OpaquePointer(bitPattern: 0), to: sqlite3_destructor_type.self)
private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
