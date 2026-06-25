import Foundation

/// A user-provided key function — returns a stable identity string for an
/// object's identity field. Called with the raw server object. Returning nil
/// falls back to the object's `id` field, then to no-normalization.
public typealias KeyFunction = @Sendable (_ typename: String, _ object: [String: JSONValue]) -> String?

public typealias GraphChangeHandler = @Sendable (_ touched: Set<CacheKey>) -> Void

/// Options for the Graph store.
public struct GraphOptions: Sendable {
    /// Map of typename → key function. If a typename has no entry, falls back to `id`.
    public var keys: [String: KeyFunction]
    /// Interface → implementing concrete types. Used by reads to detect that
    /// a selection set on an interface applies to a concrete record.
    public var interfaces: [String: [String]]
    /// Delivered after each `flush()` with the set of record IDs whose snapshot
    /// changed (or was removed, value=nil) since the last flush.
    public var onChange: GraphChangeHandler?

    public init(
        keys: [String: KeyFunction] = [:],
        interfaces: [String: [String]] = [:],
        onChange: GraphChangeHandler? = nil
    ) {
        self.keys = keys
        self.interfaces = interfaces
        self.onChange = onChange
    }
}

/// The normalized record store. Single source of truth for entities, pages,
/// edges, and connection meta. Reads are synchronous; writes are batched and
/// flushed explicitly via `flush()` or implicitly at the end of top-level
/// operations (normalize/mutation/etc.) so multiple `putRecord` calls
/// coalesce into one `onChange` delivery.
///
/// Thread-safety: internal `NSLock` serializes state access. `final class` +
/// `@unchecked Sendable` because the lock makes concurrent access safe.
public final class Graph: @unchecked Sendable {
    private var keys: [String: KeyFunction]
    private var interfaces: [String: [String]]
    private var implementers: [String: Set<String>]
    private var onChange: GraphChangeHandler?
    let profiler: (any CachebayProfiler)?

    private var records: [CacheKey: [String: JSONValue]] = [:]
    private var versions: [CacheKey: UInt32] = [:]
    private var pending: Set<CacheKey> = []
    private var versionClock: UInt32 = 0
    private var isFlushing = false
    /// While > 0, `flush()` defers delivery — `pending` keeps accumulating so a
    /// multi-op writer (an optimistic layer) can complete, and tolerate cache
    /// reads that internally flush, without leaking a half-applied state to
    /// watchers. See `beginNotificationBatch()`.
    private var notifySuspendDepth = 0

    private let lock = NSRecursiveLock()

    public init(options: GraphOptions = .init(), profiler: (any CachebayProfiler)? = nil) {
        self.keys = options.keys
        self.interfaces = options.interfaces
        self.onChange = options.onChange
        self.profiler = profiler

        var impls: [String: Set<String>] = [:]
        for (iface, concrete) in options.interfaces {
            impls[iface] = Set(concrete)
        }
        self.implementers = impls
    }

    /// Replace the change handler (used by CachebayClient after Graph creation).
    public func setOnChange(_ handler: GraphChangeHandler?) {
        lock.lock(); defer { lock.unlock() }
        self.onChange = handler
    }

    // MARK: - Identity

    /// Map `Type → parent interface name` (canonical typename). Returns the
    /// parent interface if the given typename is an implementer, else the
    /// typename itself.
    public func canonicalTypename(_ typename: String) -> String {
        lock.lock(); defer { lock.unlock() }
        for (iface, impls) in implementers where impls.contains(typename) {
            return iface
        }
        return typename
    }

