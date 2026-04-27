import XCTest
@testable import Cachebay

final class GraphTests: XCTestCase {
    func test_default_identify_uses_id_field() {
        let g = Graph()
        XCTAssertEqual(g.identify(["__typename": "Post", "id": "p1"]), "Post:p1")
        XCTAssertEqual(g.identify(["__typename": "User", "id": 42]), "User:42")
    }

    func test_missing_id_returns_nil() {
        let g = Graph()
        XCTAssertNil(g.identify(["__typename": "Post"]))
        XCTAssertNil(g.identify(["id": "p1"]))
    }

    func test_custom_key_function() {
        let keys: [String: KeyFunction] = [
            "User": { _, obj in obj["email"]?.string }
        ]
        let g = Graph(options: GraphOptions(keys: keys))
        XCTAssertEqual(g.identify(["__typename": "User", "email": "a@b.c"]), "User:a@b.c")
    }

    func test_interface_identity_resolves_to_interface_name() {
        let g = Graph(options: GraphOptions(interfaces: [
            "Post": ["AudioPost", "VideoPost"]
        ]))
        XCTAssertEqual(g.identify(["__typename": "AudioPost", "id": "p1"]), "Post:p1")
        XCTAssertEqual(g.identify(["__typename": "VideoPost", "id": "p2"]), "Post:p2")
    }

    func test_get_implementers() {
        let g = Graph(options: GraphOptions(interfaces: [
            "Post": ["AudioPost", "VideoPost"]
        ]))
        XCTAssertEqual(g.getImplementers("Post"), Set(["AudioPost", "VideoPost"]))
        XCTAssertEqual(g.getImplementers("Other"), [])
    }

    func test_put_get_remove_with_onchange() {
        let received = CaptureBox<[Set<CacheKey>]>(value: [])
        let options = GraphOptions(onChange: { touched in
            received.lock.lock(); received.unsafeValue.append(touched); received.lock.unlock()
        })
        let g = Graph(options: options)
        g.putRecord("Post:p1", ["__typename": "Post", "id": "p1", "title": "Hello"])
        g.flush()
        XCTAssertEqual(received.value.count, 1)
        XCTAssertTrue(received.value[0].contains("Post:p1"))

        g.removeRecord("Post:p1")
        g.flush()
        XCTAssertEqual(received.value.count, 2)
        XCTAssertNil(g.getRecord("Post:p1"))
    }

    func test_putRecord_dedup_no_change() {
        let count = CaptureBox<Int>(value: 0)
        let g = Graph(options: GraphOptions(onChange: { _ in
            count.lock.lock(); count.unsafeValue += 1; count.lock.unlock()
        }))
        g.putRecord("X:1", ["a": "1"])
        g.flush()
        XCTAssertEqual(count.value, 1)
        // Same patch should be a no-op (hasChanges=false).
        g.putRecord("X:1", ["a": "1"])
        g.flush()
        XCTAssertEqual(count.value, 1)
    }

    func test_undefined_removes_field() {
        let g = Graph()
        g.putRecord("X:1", ["a": "1", "b": "2"])
        g.putRecord("X:1", ["b": .undefined])
        XCTAssertEqual(g.getRecord("X:1")?["a"]?.string, "1")
        XCTAssertNil(g.getRecord("X:1")?["b"])
    }

    func test_root_change_expands_to_field_deps() {
        let last = CaptureBox<Set<CacheKey>>(value: [])
        let g = Graph(options: GraphOptions(onChange: { touched in
            last.lock.lock(); last.unsafeValue = touched; last.lock.unlock()
        }))
        g.putRecord(CachebayConstants.rootID, ["posts": .ref("Post:1")])
        g.flush()
        XCTAssertTrue(last.value.contains("@"))
        XCTAssertTrue(last.value.contains("@.posts"))
    }
}
