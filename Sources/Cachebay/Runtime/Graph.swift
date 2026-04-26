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

    private var records: [CacheKey: [String: JSONValue]] = [:]
    private var versions: [CacheKey: UInt32] = [:]
    private var pending: Set<CacheKey> = []
    private var versionClock: UInt32 = 0
    private var isFlushing = false

    private let lock = NSRecursiveLock()

    public init(options: GraphOptions = .init()) {
        self.keys = options.keys
        self.interfaces = options.interfaces
        self.onChange = options.onChange

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

    private func noteChangeLocked(_ id: CacheKey, patch: [String: JSONValue]?) {
        pending.insert(id)
        if id == CachebayConstants.rootID, let patch {
            for k in patch.keys {
                pending.insert("\(id).\(k)")
            }
        }
    }

    /// Deliver all pending change notifications to `onChange`.
    /// Re-entrant flushes triggered by the handler are suppressed and will
    /// surface on the next outer-scope flush call.
    public func flush() {
        lock.lock()
        if isFlushing || pending.isEmpty {
            lock.unlock()
            return
        }
        isFlushing = true
        let handler = onChange
        let touched = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()

        handler?(touched)

        lock.lock()
        isFlushing = false
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
