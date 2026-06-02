import XCTest
@testable import Cachebay

/// Port of `cachebay-web/test/unit/core/utils.test.ts`.
///
/// `isObject` and `hasTypename` are JS-language helpers — Swift's
/// strongly-typed `JSONValue` makes both into trivial pattern matches,
/// so the tests here cover the equivalent Swift surface (`isEmptyObject`,
/// `isDataDeepEqual`, `stableStringify`, `encodeJSONString`,
/// `fingerprintNodes`, `recycleSnapshots`).
final class UtilsTests: XCTestCase {

    // MARK: - isEmptyObject

    func test_isEmptyObject_trueForEmptyObject() {
        XCTAssertTrue(isEmptyObject(.object([:])))
    }

    func test_isEmptyObject_falseForObjectWithProperties() {
        XCTAssertFalse(isEmptyObject(.object(["a": .int(1)])))
        XCTAssertFalse(isEmptyObject(.object(["__typename": .string("User")])))
    }

    func test_isEmptyObject_falseForNullAndPrimitives() {
        XCTAssertFalse(isEmptyObject(.null))
        XCTAssertFalse(isEmptyObject(.undefined))
        XCTAssertFalse(isEmptyObject(.int(42)))
        XCTAssertFalse(isEmptyObject(.string("")))
        XCTAssertFalse(isEmptyObject(.bool(true)))
        XCTAssertFalse(isEmptyObject(.bool(false)))
    }

    func test_isEmptyObject_falseForArrays() {
        XCTAssertFalse(isEmptyObject(.array([])))
        XCTAssertFalse(isEmptyObject(.array([.int(1)])))
    }

    // MARK: - isDataDeepEqual: primitives

    func test_isDataDeepEqual_primitives() {
        XCTAssertTrue(isDataDeepEqual(.int(42), .int(42)))
        XCTAssertTrue(isDataDeepEqual(.string("hello"), .string("hello")))
        XCTAssertTrue(isDataDeepEqual(.bool(true), .bool(true)))
        XCTAssertTrue(isDataDeepEqual(.null, .null))
        XCTAssertTrue(isDataDeepEqual(.undefined, .undefined))
    }

    func test_isDataDeepEqual_differentPrimitives() {
        XCTAssertFalse(isDataDeepEqual(.int(42), .int(43)))
        XCTAssertFalse(isDataDeepEqual(.string("hello"), .string("world")))
        XCTAssertFalse(isDataDeepEqual(.bool(true), .bool(false)))
    }

    func test_isDataDeepEqual_nullVsUndefined() {
        XCTAssertFalse(isDataDeepEqual(.null, .undefined))
        XCTAssertFalse(isDataDeepEqual(.undefined, .null))
    }

    func test_isDataDeepEqual_differentTypes() {
        XCTAssertFalse(isDataDeepEqual(.int(42), .string("42")))
        XCTAssertFalse(isDataDeepEqual(.int(0), .bool(false)))
        XCTAssertFalse(isDataDeepEqual(.string(""), .bool(false)))
    }

    // MARK: - isDataDeepEqual: refs

    func test_isDataDeepEqual_refsByValue() {
        XCTAssertTrue(isDataDeepEqual(.ref("User:1"), .ref("User:1")))
    }

    func test_isDataDeepEqual_differentRefs() {
        XCTAssertFalse(isDataDeepEqual(.ref("User:1"), .ref("User:2")))
    }

    func test_isDataDeepEqual_refLists() {
        XCTAssertTrue(isDataDeepEqual(
            .refList(["User:1", "User:2"]),
            .refList(["User:1", "User:2"])
        ))
    }

    func test_isDataDeepEqual_differentRefListContents() {
        XCTAssertFalse(isDataDeepEqual(
            .refList(["User:1", "User:2"]),
            .refList(["User:1", "User:3"])
        ))
    }

    func test_isDataDeepEqual_differentRefListLengths() {
        XCTAssertFalse(isDataDeepEqual(
            .refList(["User:1", "User:2"]),
            .refList(["User:1"])
        ))
    }

    // MARK: - isDataDeepEqual: arrays

    func test_isDataDeepEqual_arrays_recursive() {
        XCTAssertTrue(isDataDeepEqual(
            .array([.int(1), .int(2), .int(3)]),
            .array([.int(1), .int(2), .int(3)])
        ))
    }

    func test_isDataDeepEqual_differentArrayLengths() {
        XCTAssertFalse(isDataDeepEqual(
            .array([.int(1), .int(2)]),
            .array([.int(1), .int(2), .int(3)])
        ))
    }

