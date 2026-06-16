import Foundation

public typealias CacheKey = String

/// Universal JSON-shaped value used throughout Cachebay for cached records,
/// materialized results, variables, and input data. Sendable and value-typed.
///
/// Extensions:
/// - `.ref(CacheKey)` — normalized link to another entity/page record.
/// - `.refList([CacheKey])` — normalized list of links (used for `edges.__refs`,
///   plain entity lists, and embedded connection edges).
/// - `.undefined` — distinct from `.null`, models JS `undefined` semantics.
///   Cache misses return `.undefined`; explicit JSON `null` values map to `.null`.
public indirect enum JSONValue: Hashable, Sendable {
    case null
    case undefined
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
    case ref(CacheKey)
    case refList([CacheKey])
}

public extension JSONValue {
    var isNull: Bool { if case .null = self { return true } else { return false } }
    var isUndefined: Bool { if case .undefined = self { return true } else { return false } }

    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var int: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 1e18: return Int64(d)
        default: return nil
        }
    }
    var double: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    var ref: CacheKey? { if case .ref(let r) = self { return r } else { return nil } }
    var refList: [CacheKey]? { if case .refList(let xs) = self { return xs } else { return nil } }

    /// Read a field on an object value.
    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

// MARK: - JSON encoding / decoding

public extension JSONValue {
    /// Parse from raw JSON bytes (e.g. server response body).
    /// `nil`/`undefined` in JSON maps to `.null`.
    ///
    /// Backed by yyjson (see `parseYYJSON`). Does not restore `__ref`/`__refs`
    /// sentinels — server payloads carry none; the normalized-store decode path
    /// opts in via `parseYYJSON(_:restoreRefs:)`.
    static func from(json data: Data) throws -> JSONValue {
        try parseYYJSON(data, restoreRefs: false)
    }

    /// Parse from a `JSONSerialization` result. Retained for consumers and for
    /// `toFoundation()` round-trips; the hot parse path is `from(json:)` (yyjson).
    static func from(any obj: Any) throws -> JSONValue {
        if obj is NSNull { return .null }
        if let n = obj as? NSNumber {
            // Distinguish Bool from other numbers
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            let stringValue = n.stringValue
            if stringValue.contains(".") || stringValue.contains("e") || stringValue.contains("E") {
                return .double(n.doubleValue)
            }
            return .int(n.int64Value)
        }
        if let s = obj as? String { return .string(s) }
        if let a = obj as? [Any] {
            var out: [JSONValue] = []
            out.reserveCapacity(a.count)
            for v in a { out.append(try from(any: v)) }
            return .array(out)
        }
        if let d = obj as? [String: Any] {
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(d.count)
            for (k, v) in d { out[k] = try from(any: v) }
            return .object(out)
        }
        throw CachebayError.invalidJSON("Unsupported type \(type(of: obj))")
    }

    /// Convert to a form acceptable by `JSONSerialization`.
    func toFoundation() -> Any {
        switch self {
        case .null, .undefined: return NSNull()
        case .bool(let b): return NSNumber(value: b)
        case .int(let i): return NSNumber(value: i)
        case .double(let d): return NSNumber(value: d)
        case .string(let s): return s
        case .array(let arr): return arr.map { $0.toFoundation() }
        case .object(let obj):
            var out: [String: Any] = [:]
            out.reserveCapacity(obj.count)
            for (k, v) in obj { out[k] = v.toFoundation() }
            return out
        case .ref(let r): return ["__ref": r]
        case .refList(let rs): return ["__refs": rs]
        }
    }

    /// Parse a JSON fragment at runtime. Used by codegen as a fallback for
    /// composite literal arguments (lists / nested objects) — scalars are
    /// emitted directly and never hit this path.
    static func parseLiteral(_ fragment: String) -> JSONValue {
        guard let data = fragment.data(using: .utf8),
            let value = try? JSONValue.from(json: data)
        else { return .null }
        return value
    }

    /// Serialize to JSON data (yyjson writer). Keys are emitted sorted, matching
    /// the prior `JSONSerialization` `.sortedKeys` behavior.
    func encodeJSON(pretty: Bool = false) throws -> Data {
        try encodeYYJSON(sortKeys: true, pretty: pretty)
    }
}

// MARK: - Dictionary literal / Array literal

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var d: [String: JSONValue] = [:]
        for (k, v) in elements { d[k] = v }
        self = .object(d)
    }
}
