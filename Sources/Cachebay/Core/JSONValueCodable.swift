import Foundation

/// `Codable` for `JSONValue` — the persistence/interop path (distinct from the
/// cache's `CachebayValue` decode). Lets generated `@CachebayData` structs that
/// carry raw `JSONValue` (unmapped custom-scalar) fields round-trip through
/// `JSONEncoder`/`JSONDecoder`.
///
/// Note the inherent JSON int/double ambiguity: a `.double` with no fractional
/// part (e.g. `.double(100.0)`) re-decodes as `.int(100)` — concrete `Double`
/// fields are unaffected (they decode against `Double` directly), so this only
/// touches raw `JSONValue` fields. `.ref`/`.refList` encode to the `__ref`/
/// `__refs` sentinels for totality (they don't occur in materialized values).
extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        // Order matters: Bool before Int (so `true` isn't read as a number),
        // Int before Double (so whole numbers stay `.int`).
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unsupported JSON value")
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null, .undefined: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .ref(let r): try c.encode(["__ref": r])
        case .refList(let rs): try c.encode(["__refs": rs])
        }
    }
}
