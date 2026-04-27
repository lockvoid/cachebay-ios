import XCTest
@testable import Cachebay

/// Gap-fill port of `cachebay-web/test/unit/core/graph.test.ts`.
///
/// The existing `GraphTests` covers the high-level `identify` / `putRecord` /
/// `flush` flow. This file extends coverage to match the web suite's
/// `describe("changes", …)` / version-tracking / evictAll / flush
/// re-entrancy invariants.
final class GraphChangesTests: XCTestCase {

    private func makeGraph(onChange: GraphChangeHandler? = nil) -> Graph {
        Graph(options: GraphOptions(onChange: onChange))
    }

    // MARK: - String values

    func test_string_sameValue_doesNotEmit() {
        let count = CaptureBox<Int>(value: 0)
        let g = makeGraph { _ in count.withLock { $0 += 1 } }
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("John")])
        g.flush()
        XCTAssertEqual(count.value, 1)

        // Same string → no version bump → no change.
        g.putRecord("User:u1", ["name": .string("John")])
        g.flush()
        XCTAssertEqual(count.value, 1)
    }

    func test_string_change_emits() {
        let count = CaptureBox<Int>(value: 0)
        let g = makeGraph { _ in count.withLock { $0 += 1 } }
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("John")])
        g.flush()
        g.putRecord("User:u1", ["name": .string("Jane")])
        g.flush()
        XCTAssertEqual(count.value, 2)
    }

    // MARK: - Number values

    func test_number_sameValue_doesNotEmit() {
        let count = CaptureBox<Int>(value: 0)
        let g = makeGraph { _ in count.withLock { $0 += 1 } }
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "age": .int(25)])
        g.flush()
        g.putRecord("User:u1", ["age": .int(25)])
        g.flush()
        XCTAssertEqual(count.value, 1)
    }

    func test_zero_to_zero_doesNotEmit() {
        let count = CaptureBox<Int>(value: 0)
        let g = makeGraph { _ in count.withLock { $0 += 1 } }
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "count": .int(0)])
        g.flush()
        g.putRecord("User:u1", ["count": .int(0)])
        g.flush()
        XCTAssertEqual(count.value, 1)
    }

    // MARK: - Boolean values

    func test_bool_sameValue_doesNotEmit() {
        let count = CaptureBox<Int>(value: 0)
        let g = makeGraph { _ in count.withLock { $0 += 1 } }
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "active": .bool(true)])
        g.flush()
        g.putRecord("User:u1", ["active": .bool(true)])
        g.flush()
        XCTAssertEqual(count.value, 1)
    }

    func test_bool_change_emits() {
        let count = CaptureBox<Int>(value: 0)
        let g = makeGraph { _ in count.withLock { $0 += 1 } }
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "active": .bool(true)])
        g.flush()
        g.putRecord("User:u1", ["active": .bool(false)])
        g.flush()
        XCTAssertEqual(count.value, 2)
    }

    // MARK: - Null values

    func test_null_sameValue_doesNotEmit() {
        let count = CaptureBox<Int>(value: 0)
        let g = makeGraph { _ in count.withLock { $0 += 1 } }
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "email": .null])
        g.flush()
        g.putRecord("User:u1", ["email": .null])
        g.flush()
        XCTAssertEqual(count.value, 1)
    }

    func test_null_to_string_emits() {
        let count = CaptureBox<Int>(value: 0)
        let g = makeGraph { _ in count.withLock { $0 += 1 } }
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "email": .null])
        g.flush()
        g.putRecord("User:u1", ["email": .string("john@example.com")])
        g.flush()
        XCTAssertEqual(count.value, 2)
    }

    func test_string_to_null_emits() {
        let count = CaptureBox<Int>(value: 0)
        let g = makeGraph { _ in count.withLock { $0 += 1 } }
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "email": .string("x@y.z")])
        g.flush()
        g.putRecord("User:u1", ["email": .null])
        g.flush()
        XCTAssertEqual(count.value, 2)
    }

    // MARK: - Undefined values (no-op)

    func test_undefined_isNoOp() {
        let count = CaptureBox<Int>(value: 0)
        let g = makeGraph { _ in count.withLock { $0 += 1 } }
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("John")])
        g.flush()
        // `.undefined` removes the field if present; here `email` is
        // absent so no change.
        g.putRecord("User:u1", ["email": .undefined])
        g.flush()
        XCTAssertEqual(count.value, 1)
    }

    func test_undefined_removesExistingField() {
        let g = makeGraph()
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "email": .string("x@y.z")])
        XCTAssertEqual(g.getField("User:u1", "email")?.string, "x@y.z")
        g.putRecord("User:u1", ["email": .undefined])
        XCTAssertNil(g.getField("User:u1", "email"))
    }

    // MARK: - Object / array deep equality

    func test_object_sameStructure_doesNotEmit() {
        let count = CaptureBox<Int>(value: 0)
        let g = makeGraph { _ in count.withLock { $0 += 1 } }
        g.putRecord("User:u1", [
            "__typename": .string("User"),
            "id": .string("u1"),
            "address": .object(["city": .string("NYC"), "country": .string("USA")]),
        ])
        g.flush()
        g.putRecord("User:u1", [
            "address": .object(["city": .string("NYC"), "country": .string("USA")]),
        ])
        g.flush()
        XCTAssertEqual(count.value, 1)
    }

    func test_object_contentChange_emits() {
        let count = CaptureBox<Int>(value: 0)
        let g = makeGraph { _ in count.withLock { $0 += 1 } }
        g.putRecord("User:u1", [
            "__typename": .string("User"),
            "id": .string("u1"),
            "address": .object(["city": .string("NYC")]),
        ])
        g.flush()
        g.putRecord("User:u1", [
            "address": .object(["city": .string("LA")]),
        ])
        g.flush()
        XCTAssertEqual(count.value, 2)
    }

    func test_array_sameContent_doesNotEmit() {
        let count = CaptureBox<Int>(value: 0)
        let g = makeGraph { _ in count.withLock { $0 += 1 } }
        g.putRecord("User:u1", [
            "__typename": .string("User"),
            "id": .string("u1"),
            "tags": .array([.string("a"), .string("b")]),
        ])
        g.flush()
        g.putRecord("User:u1", ["tags": .array([.string("a"), .string("b")])])
        g.flush()
        XCTAssertEqual(count.value, 1)
    }

    func test_array_lengthChange_emits() {
        let count = CaptureBox<Int>(value: 0)
        let g = makeGraph { _ in count.withLock { $0 += 1 } }
        g.putRecord("User:u1", [
            "__typename": .string("User"),
            "id": .string("u1"),
            "tags": .array([.string("a")]),
        ])
        g.flush()
        g.putRecord("User:u1", ["tags": .array([.string("a"), .string("b")])])
        g.flush()
        XCTAssertEqual(count.value, 2)
    }

    // MARK: - Versioning

    func test_version_zero_for_nonExistingRecord() {
        let g = makeGraph()
        XCTAssertEqual(g.version("User:u1"), 0)
    }

    func test_version_one_after_first_write() {
        let g = makeGraph()
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("John")])
        XCTAssertEqual(g.version("User:u1"), 1)
    }

    func test_version_increments_on_each_update() {
        let g = makeGraph()
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("John")])
        XCTAssertEqual(g.version("User:u1"), 1)
        g.putRecord("User:u1", ["name": .string("Jane")])
        XCTAssertEqual(g.version("User:u1"), 2)
        g.putRecord("User:u1", ["email": .string("jane@example.com")])
        XCTAssertEqual(g.version("User:u1"), 3)
    }

    func test_version_doesNotIncrement_when_noChanges() {
        let g = makeGraph()
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("John")])
        let v1 = g.version("User:u1")
        g.putRecord("User:u1", ["name": .string("John")])
        XCTAssertEqual(g.version("User:u1"), v1)
    }

    func test_version_globalClock_perRecord() {
        let g = makeGraph()
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("John")])
        g.putRecord("User:u2", ["__typename": .string("User"), "id": .string("u2"), "name": .string("Jane")])
        // Global clock means u1 < u2 even though both are first writes.
        XCTAssertEqual(g.version("User:u1"), 1)
        XCTAssertEqual(g.version("User:u2"), 2)
        g.putRecord("User:u1", ["name": .string("John Updated")])
        XCTAssertEqual(g.version("User:u1"), 3)
        XCTAssertEqual(g.version("User:u2"), 2)
    }

    func test_version_resetsTo_zero_after_remove() {
        let g = makeGraph()
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("John")])
        g.putRecord("User:u1", ["name": .string("Jane")])
        XCTAssertEqual(g.version("User:u1"), 2)
        g.removeRecord("User:u1")
        XCTAssertEqual(g.version("User:u1"), 0)
    }

    // MARK: - keysList

    func test_keysList_listsAllRecordIds() {
        let g = makeGraph()
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("Ada")])
        g.putRecord("Post:p1", ["__typename": .string("Post"), "id": .string("p1"), "title": .string("T")])
        XCTAssertEqual(g.keysList().sorted(), ["Post:p1", "User:u1"])
    }

    // MARK: - evictAll

    func test_evictAll_clearsRecordsAndVersions() {
        let g = makeGraph()
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("Ada")])
        g.putRecord("Post:p1", ["__typename": .string("Post"), "id": .string("p1"), "title": .string("T")])
        XCTAssertEqual(g.version("User:u1"), 1)
        XCTAssertEqual(g.version("Post:p1"), 2)
        g.evictAll()
        XCTAssertEqual(g.keysList().count, 0)
        XCTAssertEqual(g.version("User:u1"), 0)
        XCTAssertEqual(g.version("Post:p1"), 0)
    }

    func test_evictAll_resetsClock() {
        let g = makeGraph()
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("Ada")])
        XCTAssertEqual(g.version("User:u1"), 1)
        g.evictAll()
        g.putRecord("User:u2", ["__typename": .string("User"), "id": .string("u2"), "name": .string("Bob")])
        XCTAssertEqual(g.version("User:u2"), 1)
    }

    func test_evictAll_identityStillWorks() {
        let g = makeGraph()
        _ = g.identify(["__typename": .string("User"), "id": .string("u1")])
        g.evictAll()
        XCTAssertEqual(g.identify(["__typename": .string("User"), "id": .string("u1")]), "User:u1")
    }

    // MARK: - onChange

    func test_onChange_notifiesListenerOnFlush() {
        let changes = CaptureBox<[Set<CacheKey>]>(value: [])
        let g = Graph(options: GraphOptions(onChange: { touched in
            changes.withLock { $0.append(touched) }
        }))
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("John")])
        g.flush()
        XCTAssertEqual(changes.value.count, 1)
        XCTAssertTrue(changes.value[0].contains("User:u1"))
    }

    func test_onChange_batchesMultipleChanges() {
        let changes = CaptureBox<[Set<CacheKey>]>(value: [])
        let g = Graph(options: GraphOptions(onChange: { touched in
            changes.withLock { $0.append(touched) }
        }))
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("John")])
        g.putRecord("User:u2", ["__typename": .string("User"), "id": .string("u2"), "name": .string("Jane")])
        g.putRecord("Post:p1", ["__typename": .string("Post"), "id": .string("p1"), "title": .string("T")])
        // No flush yet → no notifications.
        XCTAssertEqual(changes.value.count, 0)
        g.flush()
        XCTAssertEqual(changes.value.count, 1)
        XCTAssertEqual(changes.value[0], Set(["User:u1", "User:u2", "Post:p1"]))
    }

    func test_onChange_rootIDFanout_emitsFieldDeps() {
        let changes = CaptureBox<[Set<CacheKey>]>(value: [])
        let g = Graph(options: GraphOptions(onChange: { touched in
            changes.withLock { $0.append(touched) }
        }))
        g.putRecord(CachebayConstants.rootID, ["users": .ref("User:u1")])
        g.flush()
        XCTAssertEqual(changes.value.count, 1)
        XCTAssertTrue(changes.value[0].contains("@"))
        XCTAssertTrue(changes.value[0].contains("@.users"))
    }

    func test_onChange_notifiesOnRemove() {
        let changes = CaptureBox<[Set<CacheKey>]>(value: [])
        let g = Graph(options: GraphOptions(onChange: { touched in
            changes.withLock { $0.append(touched) }
        }))
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("John")])
        g.flush()
        changes.withLock { $0.removeAll() }
        g.removeRecord("User:u1")
        g.flush()
        XCTAssertEqual(changes.value.count, 1)
        XCTAssertEqual(changes.value[0], Set(["User:u1"]))
    }

    func test_onChange_notNotified_whenNoChanges() {
        let changes = CaptureBox<[Set<CacheKey>]>(value: [])
        let g = Graph(options: GraphOptions(onChange: { touched in
            changes.withLock { $0.append(touched) }
        }))
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("John")])
        g.flush()
        changes.withLock { $0.removeAll() }
        g.putRecord("User:u1", ["name": .string("John")])
        g.flush()
        XCTAssertEqual(changes.value.count, 0)
    }

    // MARK: - flush behaviour

    func test_flush_doesNothing_whenNoPending() {
        let changes = CaptureBox<[Set<CacheKey>]>(value: [])
        let g = Graph(options: GraphOptions(onChange: { touched in
            changes.withLock { $0.append(touched) }
        }))
        g.flush()
        XCTAssertEqual(changes.value.count, 0)
    }

    func test_flush_clearsPending_afterCall() {
        let changes = CaptureBox<[Set<CacheKey>]>(value: [])
        let g = Graph(options: GraphOptions(onChange: { touched in
            changes.withLock { $0.append(touched) }
        }))
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("John")])
        g.flush()
        XCTAssertEqual(changes.value.count, 1)
        g.flush()
        // Second flush is a no-op — pending was cleared.
        XCTAssertEqual(changes.value.count, 1)
    }

    func test_flush_callableManyTimes_safely() {
        let changes = CaptureBox<[Set<CacheKey>]>(value: [])
        let g = Graph(options: GraphOptions(onChange: { touched in
            changes.withLock { $0.append(touched) }
        }))
        g.flush()
        g.flush()
        g.flush()
        XCTAssertEqual(changes.value.count, 0)
    }

    func test_flush_allowsNewChanges_afterFlush() {
        let changes = CaptureBox<[Set<CacheKey>]>(value: [])
        let g = Graph(options: GraphOptions(onChange: { touched in
            changes.withLock { $0.append(touched) }
        }))
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("John")])
        g.flush()
        XCTAssertEqual(changes.value.count, 1)
        g.putRecord("User:u2", ["__typename": .string("User"), "id": .string("u2"), "name": .string("Jane")])
        g.flush()
        XCTAssertEqual(changes.value.count, 2)
        XCTAssertEqual(changes.value[1], Set(["User:u2"]))
    }

    func test_flush_reentrancy_suppressed() {
        // If the onChange handler triggers another `flush()` while the
        // outer flush is in flight, it must be suppressed (otherwise we
        // recurse on the same pending set).
        let g = Graph()
        let count = CaptureBox<Int>(value: 0)
        g.setOnChange { _ in
            count.withLock { $0 += 1 }
            // Re-entrant flush — should be a no-op.
            g.flush()
        }
        g.putRecord("User:u1", ["__typename": .string("User"), "id": .string("u1"), "name": .string("John")])
        g.flush()
        XCTAssertEqual(count.value, 1, "re-entrant flush must not re-fire onChange")
    }

    // MARK: - replaceRecord

    func test_replaceRecord_fullReplacesFields() {
        let g = makeGraph()
        g.putRecord("X:1", ["a": .string("1"), "b": .string("2"), "c": .string("3")])
        g.replaceRecord("X:1", ["a": .string("1"), "z": .string("9")])
        let rec = g.getRecord("X:1")
        XCTAssertEqual(rec?["a"]?.string, "1")
        XCTAssertNil(rec?["b"], "replaceRecord must drop fields not present in patch")
        XCTAssertNil(rec?["c"])
        XCTAssertEqual(rec?["z"]?.string, "9")
    }

    func test_replaceRecord_equalityShortCircuit_noVersionBump() {
        let g = makeGraph()
        g.putRecord("X:1", ["a": .string("1")])
        let v1 = g.version("X:1")
        g.replaceRecord("X:1", ["a": .string("1")])
        XCTAssertEqual(g.version("X:1"), v1, "equal replace must not bump version")
    }
}
