import Foundation

/// FNV-1a 32-bit fingerprint combinator used by the materialize path.
/// Order-dependent. `baseNode` can be 0 for array-only fingerprints.
@inlinable
public func fingerprintNodes(_ baseNode: UInt32, _ children: [UInt32]) -> UInt32 {
    let FNV_SEED: UInt32 = 0x811c9dc5
    let FNV_PRIME: UInt32 = 16777619
    var h: UInt32 = (FNV_SEED ^ baseNode) &* FNV_PRIME
    for c in children { h = (h ^ c) &* FNV_PRIME }
    return h
}

/// Stable 32-bit FNV-1a hash for strings. Used by Planner.id and signatures.
@inlinable
public func fnv1a32(_ s: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for b in s.utf8 {
        h ^= UInt32(b)
        h = h &* 16777619
    }
    return h
}

/// Deep-equality tailored for cached records & materialized snapshots.
/// Handles the common fast paths: primitive equality, `.ref`, `.refList`.
public func isDataDeepEqual(_ a: JSONValue, _ b: JSONValue) -> Bool {
    switch (a, b) {
    case (.null, .null): return true
    case (.undefined, .undefined): return true
    case (.bool(let x), .bool(let y)): return x == y
    case (.int(let x), .int(let y)): return x == y
    case (.double(let x), .double(let y)): return x == y
    case (.int(let x), .double(let y)): return Double(x) == y
    case (.double(let x), .int(let y)): return x == Double(y)
    case (.string(let x), .string(let y)): return x == y
    case (.ref(let x), .ref(let y)): return x == y
    case (.refList(let x), .refList(let y)): return x == y
    case (.array(let x), .array(let y)):
        if x.count != y.count { return false }
        for i in 0..<x.count { if !isDataDeepEqual(x[i], y[i]) { return false } }
        return true
    case (.object(let x), .object(let y)):
        if x.count != y.count { return false }
        for (k, v) in x {
            guard let w = y[k] else { return false }
            if !isDataDeepEqual(v, w) { return false }
        }
        return true
    default: return false
    }
}

public func isEmptyObject(_ v: JSONValue) -> Bool {
    if case .object(let o) = v { return o.isEmpty }
    return false
}

/// Stable JSON.stringify with sorted keys — used by connection canonical keys.
/// Appends into a single buffer (no per-node intermediate `String`s from
/// `.map`/`.joined`/`+`); byte-for-byte identical to the prior formulation.
public func stableStringify(_ v: JSONValue) -> String {
    var out = ""
    out.reserveCapacity(32)
    appendStable(v, into: &out)
    return out
}

func appendStable(_ v: JSONValue, into out: inout String) {
    switch v {
    case .null, .undefined: out += "null"
    case .bool(let b): out += b ? "true" : "false"
    case .int(let i): out += String(i)
    case .double(let d):
        if d.rounded() == d && abs(d) < 1e18 { out += String(Int64(d)) } else { out += String(d) }
    case .string(let s): appendJSONString(s, into: &out)
    case .array(let xs):
        out += "["
        var first = true
        for x in xs {
            if !first { out += "," }
            first = false
            appendStable(x, into: &out)
        }
        out += "]"
    case .object(let o):
        out += "{"
        var first = true
        for k in o.keys.sorted() {
            if !first { out += "," }
            first = false
            appendJSONString(k, into: &out)
            out += ":"
            appendStable(o[k]!, into: &out)
        }
        out += "}"
    case .ref(let r): appendJSONString(r, into: &out)
    case .refList(let rs):
        out += "["
        var first = true
        for r in rs {
            if !first { out += "," }
            first = false
            appendJSONString(r, into: &out)
        }
        out += "]"
    }
}

@inlinable
public func encodeJSONString(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count + 2)
    appendJSONString(s, into: &out)
    return out
}

/// Appends the JSON-escaped, double-quoted form of `s` into `out`.
@usableFromInline
func appendJSONString(_ s: String, into out: inout String) {
    out += "\""
    for scalar in s.unicodeScalars {
        switch scalar.value {
        case 0x22: out += "\\\""
        case 0x5C: out += "\\\\"
        case 0x08: out += "\\b"
        case 0x0C: out += "\\f"
        case 0x0A: out += "\\n"
        case 0x0D: out += "\\r"
        case 0x09: out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.append(Character(scalar))
            }
        }
    }
    out += "\""
}

/// Recycle unchanged subtrees from `prev` into `next` using fingerprints.
/// Returns the `prev` instance when fingerprints match entirely.
public func recycleSnapshots(_ prev: JSONValue, _ next: JSONValue, _ prevFp: JSONValue, _ nextFp: JSONValue) -> JSONValue {
    if isDataDeepEqual(prev, next) { return prev }

    let prevVersion = prevFp[CachebayConstants.fingerprintKey]?.int
    let nextVersion = nextFp[CachebayConstants.fingerprintKey]?.int

    if let pv = prevVersion, let nv = nextVersion, pv == nv {
        return prev
    }

    switch (prev, next) {
    case (.array(let pa), .array(let na)):
        // Build a `fingerprint → prev instance` map once, then resolve each next
        // item in O(1) — O(n+m) instead of the prior O(n·m) per-item rescan.
        // First-wins insertion preserves the original "first matching prev item"
        // semantics (the old inner loop's `break`).
        var prevByFp: [Int64: JSONValue] = [:]
        if case .array(let prevArrFp) = prevFp {
            let count = min(pa.count, prevArrFp.count)
            prevByFp.reserveCapacity(count)
            for j in 0..<count {
                if let pv = prevArrFp[j][CachebayConstants.fingerprintKey]?.int, prevByFp[pv] == nil {
                    prevByFp[pv] = pa[j]
                }
            }
        }
        let nextArrFp: [JSONValue]? = { if case .array(let arrFp) = nextFp { return arrFp } else { return nil } }()
        var out: [JSONValue] = []
        out.reserveCapacity(na.count)
        for i in 0..<na.count {
            if let arrFp = nextArrFp, i < arrFp.count,
               let nv = arrFp[i][CachebayConstants.fingerprintKey]?.int,
               let matched = prevByFp[nv] {
                out.append(matched)   // recycle the unchanged prev instance
            } else {
                out.append(na[i])
            }
        }
        return .array(out)
    case (.object(let po), .object(let no)):
        var out: [String: JSONValue] = [:]
        out.reserveCapacity(no.count)
        for (k, v) in no {
            if k == CachebayConstants.fingerprintKey { out[k] = v; continue }
            let pv = po[k] ?? .undefined
            let pfp = prevFp[k] ?? .undefined
            let nfp = nextFp[k] ?? .undefined
            out[k] = recycleSnapshots(pv, v, pfp, nfp)
        }
        return .object(out)
    default:
        return next
    }
}
