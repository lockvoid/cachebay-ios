// TEMP perf spike: Foundation JSONDecoder vs. JSONSerialization vs. yyjson.
//
// Run:  swift run -c release YYBench
//
// Parses the same synthetic JSON payload three ways into the same Swift value
// (an array of `Record`), so the comparison is apples-to-apples on the work
// Cachebay actually does on the materialize/parse path: turn bytes into typed
// Swift values. JSONSerialization is the fair DOM baseline for yyjson; the
// JSONDecoder column is what we ship today.

import Foundation
import yyjson
import Cachebay

struct Record: Codable {
    let id: String
    let name: String
    let count: Int
    let score: Double
    let active: Bool
    let tags: [String]
}

func makeJSON(_ n: Int) -> Data {
    let recs = (0..<n).map { i in
        Record(
            id: "id-\(i)",
            name: "Record number \(i) — a longer, more representative descriptive name",
            count: i,
            score: Double(i) * 1.5,
            active: i % 2 == 0,
            tags: ["tag\(i % 10)", "category-\(i % 5)", "kind-stable"]
        )
    }
    return try! JSONEncoder().encode(recs)
}

// MARK: - Three decode strategies (each returns the record count it produced)

func decodeFoundation(_ data: Data) -> Int {
    // Fresh decoder per call; creation cost is negligible vs. decoding 50k records.
    (try? JSONDecoder().decode([Record].self, from: data))?.count ?? -1
}

func decodeJSONSerialization(_ data: Data) -> Int {
    guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return -1 }
    var out: [Record] = []
    out.reserveCapacity(arr.count)
    for o in arr {
        out.append(Record(
            id: o["id"] as? String ?? "",
            name: o["name"] as? String ?? "",
            count: o["count"] as? Int ?? 0,
            score: o["score"] as? Double ?? 0,
            active: o["active"] as? Bool ?? false,
            tags: o["tags"] as? [String] ?? []
        ))
    }
    return out.count
}

@inline(__always)
func yyStr(_ v: UnsafeMutablePointer<yyjson_val>?) -> String {
    guard let p = yyjson_get_str(v) else { return "" }
    return String(cString: p)
}

func decodeYYJSON(_ data: Data) -> Int {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
        guard let base = raw.baseAddress else { return -1 }
        let cptr = base.assumingMemoryBound(to: CChar.self)
        guard let doc = yyjson_read(cptr, raw.count, 0) else { return -1 }
        defer { yyjson_doc_free(doc) }
        guard let root = yyjson_doc_get_root(doc) else { return -1 }

        var out: [Record] = []
        out.reserveCapacity(yyjson_arr_size(root))
        var it = yyjson_arr_iter()
        yyjson_arr_iter_init(root, &it)
        while let obj = yyjson_arr_iter_next(&it) {
            let id = yyStr(yyjson_obj_get(obj, "id"))
            let name = yyStr(yyjson_obj_get(obj, "name"))
            let count = Int(yyjson_get_sint(yyjson_obj_get(obj, "count")))
            let score = yyjson_get_real(yyjson_obj_get(obj, "score"))
            let active = yyjson_get_bool(yyjson_obj_get(obj, "active"))
            var tags: [String] = []
            if let arr = yyjson_obj_get(obj, "tags") {
                tags.reserveCapacity(yyjson_arr_size(arr))
                var ti = yyjson_arr_iter()
                yyjson_arr_iter_init(arr, &ti)
                while let t = yyjson_arr_iter_next(&ti) { tags.append(yyStr(t)) }
            }
            out.append(Record(id: id, name: name, count: count, score: score, active: active, tags: tags))
        }
        return out.count
    }
}

// MARK: - Timing harness

func ms(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) * 1000.0 + Double(c.attoseconds) / 1e15
}

func bench(_ label: String, iters: Int, bytes: Int, _ body: () -> Int) {
    _ = body() // warmup (filesystem/codepaths/JIT-of-nothing, just steady-state)
    let clock = ContinuousClock()
    var best = Duration.seconds(1 << 30)
    var sum = Duration.zero
    var produced = 0
    for _ in 0..<iters {
        let d = clock.measure { produced = body() }
        best = min(best, d)
        sum += d
    }
    let bestMs = ms(best)
    let avgMs = ms(sum / iters)
    let mbps = (Double(bytes) / (1024 * 1024)) / (bestMs / 1000.0)
    let padded = label.padding(toLength: 24, withPad: " ", startingAt: 0)
    let nums = String(format: "best %8.3f ms   avg %8.3f ms   %7.1f MB/s", bestMs, avgMs, mbps)
    print("\(padded)\(nums)   count=\(produced)")
}