    func test_isDataDeepEqual_differentArrayElements() {
        XCTAssertFalse(isDataDeepEqual(
            .array([.int(1), .int(2), .int(3)]),
            .array([.int(1), .int(2), .int(4)])
        ))
    }

    // MARK: - isDataDeepEqual: objects

    func test_isDataDeepEqual_plainObjects() {
        let a: JSONValue = .object(["name": .string("Alice"), "age": .int(30)])
        let b: JSONValue = .object(["name": .string("Alice"), "age": .int(30)])
        XCTAssertTrue(isDataDeepEqual(a, b))
    }

    func test_isDataDeepEqual_differentKeyCounts() {
        let a: JSONValue = .object(["name": .string("Alice"), "age": .int(30)])
        let b: JSONValue = .object(["name": .string("Alice")])
        XCTAssertFalse(isDataDeepEqual(a, b))
    }

    func test_isDataDeepEqual_differentValues() {
        let a: JSONValue = .object(["name": .string("Alice"), "age": .int(30)])
        let b: JSONValue = .object(["name": .string("Alice"), "age": .int(31)])
        XCTAssertFalse(isDataDeepEqual(a, b))
    }

    func test_isDataDeepEqual_nestedObjects() {
        let a: JSONValue = .object([
            "user": .object([
                "name": .string("Alice"),
                "posts": .array([.object(["id": .string("p1")])]),
            ])
        ])
        let b: JSONValue = .object([
            "user": .object([
                "name": .string("Alice"),
                "posts": .array([.object(["id": .string("p1")])]),
            ])
        ])
        XCTAssertTrue(isDataDeepEqual(a, b))
    }

    func test_isDataDeepEqual_normalizedCacheData() {
        let a: JSONValue = .object([
            "__typename": .string("Query"),
            "user": .ref("User:1"),
            "posts": .refList(["Post:1", "Post:2"]),
        ])
        let b: JSONValue = .object([
            "__typename": .string("Query"),
            "user": .ref("User:1"),
            "posts": .refList(["Post:1", "Post:2"]),
        ])
        XCTAssertTrue(isDataDeepEqual(a, b))
    }

    func test_isDataDeepEqual_detectsNestedDifferences() {
        let a: JSONValue = .object([
            "__typename": .string("Query"),
            "user": .ref("User:1"),
            "posts": .refList(["Post:1", "Post:2"]),
        ])
        let b: JSONValue = .object([
            "__typename": .string("Query"),
            "user": .ref("User:2"),
            "posts": .refList(["Post:1", "Post:2"]),
        ])
        XCTAssertFalse(isDataDeepEqual(a, b))
    }

    // MARK: - fingerprintNodes

    func test_fingerprintNodes_isStable() {
        let a = fingerprintNodes(100, [200, 300])
        let b = fingerprintNodes(100, [200, 300])
        XCTAssertEqual(a, b)
    }

    func test_fingerprintNodes_differentBaseDifferentResult() {
        XCTAssertNotEqual(
            fingerprintNodes(100, [200, 300]),
            fingerprintNodes(101, [200, 300])
        )
    }

    func test_fingerprintNodes_differentChildrenDifferentResult() {
        XCTAssertNotEqual(
            fingerprintNodes(100, [200, 300]),
            fingerprintNodes(100, [200, 301])
        )
    }

    func test_fingerprintNodes_orderDependent() {
        XCTAssertNotEqual(
            fingerprintNodes(100, [200, 300]),
            fingerprintNodes(100, [300, 200])
        )
    }

    func test_fingerprintNodes_emptyChildArray() {
        let a = fingerprintNodes(100, [])
        let b = fingerprintNodes(100, [])
        XCTAssertEqual(a, b)
    }

    func test_fingerprintNodes_baseZero() {
        XCTAssertEqual(
            fingerprintNodes(0, [100, 200, 300]),
            fingerprintNodes(0, [100, 200, 300])
        )
    }

    func test_fingerprintNodes_largeChildArrays() {
        let children: [UInt32] = (0..<100).map { UInt32($0) }
        let a = fingerprintNodes(42, children)
        let b = fingerprintNodes(42, children)
        XCTAssertEqual(a, b)
    }

    func test_fingerprintNodes_differentArrayLengths() {
        XCTAssertNotEqual(
            fingerprintNodes(100, [200, 300]),
            fingerprintNodes(100, [200, 300, 400])
        )
    }