    /// Returns the set of concrete typenames implementing the given interface.
    /// Empty set if the typename is not registered as an interface.
    public func getImplementers(_ name: String) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return implementers[name] ?? []
    }

    /// Compute a stable cache key for an object. Returns nil if the object
    /// lacks `__typename` and a configured key function, or if the key function
    /// returns nil and the object has no `id`.
    public func identify(_ object: [String: JSONValue]) -> CacheKey? {
        guard let typename = object[CachebayConstants.typenameField]?.string else { return nil }
        lock.lock(); defer { lock.unlock() }
        let canonical = canonicalTypenameLocked(typename)
        if let fn = keys[canonical], let key = fn(canonical, object) {
            return "\(canonical):\(key)"
        }
        if let idValue = object[CachebayConstants.idField] {
            switch idValue {
            case .string(let s): return "\(canonical):\(s)"
            case .int(let i): return "\(canonical):\(i)"
            case .double(let d): return "\(canonical):\(d)"
            default: return nil
            }
        }
        return nil
    }

    private func canonicalTypenameLocked(_ typename: String) -> String {
        for (iface, impls) in implementers where impls.contains(typename) {
            return iface
        }
        return typename
    }

    // MARK: - Records

    public func getRecord(_ id: CacheKey) -> [String: JSONValue]? {
        lock.lock(); defer { lock.unlock() }
        return records[id]
    }

    public func getField(_ id: CacheKey, _ field: String) -> JSONValue? {
        lock.lock(); defer { lock.unlock() }
        return records[id]?[field]
    }

    public func hasRecord(_ id: CacheKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return records[id] != nil
    }

    /// Merge `patch` into the record at `id`. Fields with `.undefined` values
    /// are removed from the record. Flushing is the caller's responsibility.
    public func putRecord(_ id: CacheKey, _ patch: [String: JSONValue]) {
        lock.lock(); defer { lock.unlock() }
        var existing = records[id] ?? [:]
        var changed = false

        for (field, value) in patch {
            if case .undefined = value {
                if existing.removeValue(forKey: field) != nil { changed = true }
                continue
            }
            if let prev = existing[field] {
                if isDataDeepEqual(prev, value) { continue }
            }
            existing[field] = value
            changed = true
        }

        if !changed { return }

        versionClock &+= 1
        records[id] = existing
        versions[id] = versionClock
        noteChangeLocked(id, patch: patch)
    }

    /// Replace a record with `patch` outright. Useful for optimistic replay.
    public func replaceRecord(_ id: CacheKey, _ patch: [String: JSONValue]) {
        lock.lock(); defer { lock.unlock() }
        let prev = records[id]
        if let prev, prev.count == patch.count {
            var equal = true
            for (k, v) in patch {
                if let pv = prev[k], isDataDeepEqual(pv, v) { continue }
                equal = false; break
            }
            if equal { return }
        }
        versionClock &+= 1
        records[id] = patch
        versions[id] = versionClock
        noteChangeLocked(id, patch: patch)
    }

    /// Remove a record. Flushes the cacheKey as touched.
    public func removeRecord(_ id: CacheKey) {
        lock.lock(); defer { lock.unlock() }
        if records.removeValue(forKey: id) != nil {
            versions.removeValue(forKey: id)
            noteChangeLocked(id, patch: nil)
        }
    }

    public func version(_ id: CacheKey) -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        return versions[id] ?? 0
    }

    /// Atomic `(record, version)` snapshot. Returns the record dict and
    /// its version under a single lock acquisition so a concurrent
    /// writer can't slip a write between the two reads. Returns
    /// `(nil, 0)` for a missing record.
    ///
    /// Why this exists: the materialize path needs to associate the
    /// record contents with their version (for fingerprint/recycle
    /// correctness). Two separate `getRecord` + `version` calls let a
    /// concurrent writer produce a `(stale record, newer version)`
    /// tuple — a subsequent materialize that actually reads the new
    /// record gets the *same* version, and `recycleSnapshots`
    /// version-short-circuits two genuinely-different snapshots into
    /// one, dropping a watcher emit. Captured by
    /// `ConcurrencyStressTests.test_watcher_never_drops_final_state_under_burst`.
    public func recordAndVersion(_ id: CacheKey) -> (record: [String: JSONValue]?, version: UInt32) {
        lock.lock(); defer { lock.unlock() }
        return (records[id], versions[id] ?? 0)
    }

    private func noteChangeLocked(_ id: CacheKey, patch: [String: JSONValue]?) {
        pending.insert(id)
        if id == CachebayConstants.rootID, let patch {
            for k in patch.keys {
                pending.insert("\(id).\(k)")
            }
        }
    }

    /// Deliver all pending change notifications to `onChange`.
    ///
    /// Concurrent callers: only one thread runs the handler at a time;
    /// the others see `isFlushing == true` and return immediately. The
    /// running thread then **loops until pending is empty** so writes
    /// that landed *during* its handler call (from any thread) are
    /// fanned out before the flush exits. Without this loop, concurrent
    /// `normalize → materialize → flush` cycles can lose a write: the
    /// late writer's flush short-circuits while the early writer's
    /// handler has already taken (and cleared) the pending set, so the
    /// late writer's record sits in `pending` until the next external
    /// flush call — meaning watchers depending on it never see the
    /// emit. Captured by
    /// `ConcurrencyStressTests.test_watcher_never_drops_final_state_under_burst`.
    ///
    /// Re-entrant flushes from inside the handler (same thread) still
    /// short-circuit; the re-entry's writes are picked up by the
    /// loop on the next iteration without recursion.
    public func flush() {
        lock.lock()
        if notifySuspendDepth > 0 {
            // Batched (e.g. inside a `modifyOptimistic` closure): keep `pending`
            // accumulating; the flush after `endNotificationBatch()` delivers it
            // as one `onChange`, so observers never see a half-applied layer.
            lock.unlock()
            return
        }
        if isFlushing {
            lock.unlock()
            return
        }
        if pending.isEmpty {
            lock.unlock()
            return
        }
        isFlushing = true
        let handler = onChange

        // Profiler span wraps the flush, but pauses while handler? is
        // running — the handler is downstream Cachebay code (watcher
        // fanout, storage replication) that already has its own spans.
        // Without the pause, those child spans would double-count under
        // `cachebay.graph.flush` AND their own names. The remaining
        // (un-paused) time is the pure flush bookkeeping: pending-set
        // drain, lock juggle, re-entry detection.
        let span = profiler?.begin("cachebay.graph.flush")
        defer { span?.end() }

        while !pending.isEmpty {
            let touched = pending
            pending.removeAll(keepingCapacity: true)
            lock.unlock()
            span?.pause()
            handler?(touched)
            span?.resume()
            lock.lock()
        }
        isFlushing = false
        lock.unlock()
    }

    /// Suspend `flush()` delivery. While a batch is open, `flush()` is a no-op
    /// and `pending` keeps accumulating; the matching `endNotificationBatch()`
    /// followed by a `flush()` delivers the whole batch as a single `onChange`.
    /// Used by `modifyOptimistic` so an optimistic layer is atomic for watchers
    /// even when a cache read inside the closure triggers an internal flush.
    /// Re-entrant (depth-counted).
    public func beginNotificationBatch() {
        lock.lock()
        notifySuspendDepth += 1
        lock.unlock()
    }

    /// End a batch opened by `beginNotificationBatch()`. Does not deliver on its
    /// own — the caller flushes once after, so accumulated `pending` fans out in
    /// one `onChange`.
    public func endNotificationBatch() {
        lock.lock()
        if notifySuspendDepth > 0 { notifySuspendDepth -= 1 }
        lock.unlock()
    }

    // MARK: - Inspect / evict

    public func keysList() -> [CacheKey] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.keys)
    }

    public func evictAll() {
        lock.lock(); defer { lock.unlock() }
        records.removeAll(keepingCapacity: false)
        versions.removeAll(keepingCapacity: false)
        pending.removeAll(keepingCapacity: false)
        versionClock = 0
    }

    /// Debug snapshot of the entire store. Returns a deep copy.
    public func snapshot() -> [CacheKey: [String: JSONValue]] {
        lock.lock(); defer { lock.unlock() }
        return records
    }
}