// MARK: - Baseline: JSONValue.from(json:) parse scaling (Phase 2)

/// A representative GraphQL-ish entity array of `n` records.
func makeRecordArrayJSON(_ n: Int) -> Data {
    var objs: [String] = []
    objs.reserveCapacity(n)
    for i in 0..<n {
        objs.append(#"""
        {"__typename":"User","id":"User:\#(i)","name":"User Number \#(i)","email":"user\#(i)@example.com","age":\#(i % 90),"score":\#(Double(i) * 0.5),"active":\#(i % 2 == 0),"tags":["alpha","beta","gamma"],"bio":"A reasonably long biography string for record \#(i), to keep the payload representative of real responses."}
        """#)
    }
    return Data(("[" + objs.joined(separator: ",") + "]").utf8)
}

func benchScale(_ label: String, iters: Int, bytes: Int, records: Int, _ body: () -> Int) {
    _ = body() // warmup
    let clock = ContinuousClock()
    var best = Duration.seconds(1 << 30)
    var produced = 0
    for _ in 0..<iters {
        let d = clock.measure { produced = body() }
        best = min(best, d)
    }
    let bestMs = ms(best)
    let mbps = (Double(bytes) / (1024 * 1024)) / (bestMs / 1000.0)
    let nsPerRec = (bestMs * 1_000_000.0) / Double(records)
    let padded = label.padding(toLength: 22, withPad: " ", startingAt: 0)
    print(padded + String(format: "best %9.4f ms   %7.1f MB/s   %8.1f ns/record   (n=%d, %d B)", bestMs, mbps, nsPerRec, produced, bytes))
}

func runParseBaseline() {
    print("=== BASELINE: JSONValue.from(json:) parse scaling (yyjson-backed) ===")
    for n in [10, 100, 1000] {
        let data = makeRecordArrayJSON(n)
        benchScale("from(json:) n=\(n)", iters: 500, bytes: data.count, records: n) {
            if case .array(let a)? = try? JSONValue.from(json: data) { return a.count }
            return -1
        }
    }
    print("")
}

func benchOps(_ label: String, iters: Int, units: Int, _ body: () -> Int) {
    _ = body() // warmup
    let clock = ContinuousClock()
    var best = Duration.seconds(1 << 30)
    var produced = 0
    for _ in 0..<iters {
        let d = clock.measure { produced = body() }
        best = min(best, d)
    }
    let bestMs = ms(best)
    let nsPer = (bestMs * 1_000_000.0) / Double(units)
    print(label.padding(toLength: 22, withPad: " ", startingAt: 0)
        + String(format: "best %9.4f ms   %10.1f ns/item   (n=%d)", bestMs, nsPer, produced))
}

/// Worst case for the recycle matcher: `next` is `prev` reordered (reversed) with
/// changed content but identical per-item fingerprints — every next item must be
/// matched against the prev set.
func makeRecycleArrays(_ n: Int) -> (JSONValue, JSONValue, JSONValue, JSONValue) {
    var prev: [JSONValue] = [], next: [JSONValue] = [], pFp: [JSONValue] = [], nFp: [JSONValue] = []
    prev.reserveCapacity(n); next.reserveCapacity(n); pFp.reserveCapacity(n); nFp.reserveCapacity(n)
    for i in 0..<n {
        prev.append(.object(["id": .string("Item:\(i)"), "v": .int(Int64(i))]))
        pFp.append(.object([CachebayConstants.fingerprintKey: .int(Int64(i))]))
    }
    for i in stride(from: n - 1, through: 0, by: -1) {
        next.append(.object(["id": .string("Item:\(i)"), "v": .int(Int64(i + 1_000_000))]))
        nFp.append(.object([CachebayConstants.fingerprintKey: .int(Int64(i))]))
    }
    return (.array(prev), .array(next), .array(pFp), .array(nFp))
}

func runRecycleBaseline() {
    print("=== recycleSnapshots scaling (reordered list, all fingerprints match) ===")
    for n in [10, 100, 1000] {
        let (p, nx, pf, nf) = makeRecycleArrays(n)
        benchOps("recycle n=\(n)", iters: 500, units: n) {
            if case .array(let a) = recycleSnapshots(p, nx, pf, nf) { return a.count }
            return -1
        }
    }
    print("")
}

func makeRecordArrayJSONValue(_ n: Int) -> JSONValue {
    var arr: [JSONValue] = []
    arr.reserveCapacity(n)
    for i in 0..<n {
        arr.append(.object([
            "__typename": .string("User"),
            "id": .string("User:\(i)"),
            "name": .string("User Number \(i)"),
            "age": .int(Int64(i % 90)),
            "score": .double(Double(i) * 0.5),
            "active": .bool(i % 2 == 0),
            "tags": .array([.string("alpha"), .string("beta"), .string("gamma")]),
        ]))
    }
    return .array(arr)
}

func runStableStringifyBaseline() {
    print("=== stableStringify scaling (array of n objects, sorted keys) ===")
    for n in [10, 100, 1000] {
        let jv = makeRecordArrayJSONValue(n)
        benchOps("stableStringify n=\(n)", iters: 500, units: n) { stableStringify(jv).count }
    }
    print("")
}

// MARK: - Run

runParseBaseline()
runRecycleBaseline()
runStableStringifyBaseline()

let N = 50_000
let iters = 30
let data = makeJSON(N)

print("yyjson vs Foundation — parse \(N) records into [Record]")
print(String(format: "Payload: %d bytes (%.2f MB)   iterations: %d (best + avg)\n", data.count, Double(data.count) / 1024 / 1024, iters))

bench("JSONDecoder", iters: iters, bytes: data.count) { decodeFoundation(data) }
bench("JSONSerialization+map", iters: iters, bytes: data.count) { decodeJSONSerialization(data) }
bench("yyjson (DOM->struct)", iters: iters, bytes: data.count) { decodeYYJSON(data) }

// Correctness: all three must agree on the count.
let counts = [decodeFoundation(data), decodeJSONSerialization(data), decodeYYJSON(data)]
print("\nCorrectness — counts: \(counts)  \(counts.allSatisfy { $0 == N } ? "✅ all agree" : "❌ MISMATCH")")

// =====================================================================
// Record-decode path — mirrors SQLiteStorage.decodeRecord (the warm-up
// hydration hot path). OLD = JSONSerialization + build tree + separate
// restoreRefs walk (3 passes). NEW = one yyjson pass with inline
// __ref/__refs recognition (what parseYYJSONRecord now does).
// =====================================================================

// Minimal stand-in for the JSONValue cases that matter to this path.
indirect enum RV {
    case str(String), num, bool, null
    case object([String: RV]), array([RV])
    case ref(String), refList([String])
}

func countRefs(_ v: RV) -> Int {
    switch v {
    case .ref: return 1
    case .refList(let r): return r.count
    case .object(let o): return o.values.reduce(0) { $0 + countRefs($1) }
    case .array(let a): return a.reduce(0) { $0 + countRefs($1) }
    default: return 0
    }
}

func makeStoreBlobs(_ n: Int) -> [Data] {
    (0..<n).map { i in
        Data("""
        {"__typename":"Cook","id":"Cook:\(i)","title":"Recipe number \(i)","rating":\(Double(i) * 0.5),"active":\(i % 2 == 0),
         "hero":{"__ref":"VideoElement:v\(i)"},
         "tags":{"__refs":["Tag:\(i % 5)","Tag:\(i % 7)","Tag:\(i % 3)"]},
         "meta":{"views":\(i),"pinned":\(i % 3 == 0)}}
        """.utf8)
    }
}

// OLD: JSONSerialization → build RV (mirrors from(any:)) → restore (2nd walk).
func buildFromAny(_ o: Any) -> RV {
    if o is NSNull { return .null }
    if let n = o as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool : .num }
    if let s = o as? String { return .str(s) }
    if let a = o as? [Any] { return .array(a.map(buildFromAny)) }
    if let d = o as? [String: Any] {
        var out: [String: RV] = [:]; out.reserveCapacity(d.count)
        for (k, v) in d { out[k] = buildFromAny(v) }
        return .object(out)
    }
    return .null
}
func restore(_ v: RV) -> RV {
    switch v {
    case .object(let o):
        if o.count == 1, case .str(let r)? = o["__ref"] { return .ref(r) }
        if o.count == 1, case .array(let xs)? = o["__refs"] {
            let all = xs.compactMap { if case .str(let s) = $0 { return s } else { return nil } }
            if all.count == xs.count { return .refList(all) }
        }
        var out: [String: RV] = [:]; out.reserveCapacity(o.count)
        for (k, sub) in o { out[k] = restore(sub) }
        return .object(out)
    case .array(let a): return .array(a.map(restore))
    default: return v
    }
}
func decodeRecordOld(_ d: Data) -> Int {
    guard let any = try? JSONSerialization.jsonObject(with: d) else { return -1 }
    return countRefs(restore(buildFromAny(any)))
}

// NEW: one yyjson pass with inline sentinel recognition (== parseYYJSONRecord).
func convertRV(_ val: UnsafeMutablePointer<yyjson_val>?) -> RV {
    guard let val else { return .null }
    if yyjson_is_str(val) { return .str(yyStr(val)) }
    if yyjson_is_obj(val) {
        if yyjson_obj_size(val) == 1 {
            if let r = yyjson_obj_get(val, "__ref"), yyjson_is_str(r) { return .ref(yyStr(r)) }
            if let rs = yyjson_obj_get(val, "__refs"), yyjson_is_arr(rs) {
                var all: [String] = []; var ok = true
                var ai = yyjson_arr_iter(); yyjson_arr_iter_init(rs, &ai)
                while let e = yyjson_arr_iter_next(&ai) {
                    if yyjson_is_str(e) { all.append(yyStr(e)) } else { ok = false; break }
                }
                if ok { return .refList(all) }
            }
        }
        var out: [String: RV] = [:]; out.reserveCapacity(yyjson_obj_size(val))
        var it = yyjson_obj_iter(); yyjson_obj_iter_init(val, &it)
        while let k = yyjson_obj_iter_next(&it) { out[yyStr(k)] = convertRV(yyjson_obj_iter_get_val(k)) }
        return .object(out)
    }
    if yyjson_is_arr(val) {
        var out: [RV] = []; out.reserveCapacity(yyjson_arr_size(val))
        var it = yyjson_arr_iter(); yyjson_arr_iter_init(val, &it)
        while let e = yyjson_arr_iter_next(&it) { out.append(convertRV(e)) }
        return .array(out)
    }
    if yyjson_is_bool(val) { return .bool }
    if yyjson_is_null(val) { return .null }
    return .num
}
func decodeRecordNew(_ d: Data) -> Int {
    d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
        guard let base = raw.baseAddress,
              let doc = yyjson_read(base.assumingMemoryBound(to: CChar.self), raw.count, 0) else { return -1 }
        defer { yyjson_doc_free(doc) }
        return countRefs(convertRV(yyjson_doc_get_root(doc)))
    }
}

let blobs = makeStoreBlobs(20_000)
let blobBytes = blobs.reduce(0) { $0 + $1.count }
print("\n--- Record-decode path (mirrors decodeRecord; __ref-laden blobs) ---")
print(String(format: "%d record blobs, %d bytes (%.2f MB)\n", blobs.count, blobBytes, Double(blobBytes) / 1024 / 1024))
bench("OLD JSONSer+restore", iters: iters, bytes: blobBytes) { var c = 0; for b in blobs { c += decodeRecordOld(b) }; return c }
bench("NEW yyjson 1-pass",  iters: iters, bytes: blobBytes) { var c = 0; for b in blobs { c += decodeRecordNew(b) }; return c }

let oldRefs = blobs.reduce(0) { $0 + decodeRecordOld($1) }
let newRefs = blobs.reduce(0) { $0 + decodeRecordNew($1) }
print("\nCorrectness — refs restored: old=\(oldRefs) new=\(newRefs)  \(oldRefs == newRefs ? "✅ agree" : "❌ MISMATCH")")