    // MARK: - stableStringify

    func test_stableStringify_sortedKeys() {
        // Two semantically-equal objects with different insertion orders
        // must serialise to the same byte string.
        let a: JSONValue = .object(["b": .int(2), "a": .int(1)])
        let b: JSONValue = .object(["a": .int(1), "b": .int(2)])
        XCTAssertEqual(stableStringify(a), stableStringify(b))
        XCTAssertEqual(stableStringify(a), "{\"a\":1,\"b\":2}")
    }

    func test_stableStringify_nullAndUndefined() {
        XCTAssertEqual(stableStringify(.null), "null")
        XCTAssertEqual(stableStringify(.undefined), "null")
    }

    func test_stableStringify_booleans() {
        XCTAssertEqual(stableStringify(.bool(true)), "true")
        XCTAssertEqual(stableStringify(.bool(false)), "false")
    }

    func test_stableStringify_numbers() {
        XCTAssertEqual(stableStringify(.int(42)), "42")
        XCTAssertEqual(stableStringify(.int(0)), "0")
        // Integer-valued doubles render without decimal noise.
        XCTAssertEqual(stableStringify(.double(10)), "10")
    }

    func test_stableStringify_strings_escape() {
        XCTAssertEqual(stableStringify(.string("hello")), "\"hello\"")
        // Quote → \", backslash → \\.
        XCTAssertEqual(stableStringify(.string("a\"b")), "\"a\\\"b\"")
        XCTAssertEqual(stableStringify(.string("a\\b")), "\"a\\\\b\"")
        // Control codes get \n, \t, \r escapes.
        XCTAssertEqual(stableStringify(.string("a\nb")), "\"a\\nb\"")
        XCTAssertEqual(stableStringify(.string("a\tb")), "\"a\\tb\"")
    }

    func test_stableStringify_arraysAndNestedObjects() {
        let v: JSONValue = .object([
            "z": .array([.int(1), .int(2)]),
            "a": .object(["k": .string("v")]),
        ])
        XCTAssertEqual(stableStringify(v), "{\"a\":{\"k\":\"v\"},\"z\":[1,2]}")
    }

    func test_stableStringify_refs() {
        // `.ref` and `.refList` serialise to bare strings / string arrays,
        // matching the JS `__ref` / `__refs` carrier-stripping path.
        XCTAssertEqual(stableStringify(.ref("User:1")), "\"User:1\"")
        XCTAssertEqual(stableStringify(.refList(["User:1", "User:2"])), "[\"User:1\",\"User:2\"]")
    }

    // MARK: - encodeJSONString

    func test_encodeJSONString_basic() {
        XCTAssertEqual(encodeJSONString("hello"), "\"hello\"")
    }

    func test_encodeJSONString_specialChars() {
        XCTAssertEqual(encodeJSONString("\""), "\"\\\"\"")
        XCTAssertEqual(encodeJSONString("\\"), "\"\\\\\"")
        XCTAssertEqual(encodeJSONString("\n"), "\"\\n\"")
        XCTAssertEqual(encodeJSONString("\r"), "\"\\r\"")
        XCTAssertEqual(encodeJSONString("\t"), "\"\\t\"")
    }

    func test_encodeJSONString_lowControlCodes() {
        // 0x01 →  — non-graphical control codes get the unicode escape.
        let s = String(UnicodeScalar(0x01)!)
        XCTAssertEqual(encodeJSONString(s), "\"\\u0001\"")
    }

    // MARK: - recycleSnapshots: basic behaviour

    func test_recycleSnapshots_returnsPrev_whenDeepEqual() {
        let prev: JSONValue = .object(["__typename": .string("User"), "id": .string("u1"), "name": .string("Alice")])
        let next: JSONValue = .object(["__typename": .string("User"), "id": .string("u1"), "name": .string("Alice")])
        let result = recycleSnapshots(prev, next, .undefined, .undefined)
        // The current Swift implementation is fingerprint-driven: when prev
        // and next are deep-equal, prev wins.
        XCTAssertTrue(isDataDeepEqual(result, prev))
    }

