import Foundation

/// A value that can be eagerly decoded from, and encoded back to, the cache's
/// `JSONValue` representation. This is the single hook the v1.0 typed-struct macros
/// use for field decode/encode — it unifies built-in scalars, custom scalars,
/// generated `@CachebayData` structs / `@CachebayInterface` enums, and the
/// `Optional` / `Array` wrappers, so the generated `init?(_dataDict:)` is uniform:
///
/// ```swift
/// guard let url = URL(cachebayJSON: dict["url"] ?? .undefined) else { return nil }
/// ```
///
/// Decode contract (eager-decode failure semantics, proposal §7):
/// - A **required** field whose `init?(cachebayJSON:)` returns `nil` fails the whole
///   record → `materialize` surfaces a `strictOK = false` miss (refetch). Missing
///   (`.undefined`) and malformed values both return `nil` for required scalars.
/// - **Optional** fields never fail: missing/null/malformed decode to `nil`.
/// - **Custom scalars**: conform your type to `CachebayValue` to plug it in.
public protocol CachebayValue {
    /// Decode from a cache `JSONValue`. Return `nil` to signal a required-field miss.
    init?(cachebayJSON json: JSONValue)
    /// Encode back to a cache `JSONValue` (round-trip / patch substrate).
    var cachebayJSON: JSONValue { get }
}

// MARK: - Built-in scalars

extension String: CachebayValue {
    public init?(cachebayJSON json: JSONValue) {
        guard let s = json.string else { return nil }
        self = s
    }
    public var cachebayJSON: JSONValue { .string(self) }
}

extension Bool: CachebayValue {
    public init?(cachebayJSON json: JSONValue) {
        guard let b = json.bool else { return nil }
        self = b
    }
    public var cachebayJSON: JSONValue { .bool(self) }
}

extension Int: CachebayValue {
    public init?(cachebayJSON json: JSONValue) {
        guard let i = json.int else { return nil }
        self = Int(i)
    }
    public var cachebayJSON: JSONValue { .int(Int64(self)) }
}

extension Int64: CachebayValue {
    public init?(cachebayJSON json: JSONValue) {
        guard let i = json.int else { return nil }
        self = i
    }
    public var cachebayJSON: JSONValue { .int(self) }
}

extension Double: CachebayValue {
    public init?(cachebayJSON json: JSONValue) {
        guard let d = json.double else { return nil }
        self = d
    }
    public var cachebayJSON: JSONValue { .double(self) }
}

extension Float: CachebayValue {
    public init?(cachebayJSON json: JSONValue) {
        guard let d = json.double else { return nil }
        self = Float(d)
    }
    public var cachebayJSON: JSONValue { .double(Double(self)) }
}

// MARK: - Common custom scalars

extension URL: CachebayValue {
    public init?(cachebayJSON json: JSONValue) {
        guard let s = json.string, let url = URL(string: s) else { return nil }
        self = url
    }
    public var cachebayJSON: JSONValue { .string(absoluteString) }
}

extension Date: CachebayValue {
    public init?(cachebayJSON json: JSONValue) {
        switch json {
        case .string(let s):
            guard let d = CachebayDateFormatting.parse(s) else { return nil }
            self = d
        case .double(let secs):
            self = Date(timeIntervalSince1970: secs)
        case .int(let secs):
            self = Date(timeIntervalSince1970: Double(secs))
        default:
            return nil
        }
    }
    public var cachebayJSON: JSONValue { .string(CachebayDateFormatting.string(from: self)) }
}

/// ISO-8601 date (de)serialization for the built-in `Date` scalar.
enum CachebayDateFormatting {
    // Configured once at init, then only used for read-only parse/format, which
    // ISO8601DateFormatter supports concurrently. `nonisolated(unsafe)` because the
    // type isn't `Sendable` but our usage never mutates it after setup.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String) -> Date? {
        iso.date(from: s) ?? isoNoFraction.date(from: s)
    }
    static func string(from date: Date) -> String {
        iso.string(from: date)
    }
}

// MARK: - Wrappers

extension Optional: CachebayValue where Wrapped: CachebayValue {
    /// Optional fields never fail the record: missing/null → `nil`; malformed → `nil`.
    public init?(cachebayJSON json: JSONValue) {
        switch json {
        case .null, .undefined:
            self = .none
        default:
            // `.some(value)` on success, `.none` on malformed — never a record miss.
            self = Wrapped(cachebayJSON: json)
        }
    }
    public var cachebayJSON: JSONValue {
        self?.cachebayJSON ?? .null
    }
}

extension Array: CachebayValue where Element: CachebayValue {
    /// A required list that is missing/null/non-array, or whose element fails to
    /// decode, is a record miss (`nil`). Use `[T]?` for a nullable list.
    public init?(cachebayJSON json: JSONValue) {
        guard case .array(let xs) = json else { return nil }
        var out: [Element] = []
        out.reserveCapacity(xs.count)
        for x in xs {
            guard let e = Element(cachebayJSON: x) else { return nil }
            out.append(e)
        }
        self = out
    }
    public var cachebayJSON: JSONValue {
        .array(map { $0.cachebayJSON })
    }
}
