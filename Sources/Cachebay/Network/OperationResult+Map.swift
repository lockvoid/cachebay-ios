import Foundation

// MARK: - OperationResult helpers

public extension OperationResult {
    /// Project the result's data into a different shape, preserving the
    /// `error` / `meta` slots. Returns `nil` data when the input data
    /// can't be projected (e.g. the typed decode returned nil for a
    /// non-decodable frame). `Meta` is rebuilt rather than copied because
    /// it's a generic-nested type — `OperationResult<TData>.Meta` and
    /// `OperationResult<U>.Meta` are distinct Swift types even though
    /// their stored layout is identical.
    ///
    /// Used by the typed `CachebayOperation` execute/subscription overloads
    /// to map a runtime `OperationResult<JSONValue>` into the operation's
    /// eagerly-decoded `Op.Data` (`Op.Data(cachebayJSON:)`).
    func mapData<U: Sendable>(_ transform: (TData) -> U?) -> OperationResult<U> {
        let translatedMeta: OperationResult<U>.Meta? = meta.map { src in
            let translatedSource: OperationResult<U>.Meta.Source? = src.source.map { s in
                switch s {
                case .cache: return .cache
                case .network: return .network
                }
            }
            return OperationResult<U>.Meta(source: translatedSource)
        }
        return OperationResult<U>(
            data: data.flatMap(transform),
            error: error,
            meta: translatedMeta
        )
    }
}
