import Foundation

/// One voice for every silent-nil path in Cachebay — the **typed-decode** hooks
/// (`@CachebayData init?(cachebayJSON:)`, the `Array`/`Optional` `CachebayValue`
/// conformances) and the **materialize** layer (a record that doesn't satisfy a
/// watching query's selection set).
///
/// Both used to fail quietly — decode by returning `nil` (logger-less signature),
/// materialize by a `logger?.warning` only the owning client could see. A decode
/// miss could blank the UI while materialize reported success (the ferment-cuts
/// empty-list bug: 29 raw edges materialized fine, then typed decode dropped them
/// to 0, with no log). Routing both here gives them a single, capturable sink.
///
/// Posture (deliberately split):
/// - **Log is the floor.** `sink` is called on every miss. `CachebayClient` points
///   it at `options.logger`; under XCTest it defaults ON (so a miss is never silent
///   in a test run, even without a client logger). The closure form lets tests
///   capture misses; set `sink = nil` to silence.
/// - **Crash is opt-in.** `strictAssert` (default `false`) gates a DEBUG
///   `assertionFailure` on every miss. It's *not* on by default — a required-field
///   miss is *mostly* a bug but not always (an optimistic / partial record is a
///   legitimate transient miss), and the library's own miss-path tests would
///   detonate. Turn it on in a focused test or a dev build to make misses fatal.
public enum CachebayDiagnostics {
    nonisolated(unsafe) public static var sink: ((String) -> Void)? = makeDefaultSink()

    /// When `true`, every miss also triggers a DEBUG `assertionFailure`. Opt-in.
    nonisolated(unsafe) public static var strictAssert: Bool = false

    /// A typed-decode hook returned `nil`. `type` is the struct/list being decoded;
    /// `reason` names the failing field / `__typename` / element.
    @inline(__always)
    public static func decodeMiss(_ type: String, _ reason: @autoclosure () -> String) {
        guard sink != nil || strictAssert else { return }
        report("typed-decode miss: \(type) — \(reason()) (returned nil; a watcher emitting this gets an empty/absent value)")
    }

    /// A record didn't satisfy a watching query's selection set during materialize.
    @inline(__always)
    public static func materializeMiss(_ detail: @autoclosure () -> String) {
        guard sink != nil || strictAssert else { return }
        report("materialize miss: \(detail())")
    }

    /// Verify a `CachebayValue` conformance is **encode-stable**: re-encoding after
    /// one decode round-trip yields identical JSON — `encode(decode(encode(x))) ==
    /// encode(x)`. Catches genuinely lossy/asymmetric custom-scalar conformances
    /// while tolerating legitimate precision normalization (the fixed point is on
    /// the *encoded* form, so a `Date` that loses sub-ms on round-trip still
    /// passes). Reports an `encode-unstable` miss (and, with `strictAssert`,
    /// aborts) when it isn't, and returns the result.
    ///
    /// Does NOT validate the server wire format — a value the server rejects
    /// (e.g. a Date in the wrong layout) encodes fine locally; only the server
    /// knows. Use this in tests for your custom scalar conformances.
    @discardableResult
    public static func checkEncodeStable<T: CachebayValue>(_ value: T, _ label: String = "") -> Bool {
        let name = label.isEmpty ? "\(T.self)" : label
        let encoded = value.cachebayJSON
        guard let roundTrip = T(cachebayJSON: encoded) else {
            report("encode-unstable: \(name) — decode(encode(x)) returned nil")
            return false
        }
        if roundTrip.cachebayJSON != encoded {
            report("encode-unstable: \(name) — re-encode differs after a round-trip (lossy/asymmetric conformance)")
            return false
        }
        return true
    }

    private static func report(_ message: String) {
        // The sink adds the "[Cachebay] " prefix (the client's logger sink does, and
        // so does the default stderr sink) — pass the bare message to avoid doubling.
        sink?(message)
        if strictAssert { assertionFailure("[Cachebay] \(message)") }
    }

    /// The sink installed at process start. Under XCTest the env var
    /// `XCTestConfigurationFilePath` is set, so a default stderr sink is installed
    /// — a miss screams in a test run even with no client logger. App/release
    /// default is `nil` (the client wires its own logger). Internal for testing.
    static func makeDefaultSink() -> ((String) -> Void)? {
        // `XCTestCase` is loaded under both `swift test` and the Xcode runner;
        // `XCTestConfigurationFilePath` only under Xcode. Check both.
        let underTest = NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        guard underTest else { return nil }
        return { message in FileHandle.standardError.write(Data(("[Cachebay] " + message + "\n").utf8)) }
    }
}