    func test_recycleSnapshots_returnsPrev_whenFingerprintsMatch() {
        let prev: JSONValue = .object(["__typename": .string("User"), "id": .string("u1"), "name": .string("Alice")])
        let next: JSONValue = .object(["__typename": .string("User"), "id": .string("u1"), "name": .string("Alice")])
        let prevFp: JSONValue = .object([CachebayConstants.fingerprintKey: .int(123)])
        let nextFp: JSONValue = .object([CachebayConstants.fingerprintKey: .int(123)])
        let result = recycleSnapshots(prev, next, prevFp, nextFp)
        // When fingerprints match, the function must return `prev`.
        XCTAssertTrue(isDataDeepEqual(result, prev))
    }

    func test_recycleSnapshots_returnsNext_whenFingerprintsDiffer() {
        let prev: JSONValue = .object(["name": .string("Alice")])
        let next: JSONValue = .object(["name": .string("Bob")])
        let prevFp: JSONValue = .object([CachebayConstants.fingerprintKey: .int(123)])
        let nextFp: JSONValue = .object([CachebayConstants.fingerprintKey: .int(124)])
        let result = recycleSnapshots(prev, next, prevFp, nextFp)
        XCTAssertTrue(isDataDeepEqual(result, next))
    }

    func test_recycleSnapshots_handlesPrimitives() {
        XCTAssertEqual(recycleSnapshots(.int(42), .int(42), .undefined, .undefined), .int(42))
        XCTAssertEqual(recycleSnapshots(.string("hello"), .string("hello"), .undefined, .undefined), .string("hello"))
        XCTAssertEqual(recycleSnapshots(.bool(true), .bool(false), .undefined, .undefined), .bool(false))
        XCTAssertEqual(recycleSnapshots(.null, .null, .undefined, .undefined), .null)
    }

    // MARK: - recycleSnapshots array-item recycling (characterization for the
    //         O(n·m) → O(n+m) optimization; behavior must be preserved exactly).

    private func fp(_ v: Int64) -> JSONValue { .object([CachebayConstants.fingerprintKey: .int(v)]) }

    // Each next item whose fingerprint matches a prev item reuses the PREV
    // instance (content), placed in NEXT's order — even when reordered.
    func test_recycleArray_reusesPrevByFingerprint_inNextOrder() {
        let prev: JSONValue = .array([.object(["v": .string("A")]), .object(["v": .string("B")])])
        let next: JSONValue = .array([.object(["v": .string("B2")]), .object(["v": .string("A2")])])
        let prevFp: JSONValue = .array([fp(7), fp(8)])
        let nextFp: JSONValue = .array([fp(8), fp(7)])
        let result = recycleSnapshots(prev, next, prevFp, nextFp)
        // next[0] fp8 → prev[1]={B}; next[1] fp7 → prev[0]={A}
        XCTAssertEqual(result, .array([.object(["v": .string("B")]), .object(["v": .string("A")])]))
    }

    // A next item whose fingerprint isn't in prev uses the NEXT value.
    func test_recycleArray_usesNext_whenNoFingerprintMatch() {
        let prev: JSONValue = .array([.object(["v": .string("A")])])
        let next: JSONValue = .array([.object(["v": .string("A")]), .object(["v": .string("C")])])
        let prevFp: JSONValue = .array([fp(7)])
        let nextFp: JSONValue = .array([fp(7), fp(99)])
        let result = recycleSnapshots(prev, next, prevFp, nextFp)
        XCTAssertEqual(result, .array([.object(["v": .string("A")]), .object(["v": .string("C")])]))
    }

    // A next item with no fingerprint at all uses the NEXT value.
    func test_recycleArray_usesNext_whenNextItemHasNoFingerprint() {
        let prev: JSONValue = .array([.object(["v": .string("A")])])
        let next: JSONValue = .array([.object(["v": .string("Z")])])
        let prevFp: JSONValue = .array([fp(7)])
        let nextFp: JSONValue = .array([.object([:])])  // no __version
        let result = recycleSnapshots(prev, next, prevFp, nextFp)
        XCTAssertEqual(result, .array([.object(["v": .string("Z")])]))
    }

    // Duplicate prev fingerprints: the FIRST matching prev item wins (preserves
    // the original first-match `break`).
    func test_recycleArray_firstWins_onDuplicatePrevFingerprint() {
        let prev: JSONValue = .array([.object(["v": .string("A1")]), .object(["v": .string("A2")])])
        let next: JSONValue = .array([.object(["v": .string("X")])])
        let prevFp: JSONValue = .array([fp(7), fp(7)])
        let nextFp: JSONValue = .array([fp(7)])
        let result = recycleSnapshots(prev, next, prevFp, nextFp)
        XCTAssertEqual(result, .array([.object(["v": .string("A1")])]))
    }
}
