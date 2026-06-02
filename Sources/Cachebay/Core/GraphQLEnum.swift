import Foundation

/// Forward-compatible wrapper for a GraphQL **enum read out of a selection set**.
///
/// The generated Swift enum (e.g. `enum VideoIntent: String, CaseIterable`) stays
/// closed and clean — that's what *input* fields use, and what powers exhaustive
/// `switch`es and pickers. Output fields are typed `GraphQLEnum<VideoIntent>` so a
/// value the current client build doesn't know (a case the server added before the
/// app updated) decodes to `.unknown(rawValue)` instead of failing.
///
/// Why a wrapper and not a `case unknown(String)` on the enum itself: an associated-
/// value case is incompatible with `RawRepresentable: String` *and* `CaseIterable`,
/// and our affected fields (`VideoIntent!`, `WidgetKind!`, …) are non-null — a closed
/// enum + lenient decoder would turn an unknown server value into a whole-record miss
/// (a missing row in the UI). `GraphQLEnum` keeps decode **total** while leaving the
/// enum maximally useful.
///
/// House rule: `@CachebayInterface` carries its forward-compat `.unknown(Shared)`
/// *inline*; enums carry it via this *outer* wrapper. Two idioms, deliberate — an
/// interface is already a sum type so `.unknown` is free; an enum kept `String`-backed
/// is not, so the unknown lives one level out.
public enum GraphQLEnum<T>: Hashable, Sendable
where T: RawRepresentable & Hashable & Sendable, T.RawValue == String {
    /// A value the client build knows.
    case known(T)
    /// A raw value the client build does not (yet) know — preserved verbatim.
    case unknown(String)

    /// Total: maps a known raw value to `.known`, anything else to `.unknown(raw)`.
    public init(_ rawValue: String) {
        if let known = T(rawValue: rawValue) {
            self = .known(known)
        } else {
            self = .unknown(rawValue)
        }
    }

    /// The known case, or `nil` when the server sent an unrecognized value.
    public var value: T? {
        if case .known(let v) = self { return v }
        return nil
    }

    /// The wire string for either case (round-trips through `init(_:)`).
    public var rawValue: String {
        switch self {
        case .known(let v): return v.rawValue
        case .unknown(let s): return s
        }
    }
}

// MARK: - Ergonomics

extension GraphQLEnum {
    /// `element.intent == .roll` — false for `.unknown`. Lets callers test a single
    /// known case without unwrapping `.value` or matching `.known(...)`.
    public static func == (lhs: GraphQLEnum<T>, rhs: T) -> Bool {
        lhs.value == rhs
    }

    public static func == (lhs: T, rhs: GraphQLEnum<T>) -> Bool {
        lhs == rhs.value
    }

    /// `!=` mirror of the heterogeneous `==`. Not auto-derived (these aren't the
    /// `Equatable` requirement), so without these `intent != .roll` won't compile.
    public static func != (lhs: GraphQLEnum<T>, rhs: T) -> Bool {
        lhs.value != rhs
    }

    public static func != (lhs: T, rhs: GraphQLEnum<T>) -> Bool {
        lhs != rhs.value
    }

    /// Lets `switch g { case .roll: … }` match a bare known case (Swift routes
    /// expression patterns through `~=`). `.unknown` never matches a known
    /// pattern, so such a `switch` is **non-exhaustive by design** — the compiler
    /// requires a `default` (or an explicit `.unknown` arm), which keeps unknown
    /// handling honest. Callers wanting the exhaustiveness check can still match
    /// structurally with `case .known(.roll)` / `case .unknown(let s)`.
    public static func ~= (pattern: T, value: GraphQLEnum<T>) -> Bool {
        value.value == pattern
    }
}

// MARK: - CachebayValue (decode/encode substrate the typed macros call)

extension GraphQLEnum: CachebayValue {
    /// Decode from the cache `JSONValue`. A string (known or not) always succeeds;
    /// a non-string where an enum was required is genuine drift -> `nil` (required
    /// miss), matching the built-in scalar contract.
    public init?(cachebayJSON json: JSONValue) {
        guard let s = json.string else { return nil }
        self.init(s)
    }

    public var cachebayJSON: JSONValue { .string(rawValue) }
}
