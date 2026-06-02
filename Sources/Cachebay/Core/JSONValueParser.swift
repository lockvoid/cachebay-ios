import Foundation
import yyjson

// yyjson-backed JSON → JSONValue parser (Phase 1). Replaces the
// `JSONSerialization` + `from(any:)` path: one pass over yyjson's arena DOM, no
// intermediate NSDictionary tree. Two wins over the old path:
//   • ~10× faster parse (yyjson vs JSONSerialization), and
//   • correct number typing for free — yyjson knows int-vs-real from the literal,
//     so `100.0` decodes to `.double` (the old NSNumber `.stringValue.contains(".")`
//     heuristic misclassified `100.0` as `.int`).
//
// The `restoreRefs` flag fuses normalized-store sentinel recognition
// (`{"__ref": …}` / `{"__refs": […]}`) into the *same* walk, so the storage
// hydration path no longer needs a separate `restoreRefs` tree pass.
extension JSONValue {
    /// Parse raw JSON bytes into a `JSONValue`.
    /// - Parameter restoreRefs: when `true`, single-key `{"__ref": s}` objects
    ///   decode to `.ref(s)` and `{"__refs": [s…]}` to `.refList`, recursively —
    ///   the normalized-store encoding. Network/response parsing uses `false`.
    static func parseYYJSON(_ data: Data, restoreRefs: Bool) throws -> JSONValue {
        if data.isEmpty { throw CachebayError.invalidJSON("empty JSON data") }
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> JSONValue in
            guard let base = raw.baseAddress else {
                throw CachebayError.invalidJSON("empty JSON data")
            }
            let cptr = base.assumingMemoryBound(to: CChar.self)
            guard let doc = yyjson_read(cptr, raw.count, 0) else {
                throw CachebayError.invalidJSON("malformed JSON")
            }
            defer { yyjson_doc_free(doc) }
            return convertYYJSON(yyjson_doc_get_root(doc), restoreRefs: restoreRefs)
        }
    }

    /// Decode a persisted store record (always a JSON object) in one pass, with
    /// `__ref`/`__refs` sentinels restored in the field *values*. The root dict
    /// itself is never collapsed to a ref (a record is an entity's fields, never a
    /// bare reference) — matching the old `decodeRecord` + `restoreRefs` semantics,
    /// minus the two extra tree walks.
    static func parseYYJSONRecord(_ data: Data) throws -> [String: JSONValue] {
        if data.isEmpty { throw CachebayError.invalidJSON("empty record data") }
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [String: JSONValue] in
            guard let base = raw.baseAddress else {
                throw CachebayError.invalidJSON("empty record data")
            }
            let cptr = base.assumingMemoryBound(to: CChar.self)
            guard let doc = yyjson_read(cptr, raw.count, 0) else {
                throw CachebayError.invalidJSON("malformed record JSON")
            }
            defer { yyjson_doc_free(doc) }
            guard let root = yyjson_doc_get_root(doc), yyjson_is_obj(root) else {
                throw CachebayError.invalidJSON("record is not a JSON object")
            }
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(yyjson_obj_size(root))
            var it = yyjson_obj_iter()
            yyjson_obj_iter_init(root, &it)
            while let key = yyjson_obj_iter_next(&it) {
                let name = yyjson_get_str(key).map { String(cString: $0) } ?? ""
                out[name] = convertYYJSON(yyjson_obj_iter_get_val(key), restoreRefs: true)
            }
            return out
        }
    }

    /// Recursively convert a yyjson value into a `JSONValue`. Type dispatch uses
    /// the `yyjson_is_*` inline checkers (not the macro-defined type constants,
    /// which the Swift importer doesn't surface).
    private static func convertYYJSON(
        _ val: UnsafeMutablePointer<yyjson_val>?,
        restoreRefs: Bool
    ) -> JSONValue {
        guard let val else { return .null }

        if yyjson_is_str(val) {
            guard let p = yyjson_get_str(val) else { return .string("") }
            return .string(String(cString: p))
        }
        if yyjson_is_obj(val) {
            if restoreRefs, yyjson_obj_size(val) == 1 {
                if let r = yyjson_obj_get(val, "__ref"), yyjson_is_str(r), let p = yyjson_get_str(r) {
                    return .ref(String(cString: p))
                }
                if let rs = yyjson_obj_get(val, "__refs"), yyjson_is_arr(rs),
                   let refs = stringArray(rs) {
                    return .refList(refs)
                }
                // Single-key object that isn't a sentinel: fall through to a
                // normal object build below.
            }
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(yyjson_obj_size(val))
            var it = yyjson_obj_iter()
            yyjson_obj_iter_init(val, &it)
            while let key = yyjson_obj_iter_next(&it) {
                let name = yyjson_get_str(key).map { String(cString: $0) } ?? ""
                out[name] = convertYYJSON(yyjson_obj_iter_get_val(key), restoreRefs: restoreRefs)
            }
            return .object(out)
        }
        if yyjson_is_arr(val) {
            var out: [JSONValue] = []
            out.reserveCapacity(yyjson_arr_size(val))
            var it = yyjson_arr_iter()
            yyjson_arr_iter_init(val, &it)
            while let e = yyjson_arr_iter_next(&it) {
                out.append(convertYYJSON(e, restoreRefs: restoreRefs))
            }
            return .array(out)
        }
        if yyjson_is_bool(val) { return .bool(yyjson_get_bool(val)) }
        // Number subtypes are distinct: yyjson tags an integer literal as UINT
        // (non-negative) or SINT, and a literal with `.`/exponent as REAL.
        if yyjson_is_uint(val) {
            let u = yyjson_get_uint(val)
            return u <= UInt64(Int64.max) ? .int(Int64(u)) : .double(Double(u))
        }
        if yyjson_is_sint(val) { return .int(yyjson_get_sint(val)) }
        if yyjson_is_real(val) { return .double(yyjson_get_real(val)) }
        // null and any unhandled type.
        return .null
    }

    /// Returns the array's elements as `[CacheKey]` iff *every* element is a
    /// string; otherwise `nil` so the caller keeps it as a normal `.array`.
    private static func stringArray(_ arr: UnsafeMutablePointer<yyjson_val>) -> [CacheKey]? {
        var out: [CacheKey] = []
        out.reserveCapacity(yyjson_arr_size(arr))
        var it = yyjson_arr_iter()
        yyjson_arr_iter_init(arr, &it)
        while let e = yyjson_arr_iter_next(&it) {
            guard yyjson_is_str(e), let p = yyjson_get_str(e) else { return nil }
            out.append(String(cString: p))
        }
        return out
    }

    // MARK: - Encode (yyjson mutable-doc writer)

    /// Serialize to JSON bytes via yyjson. `.ref`/`.refList` are written back as
    /// the `{"__ref": …}` / `{"__refs": […]}` sentinels (mirroring `toFoundation`).
    /// - Parameters:
    ///   - sortKeys: emit object keys in sorted order (deterministic output).
    ///   - pretty: pretty-print (indented).
    func encodeYYJSON(sortKeys: Bool, pretty: Bool) throws -> Data {
        guard let doc = yyjson_mut_doc_new(nil) else {
            throw CachebayError.invalidJSON("yyjson: mutable-doc allocation failed")
        }
        defer { yyjson_mut_doc_free(doc) }
        yyjson_mut_doc_set_root(doc, Self.buildMut(self, doc, sortKeys: sortKeys))
        var len = 0
        let flag: yyjson_write_flag = pretty ? YYJSON_WRITE_PRETTY : YYJSON_WRITE_NOFLAG
        guard let cstr = yyjson_mut_write(doc, flag, &len) else {
            throw CachebayError.invalidJSON("yyjson: write failed")
        }
        defer { free(cstr) }
        return Data(bytes: cstr, count: len)
    }

    /// Build a yyjson mutable value mirroring this `JSONValue`. Strings are copied
    /// into the doc arena (`strcpy`), so transient Swift `String` bridges are safe.
    private static func buildMut(
        _ v: JSONValue,
        _ doc: UnsafeMutablePointer<yyjson_mut_doc>,
        sortKeys: Bool
    ) -> UnsafeMutablePointer<yyjson_mut_val>? {
        switch v {
        case .null, .undefined:
            return yyjson_mut_null(doc)
        case .bool(let b):
            return yyjson_mut_bool(doc, b)
        case .int(let i):
            return yyjson_mut_sint(doc, i)
        case .double(let d):
            return yyjson_mut_real(doc, d)
        case .string(let s):
            return yyjson_mut_strcpy(doc, s)
        case .array(let arr):
            let a = yyjson_mut_arr(doc)
            for e in arr { yyjson_mut_arr_add_val(a, buildMut(e, doc, sortKeys: sortKeys)) }
            return a
        case .object(let obj):
            let o = yyjson_mut_obj(doc)
            let keys = sortKeys ? obj.keys.sorted() : Array(obj.keys)
            for k in keys {
                yyjson_mut_obj_add(o, yyjson_mut_strcpy(doc, k), buildMut(obj[k]!, doc, sortKeys: sortKeys))
            }
            return o
        case .ref(let r):
            let o = yyjson_mut_obj(doc)
            yyjson_mut_obj_add(o, yyjson_mut_strcpy(doc, "__ref"), yyjson_mut_strcpy(doc, r))
            return o
        case .refList(let rs):
            let o = yyjson_mut_obj(doc)
            let a = yyjson_mut_arr(doc)
            for r in rs { yyjson_mut_arr_add_val(a, yyjson_mut_strcpy(doc, r)) }
            yyjson_mut_obj_add(o, yyjson_mut_strcpy(doc, "__refs"), a)
            return o
        }
    }
}
