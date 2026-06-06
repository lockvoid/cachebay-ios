/// Diagnostic sink for the **typed-decode** path (`@CachebayData init?(cachebayJSON:)`,
/// the `Array`/`Optional` `CachebayValue` conformances).
///
/// Those decode hooks have a logger-less signature (`init?(cachebayJSON:)`), so a
/// failed decode used to return `nil` in total silence — a required field missing,
/// a `__typename` mismatch, or one bad element fail-all'ing a whole list would
/// blank the UI with **no log**, while the materialize layer happily reported
/// success. (This is what made the ferment-cuts empty-list bug invisible: 29 raw
/// edges materialized fine, then the typed decode silently dropped them to 0.)
///
/// `CachebayClient` points `sink` at its per-client `options.logger` on init, so a
/// decode-to-nil now surfaces through the *same* logger as `[Cachebay] materialize
/// miss`. The sink is a plain closure (not a `Logger`) so tests can capture it.
///
/// Single shared sink (set once on the main actor before concurrent reads) — if an
/// app builds multiple clients with different loggers, the last one wins; that's
/// acceptable for a debug diagnostic. Set to `nil` to silence.
public enum CachebayDiagnostics {
    nonisolated(unsafe) public static var sink: ((String) -> Void)?

    /// A typed-decode hook returned `nil`. `type` is the struct/list being decoded;
    /// `reason` names the failing field / `__typename` / element. The `reason`
    /// autoclosure is only evaluated when a sink is installed (zero cost otherwise).
    @inline(__always)
    public static func decodeMiss(_ type: String, _ reason: @autoclosure () -> String) {
        guard let sink else { return }
        sink("typed-decode miss: \(type) — \(reason()) (returned nil; a watcher emitting this gets an empty/absent value)")
    }
}
