import Foundation
@testable import Cachebay

/// In-memory `CachebayProfiler` for tests. Records every span and
/// `record` event with timestamps so tests can assert: which spans
/// fired, in what order, with what attributes, and whether a host
/// callback executed inside a span (which it must not).
public final class RecordingProfiler: CachebayProfiler, @unchecked Sendable {
    public struct SpanRecord: Sendable {
        public let name: String
        public let beganAt: TimeInterval
        public internal(set) var endedAt: TimeInterval?
        public internal(set) var attributes: [String: String] = [:]
        public internal(set) var pauseSegments: [(TimeInterval, TimeInterval)] = []
        /// Thread on which `begin(_:)` was invoked.
        public let beganOnMain: Bool
        /// Thread on which `end()` was invoked (nil while the span is
        /// still open). When `beganOnMain != endedOnMain`, the span's
        /// work crossed a queue boundary — a useful diagnostic for
        /// async paths.
        public internal(set) var endedOnMain: Bool?
        /// Whether the span has been ended.
        public var isEnded: Bool { endedAt != nil }
        /// Sum of paused intervals (host-callback exclusion regions).
        public var pausedDuration: TimeInterval {
            pauseSegments.reduce(0) { $0 + ($1.1 - $1.0) }
        }
    }

    public struct EventRecord: Sendable {
        public let name: String
        public let value: Double
        public let attributes: [String: String]
        public let at: TimeInterval
    }

    private let lock = NSLock()
    private var _spans: [SpanRecord] = []
    private var _events: [EventRecord] = []
    /// Names of spans currently open (i.e., begin called, end not yet).
    /// Used by `assertHostNotInsideSpan` and the like.
    private var _activeNames: [String] = []

    public init() {}

    // MARK: CachebayProfiler

    public func begin(_ name: StaticString) -> CachebayProfileSpan? {
        let nameStr = "\(name)"
        // Capture thread state before taking the lock — `Thread.isMainThread`
        // is a thread-local read (~1-5 ns), well below the cost of the
        // surrounding work. Centralising it here means call sites don't need
        // to plug per-span thread instrumentation.
        let beganOnMain = Thread.isMainThread
        lock.lock()
        let index = _spans.count
        _spans.append(SpanRecord(name: nameStr, beganAt: Self.now(), beganOnMain: beganOnMain))
        _activeNames.append(nameStr)
        lock.unlock()
        return Span(profiler: self, index: index, name: nameStr)
    }

    public func record(_ name: StaticString, value: Double) {
        record(name, value: value, attributes: [:])
    }

    public func record(_ name: StaticString, value: Double, attributes: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        _events.append(EventRecord(name: "\(name)", value: value, attributes: attributes, at: Self.now()))
    }

    // MARK: Inspection

    public var spans: [SpanRecord] {
        lock.lock(); defer { lock.unlock() }
        return _spans
    }

    public var events: [EventRecord] {
        lock.lock(); defer { lock.unlock() }
        return _events
    }

    public var activeNames: [String] {
        lock.lock(); defer { lock.unlock() }
        return _activeNames
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        _spans.removeAll()
        _events.removeAll()
        _activeNames.removeAll()
    }

    // MARK: Span-internal mutators

    fileprivate func endSpan(at index: Int) {
        let endedOnMain = Thread.isMainThread
        lock.lock(); defer { lock.unlock() }
        guard index < _spans.count else { return }
        if _spans[index].endedAt != nil { return }
        _spans[index].endedAt = Self.now()
        _spans[index].endedOnMain = endedOnMain
        if let idx = _activeNames.firstIndex(of: _spans[index].name) {
            _activeNames.remove(at: idx)
        }
    }

    fileprivate func setAttribute(at index: Int, key: String, value: String) {
        lock.lock(); defer { lock.unlock() }
        guard index < _spans.count, _spans[index].endedAt == nil else { return }
        _spans[index].attributes[key] = value
    }

    fileprivate func pauseSpan(at index: Int) {
        lock.lock(); defer { lock.unlock() }
        guard index < _spans.count, _spans[index].endedAt == nil else { return }
        // Open a new pause segment with start=now, end=now (closed by resume).
        _spans[index].pauseSegments.append((Self.now(), .infinity))
    }

    fileprivate func resumeSpan(at index: Int) {
        lock.lock(); defer { lock.unlock() }
        guard index < _spans.count, _spans[index].endedAt == nil else { return }
        if var last = _spans[index].pauseSegments.last, last.1 == .infinity {
            last.1 = Self.now()
            _spans[index].pauseSegments[_spans[index].pauseSegments.count - 1] = last
        }
    }

    private static func now() -> TimeInterval {
        return ProcessInfo.processInfo.systemUptime
    }

    // MARK: - Span

    private final class Span: CachebayProfileSpan, @unchecked Sendable {
        weak var profiler: RecordingProfiler?
        let index: Int
        let name: String
        private var ended = false
        private let lock = NSLock()
        init(profiler: RecordingProfiler, index: Int, name: String) {
            self.profiler = profiler
            self.index = index
            self.name = name
        }
        func end() {
            lock.lock(); defer { lock.unlock() }
            if ended { return }
            ended = true
            profiler?.endSpan(at: index)
        }
        func attribute(_ key: StaticString, _ value: String) {
            lock.lock(); defer { lock.unlock() }
            if ended { return }
            profiler?.setAttribute(at: index, key: "\(key)", value: value)
        }
        func pause() {
            lock.lock(); defer { lock.unlock() }
            if ended { return }
            profiler?.pauseSpan(at: index)
        }
        func resume() {
            lock.lock(); defer { lock.unlock() }
            if ended { return }
            profiler?.resumeSpan(at: index)
        }
    }
}

// MARK: - Test helpers

extension RecordingProfiler {
    /// True iff at least one span with the given name was begun.
    public func didEmit(_ name: String) -> Bool {
        spans.contains(where: { $0.name == name })
    }

    /// All spans for a given name (in begin order).
    public func spans(named name: String) -> [SpanRecord] {
        spans.filter { $0.name == name }
    }

    /// All events for a given name (in emission order).
    public func events(named name: String) -> [EventRecord] {
        events.filter { $0.name == name }
    }
}
