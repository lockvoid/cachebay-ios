import Foundation

// MARK: - CachebayProfiler

/// Opt-in instrumentation surface. Cachebay calls into a profiler at
/// every user-facing operation (mutations, queries, fragment writes,
/// optimistic updates) and at every internal hot path that competes
/// for visible time (normalize, materialize, graph flush, watcher
/// fanout, optimistic replay, storage flush/warmup).
///
/// The protocol is designed so that **a `nil` profiler costs one nil
/// check per call site** — no allocations, no closure capture, no
/// argument evaluation beyond the trivial. Wire one in via
/// `CachebayOptions.profiler`; ship `OSSignpostProfiler()` by default
/// if you want Instruments timelines, or implement your own conformance
/// for OpenTelemetry / Firebase / custom telemetry pipelines.
///
/// ## Host-callback exclusion
///
/// Cachebay is careful to keep host code (your `builder` closure in
/// `modifyOptimistic`, your watcher's `onData`, your commit closure)
/// **out** of the reported span time. The convention:
///
/// - **Pattern A** — span wraps internal work that contains a host
///   callback. Cachebay pauses the span around the host call so the
///   host's time is subtracted from the reported duration:
///
///   ```swift
///   let span = profiler?.begin("cachebay.modifyOptimistic")
///   defer { span?.end() }
///   // ... internal work ...
///   span.excludingHost { builder(b) }  // ← host code, not counted
///   // ... internal work ...
///   ```
///
/// - **Pattern B** — internal work ends *before* the loop that invokes
///   host callbacks. No span is open across the host call, so it's
///   naturally outside any measured region:
///
///   ```swift
///   let span = profiler?.begin("cachebay.watchers.fanout")
///   // ... build emits list ...
///   span?.end()
///   for (cb, v) in emits { cb(v) }  // ← host code, outside any span
///   ```
///
/// Pattern B is preferred where the host call is the tail of the
/// operation; Pattern A is the escape hatch for closures that fire
/// mid-flight.
///
/// ## Performance contract
///
/// - When `profiler == nil`, every instrumentation call is a single
///   nil check (Swift's `?.` short-circuit). Attributes set via
///   `span?.attribute(...)` are not evaluated.
/// - When the profiler is attached but `begin(...)` returns `nil`
///   (e.g., `OSSignpostProfiler` when Instruments isn't recording),
///   the call site still compiles to a nil check on the result.
/// - Span objects are reference-typed and `Sendable`. Implementations
///   must be safe across thread boundaries (async paths begin a span
///   on one thread and end it on another after a suspension point).
public protocol CachebayProfiler: AnyObject, Sendable {
    /// Begin a duration span. Return `nil` if the profiler isn't
    /// currently recording — call sites short-circuit on the result.
    func begin(_ name: StaticString) -> CachebayProfileSpan?

    /// Point-in-time signal (counts, hit/miss flags, scope sizes).
    /// Doesn't wrap host work — call once with the final value.
    func record(_ name: StaticString, value: Double)

    /// Same as `record(_:value:)` but carries structured attributes.
    /// Cachebay only emits this when the profiler is non-nil (callers
    /// must check before building the attribute dictionary).
    func record(_ name: StaticString, value: Double, attributes: [String: String])
}

// MARK: - CachebayProfileSpan

/// A live duration span returned by `CachebayProfiler.begin(_:)`.
/// Always reference-typed; sites pattern-match `Optional` and call
/// through `span?.method()` so the disabled case stays free.
///
/// Lifecycle: `begin → (attribute|pause|resume)* → end`. Calling any
/// method after `end()` is a defined no-op. Implementations must be
/// thread-safe — async work begins a span before a suspension point
/// and ends it after, possibly on a different thread.
public protocol CachebayProfileSpan: AnyObject, Sendable {
    /// Finalize the span. Idempotent (extra calls after the first are
    /// no-ops).
    func end()

    /// Attach a structured attribute discovered mid-flight. Cheap when
    /// the span exists; when the span is nil at the call site the
    /// `?.attribute(...)` short-circuit means this method is never
    /// invoked.
    func attribute(_ key: StaticString, _ value: String)

    /// Stop counting time on this span until `resume()` (or `end()`).
    /// Used to exclude host callback time from the reported duration.
    /// Idempotent: calling `pause()` on an already-paused span is a
    /// no-op. Implementations subtract the paused interval from the
    /// total they report.
    func pause()

    /// Resume time counting after a `pause()`. Idempotent.
    func resume()
}

// MARK: - Host-exclusion helper

extension Optional where Wrapped == CachebayProfileSpan {
    /// Run a host callback with the enclosing span paused. Use this
    /// any time Cachebay invokes user code from inside an open span —
    /// the `builder` in `modifyOptimistic`, a `commit { … }` closure,
    /// etc. Eliminates host time from the reported span duration.
    @inlinable
    public func excludingHost<T>(_ body: () throws -> T) rethrows -> T {
        switch self {
        case .some(let s):
            s.pause()
            defer { s.resume() }
            return try body()
        case .none:
            return try body()
        }
    }

    /// Async overload of `excludingHost` for awaiting host code from
    /// inside a span. Same contract: the span is paused around the
    /// body and resumed afterwards.
    @inlinable
    public func excludingHost<T>(_ body: () async throws -> T) async rethrows -> T {
        switch self {
        case .some(let s):
            s.pause()
            defer { s.resume() }
            return try await body()
        case .none:
            return try await body()
        }
    }
}

// MARK: - Span name registry (documentation aid)

/// The complete set of span names Cachebay emits. This enum is
/// intentionally NOT used at call sites (those use `StaticString`
/// literals directly so the names live in the binary's `__cstring`
/// section, zero-alloc). It exists to document the inventory and to
/// give tests a stable reference for assertions.
public enum CachebayProfileName: String, CaseIterable {
    // Optimistic
    case modifyOptimistic       = "cachebay.modifyOptimistic"
    case applyAutoCommit        = "cachebay.applyAutoCommit"
    case optimisticCommit       = "cachebay.optimistic.commit"
    case optimisticRevert       = "cachebay.optimistic.revert"
    case optimisticDispose      = "cachebay.optimistic.dispose"
    case replayConnection       = "cachebay.optimistic.replay.connection"
    case replayEntity           = "cachebay.optimistic.replay.entity"

    // Operations
    case executeMutation        = "cachebay.executeMutation"
    case executeQuery           = "cachebay.executeQuery"
    case executeSubscriptionFrame = "cachebay.executeSubscription.frame"

    // Documents
    case normalize              = "cachebay.documents.normalize"
    case materialize            = "cachebay.documents.materialize"

    // Fragments
    case readFragment           = "cachebay.readFragment"
    case writeFragment          = "cachebay.writeFragment"

    // Graph / watcher fanout
    case graphFlush             = "cachebay.graph.flush"
    case watchersFanout         = "cachebay.watchers.fanout"

    // Storage
    case storageFlush           = "cachebay.storage.flush"
    case storageWarmup          = "cachebay.storage.warmup"

    // Counter events (point-in-time, not durations)
    case watchersEmitted        = "cachebay.watchers.emitted"
    case watchersSilenced       = "cachebay.watchers.silenced"
}
