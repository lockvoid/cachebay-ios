#if canImport(os)
    import Foundation
    import os

    /// `CachebayProfiler` conformance backed by Apple's `OSSignposter`.
    /// Drop one of these into `CachebayOptions.profiler` and every
    /// instrumented Cachebay call shows up as a signpost interval in
    /// Instruments → "os_signpost" → subsystem `com.cachebay` (override
    /// at init time if your app has its own subsystem convention).
    ///
    /// **Cost when Instruments isn't recording**: signposts compile to
    /// a single `os_signpost_enabled` check that the kernel answers
    /// without a syscall when no consumer is attached. The span object
    /// is still allocated (one small reference type per call), so for
    /// extremely hot paths where the alloc dominates you may prefer a
    /// custom profiler that returns `nil` from `begin(...)` when not
    /// actively recording.
    ///
    /// `pause()` / `resume()` map to `endInterval` + a fresh
    /// `beginInterval` with the same name and signpost ID. In
    /// Instruments this renders as two adjacent intervals with a gap —
    /// the gap is the excluded host-callback time. Aggregations over
    /// "Total duration" sum the two intervals, which is the right
    /// answer.
    @available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
    public final class OSSignpostProfiler: CachebayProfiler {
        private let signposter: OSSignposter

        public init(subsystem: String = "com.cachebay", category: String = "Cachebay") {
            self.signposter = OSSignposter(subsystem: subsystem, category: category)
        }

        public func begin(_ name: StaticString) -> CachebayProfileSpan? {
            let id = signposter.makeSignpostID()
            // Capture thread state at begin so every span auto-emits which
            // thread it started on — no call-site instrumentation needed.
            // `Thread.isMainThread` is a thread-local read, ~1-5 ns; well
            // below the cost of the surrounding `beginInterval` call.
            let beganOnMain = Thread.isMainThread
            let state = signposter.beginInterval(name, id: id)
            return OSSignpostSpan(signposter: signposter, name: name, id: id, state: state, beganOnMain: beganOnMain)
        }

        public func record(_ name: StaticString, value: Double) {
            signposter.emitEvent(name, "value=\(value)")
        }

        public func record(_ name: StaticString, value: Double, attributes: [String: String]) {
            if attributes.isEmpty {
                signposter.emitEvent(name, "value=\(value)")
            } else {
                // Sort keys for deterministic message strings — easier to grep
                // recordings and tests don't flake on dict iteration order.
                let attrs =
                    attributes
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                signposter.emitEvent(name, "value=\(value) \(attrs, privacy: .public)")
            }
        }
    }

    @available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
    private final class OSSignpostSpan: CachebayProfileSpan, @unchecked Sendable {
        private let signposter: OSSignposter
        private let name: StaticString
        private let id: OSSignpostID
        private let beganOnMain: Bool
        private let lock = NSLock()
        private var state: OSSignpostIntervalState?
        private var ended = false

        init(signposter: OSSignposter, name: StaticString, id: OSSignpostID, state: OSSignpostIntervalState, beganOnMain: Bool) {
            self.signposter = signposter
            self.name = name
            self.id = id
            self.state = state
            self.beganOnMain = beganOnMain
        }

        func end() {
            lock.lock(); defer { lock.unlock() }
            if ended { return }
            ended = true
            if let s = state {
                // Emit thread metadata BEFORE endInterval so it's
                // associated with the interval in Instruments. begin/end
                // pair surfaces async hops automatically — a span that
                // begins on background and ends on main reveals a queue
                // crossing without any consumer code change.
                let endedOnMain = Thread.isMainThread
                signposter.emitEvent(
                    name,
                    id: id,
                    "thread.begin=\(self.beganOnMain ? "main" : "bg", privacy: .public) thread.end=\(endedOnMain ? "main" : "bg", privacy: .public)"
                )
                signposter.endInterval(name, s)
                state = nil
            }
        }

        func attribute(_ key: StaticString, _ value: String) {
            lock.lock(); defer { lock.unlock() }
            if ended { return }
            signposter.emitEvent(name, id: id, "\(key) \(value, privacy: .public)")
        }

        func pause() {
            lock.lock(); defer { lock.unlock() }
            if ended { return }
            if let s = state {
                signposter.endInterval(name, s)
                state = nil
            }
        }

        func resume() {
            lock.lock(); defer { lock.unlock() }
            if ended { return }
            if state == nil {
                state = signposter.beginInterval(name, id: id)
            }
        }
    }
#endif
