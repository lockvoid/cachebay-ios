import XCTest
@testable import Cachebay

/// Repro for the bug: `b.patch(fragment:id:)` does not normalize inline
/// (id-less) sub-objects, so assigning `draft.<container> = ...` writes
/// `.object(...)` into the parent record where the strict materializer
/// requires `.ref(...)`. Watchers on the parent silence on the next
/// re-materialize with "unexpected link shape".
///
/// Compare with `OptimisticWriteFragmentTests` — `writeFragment(...)` IS
/// plan-aware (it goes through `documents.normalize`) and produces the
/// right shape. The typed `patch<F>` overload delegates to the raw JSON
/// `patch(_:_:mode:)` which calls `graph.putRecord` directly, skipping
/// the inline-container normalize pass entirely.
final class TypedPatchInlineContainerTests: XCTestCase {

    // MARK: - Fixtures

    /// Project-with-inline-Settings: settings is an inline (id-less)
    /// object with its own selection set. Mirrors the real-world
    /// `Project.settings` / `Project.poster` / `User.subscription`
    /// shape.
    struct ProjectFields: Cachebay.Fragment {
        static let networkQuery = """
        fragment ProjectFields on Project {
            __typename
            id
            title
            settings {
                __typename
                exportQuality
                captionStyle
            }
        }
        """
        static let document: QueryDocument = .source(networkQuery)
        static let fragmentName = "ProjectFields"
        static let onTypename = "Project"
        typealias Variables = Cachebay.EmptyVariables

        struct Data: Sendable, Cachebay.OperationData {
            var __data: [String: JSONValue]
            init(__data: [String: JSONValue]) { self.__data = __data }
        }
    }

    private func makeClient() -> CachebayClient {
        CachebayClient(options: CachebayOptions(
            transport: Transport(http: MockHTTPTransport()),
            cachePolicy: .cacheFirst,
            suspensionTimeout: 0
        ))
    }

    private static func makeProjectData(exportQuality: String = "720p") -> ProjectFields.Data {
        ProjectFields.Data(__data: [
            "__typename": .string("Project"),
            "id": .string("p1"),
            "title": .string("Demo"),
            "settings": .object([
                "__typename": .string("Settings"),
                "exportQuality": .string(exportQuality),
                "captionStyle": .string("default"),
            ]),
        ])
    }

    // MARK: - 1. Baseline: writeFragment correctly normalizes inline containers

    /// Establishes that the inline-container shape lands correctly via
    /// `writeFragment` (the working path). This is the contract the
    /// strict materializer expects.
    func test_writeFragment_normalizesInlineContainer() {
        let client = makeClient()
        client.modifyOptimistic { b in
            b.writeFragment(fragment: ProjectFields.self, id: "p1", data: Self.makeProjectData())
        }
        let parent = client.graph.getRecord("Project:p1")
        XCTAssertEqual(parent?["title"], .string("Demo"))
        XCTAssertEqual(parent?["settings"], .ref("Project:p1.settings"),
            "writeFragment must produce .ref to a synthetic container record")

        let container = client.graph.getRecord("Project:p1.settings")
        XCTAssertEqual(container?["exportQuality"], .string("720p"))
        XCTAssertEqual(container?["captionStyle"], .string("default"))

        // And materialize round-trips.
        let read = client.readFragment(fragment: ProjectFields.self, id: "p1", variables: .init())
        XCTAssertNotNil(read, "writeFragment-seeded entity should be readable")
        if case .object(let s)? = read?.__data["settings"] {
            XCTAssertEqual(s["exportQuality"], .string("720p"))
        } else {
            XCTFail("settings must materialize as a nested object, got \(String(describing: read?.__data["settings"]))")
        }
    }

    // MARK: - 2. Bug: typed patch writes .object into the inline-container slot

    /// **THIS IS THE BUG.** A typed `b.patch(fragment:id:) { draft.settings = ... }`
    /// must produce the same on-disk shape as `writeFragment` —
    /// `Project:p1` field `settings` should be `.ref("Project:p1.settings")`
    /// and the inline contents at the synthetic container key.
    ///
    /// Today it writes `.object(...)` directly into the parent record,
    /// which the strict materializer rejects.
    func test_typedPatch_inlineContainer_producesRefShape() {
        let client = makeClient()
        // Seed with writeFragment so the baseline is correct.
        client.modifyOptimistic { b in
            b.writeFragment(fragment: ProjectFields.self, id: "p1", data: Self.makeProjectData(exportQuality: "720p"))
        }

        // Optimistically patch settings via the typed surface — the
        // generated setter writes `.object(child.__data)` into __data.
        client.modifyOptimistic { b in
            b.patch(fragment: ProjectFields.self, id: "p1") { draft in
                draft.__data["settings"] = .object([
                    "__typename": .string("Settings"),
                    "exportQuality": .string("1080p"),
                    "captionStyle": .string("default"),
                ])
            }
        }

        let parent = client.graph.getRecord("Project:p1")
        XCTAssertEqual(parent?["settings"], .ref("Project:p1.settings"),
            "typed patch on an inline-container field must produce a .ref to the synthetic container, not an embedded .object — strict materializer rejects .object here")

        let container = client.graph.getRecord("Project:p1.settings")
        XCTAssertEqual(container?["exportQuality"], .string("1080p"),
            "inline contents must land at the synthetic container key")
    }

    // MARK: - 3. Bug consequence: materialize silences watcher

    /// Even more concrete: after the typed patch, a watching read must
    /// see the new `exportQuality`. If the bug bites, the materializer
    /// hits the `default` branch ("unexpected link shape") and surfaces
    /// `.undefined`, so the typed read returns nil or a stale value.
    func test_typedPatch_inlineContainer_isReadable() {
        let client = makeClient()
        client.modifyOptimistic { b in
            b.writeFragment(fragment: ProjectFields.self, id: "p1", data: Self.makeProjectData(exportQuality: "720p"))
        }

        client.modifyOptimistic { b in
            b.patch(fragment: ProjectFields.self, id: "p1") { draft in
                draft.__data["settings"] = .object([
                    "__typename": .string("Settings"),
                    "exportQuality": .string("1080p"),
                    "captionStyle": .string("default"),
                ])
            }
        }

        let read = client.readFragment(fragment: ProjectFields.self, id: "p1", variables: .init())
        XCTAssertNotNil(read, "fragment read must not silence on inline-container typed patch")
        guard case .object(let s)? = read?.__data["settings"] else {
            XCTFail("settings must materialize as an object, got \(String(describing: read?.__data["settings"]))")
            return
        }
        XCTAssertEqual(s["exportQuality"], .string("1080p"),
            "new exportQuality must round-trip through materialize")
    }

    // MARK: - 4. Revert restores the pre-existing inline-container baseline

    /// After a typed-patch overwrites an inline container, `tx.revert()`
    /// must restore the pre-existing value at the synthetic key — not
    /// leave the optimistic value behind, not blow the record away.
    func test_typedPatch_inlineContainer_revertRestoresBaseline() {
        let client = makeClient()
        client.modifyOptimistic { b in
            b.writeFragment(fragment: ProjectFields.self, id: "p1", data: Self.makeProjectData(exportQuality: "720p"))
        }

        let tx = client.modifyOptimistic { b in
            b.patch(fragment: ProjectFields.self, id: "p1") { draft in
                draft.__data["settings"] = .object([
                    "__typename": .string("Settings"),
                    "exportQuality": .string("1080p"),
                    "captionStyle": .string("default"),
                ])
            }
        }
        // Sanity: optimistic state visible.
        XCTAssertEqual(
            client.graph.getRecord("Project:p1.settings")?["exportQuality"],
            .string("1080p"),
            "optimistic state should be live before revert"
        )

        tx.revert()

        XCTAssertEqual(
            client.graph.getRecord("Project:p1.settings")?["exportQuality"],
            .string("720p"),
            "revert must restore the inline container's baseline — the synthetic key must NOT be left holding the optimistic value"
        )
        XCTAssertEqual(
            client.graph.getRecord("Project:p1")?["settings"],
            .ref("Project:p1.settings"),
            "parent's link must still point at the synthetic container after revert"
        )
    }

    // MARK: - 5. Mixed scalar + inline-container patch in one draft

    /// A single typed patch can touch both a scalar AND an inline
    /// container. Both writes must apply correctly — scalar goes onto
    /// the parent record, inline container produces the ref + synthetic
    /// shape.
    func test_typedPatch_mixedScalarAndInlineContainer_inOneDraft() {
        let client = makeClient()
        client.modifyOptimistic { b in
            b.writeFragment(fragment: ProjectFields.self, id: "p1", data: Self.makeProjectData(exportQuality: "720p"))
        }

        client.modifyOptimistic { b in
            b.patch(fragment: ProjectFields.self, id: "p1") { draft in
                draft.__data["title"] = .string("Renamed")
                draft.__data["settings"] = .object([
                    "__typename": .string("Settings"),
                    "exportQuality": .string("4K"),
                    "captionStyle": .string("default"),
                ])
            }
        }

        let parent = client.graph.getRecord("Project:p1")
        XCTAssertEqual(parent?["title"], .string("Renamed"),
            "scalar field must land on the parent record")
        XCTAssertEqual(parent?["settings"], .ref("Project:p1.settings"),
            "inline-container field must be a ref to the synthetic container")
        XCTAssertEqual(
            client.graph.getRecord("Project:p1.settings")?["exportQuality"],
            .string("4K"),
            "inline contents must land at the synthetic key"
        )
    }

    // MARK: - 6. mode: .replace on inline-container honours the consumer's intent

    /// `mode: .replace` says "drop fields not in the patch on the
    /// touched record." For an inline-container field assignment, that
    /// applies to BOTH layers: parent gets only the fields in the
    /// patch (other parent fields like `title` are dropped), and the
    /// container itself gets only the inline values in the patch.
    func test_typedPatch_inlineContainer_replaceMode() {
        let client = makeClient()
        client.modifyOptimistic { b in
            b.writeFragment(fragment: ProjectFields.self, id: "p1", data: Self.makeProjectData(exportQuality: "720p"))
        }
        // Sanity: baseline has both title and settings.
        XCTAssertEqual(client.graph.getRecord("Project:p1")?["title"], .string("Demo"))
        XCTAssertEqual(
            client.graph.getRecord("Project:p1.settings")?["captionStyle"],
            .string("default")
        )

        client.modifyOptimistic { b in
            b.patch(fragment: ProjectFields.self, id: "p1", mode: .replace) { draft in
                draft.__data["settings"] = .object([
                    "__typename": .string("Settings"),
                    "exportQuality": .string("8K"),
                    // intentionally omit captionStyle to verify replace
                ])
            }
        }

        let parent = client.graph.getRecord("Project:p1")
        XCTAssertEqual(parent?["settings"], .ref("Project:p1.settings"),
            "parent must still link to the synthetic container under replace")
        XCTAssertNil(parent?["title"],
            "title was not in the replace patch — replace must drop it from the parent record")

        let container = client.graph.getRecord("Project:p1.settings")
        XCTAssertEqual(container?["exportQuality"], .string("8K"),
            "replace must write the new exportQuality")
        XCTAssertNil(container?["captionStyle"],
            "captionStyle was not in the replace patch — replace must drop it from the container record")
    }

    // MARK: - 7. Inline-container LIST (id-less array)

    /// Lists of inline (id-less) objects must produce a refList of
    /// synthetic keys (`parent.fieldName.0`, `parent.fieldName.1`, …)
    /// — same shape as normalize produces for response trees with
    /// id-less arrays. Today the typed patch writes
    /// `.array([.object(...), ...])` directly into the parent, which
    /// the strict materializer rejects identically to the single
    /// inline-container case.
    func test_typedPatch_inlineContainerList_producesRefListShape() throws {
        // Fragment with an inline-container list. Mirrors a real-world
        // case like `Project.tags { label, weight }` where tags don't
        // have their own id.
        struct ProjectWithTagsFields: Cachebay.Fragment {
            static let networkQuery = """
            fragment ProjectWithTagsFields on Project {
                __typename
                id
                tags {
                    __typename
                    label
                    weight
                }
            }
            """
            static let document: QueryDocument = .source(networkQuery)
            static let fragmentName = "ProjectWithTagsFields"
            static let onTypename = "Project"
            typealias Variables = Cachebay.EmptyVariables

            struct Data: Sendable, Cachebay.OperationData {
                var __data: [String: JSONValue]
                init(__data: [String: JSONValue]) { self.__data = __data }
            }
        }

        let client = makeClient()
        client.modifyOptimistic { b in
            b.writeFragment(fragment: ProjectWithTagsFields.self, id: "p1", data: .init(__data: [
                "__typename": .string("Project"),
                "id": .string("p1"),
                "tags": .array([
                    .object(["__typename": .string("Tag"), "label": .string("a"), "weight": .int(1)]),
                    .object(["__typename": .string("Tag"), "label": .string("b"), "weight": .int(2)]),
                ]),
            ]))
        }

        // Patch the tags list via typed surface.
        client.modifyOptimistic { b in
            b.patch(fragment: ProjectWithTagsFields.self, id: "p1") { draft in
                draft.__data["tags"] = .array([
                    .object(["__typename": .string("Tag"), "label": .string("x"), "weight": .int(10)]),
                    .object(["__typename": .string("Tag"), "label": .string("y"), "weight": .int(20)]),
                    .object(["__typename": .string("Tag"), "label": .string("z"), "weight": .int(30)]),
                ])
            }
        }

        // Parent must hold a refList of synthetic keys, not an embedded
        // array of objects.
        let parent = client.graph.getRecord("Project:p1")
        guard case .refList(let refs)? = parent?["tags"] else {
            XCTFail("tags must be a refList; got \(String(describing: parent?["tags"]))")
            return
        }
        XCTAssertEqual(refs.count, 3, "refList length must match the new array length")
        XCTAssertTrue(refs.allSatisfy { $0.hasPrefix("Project:p1.tags.") },
            "synthetic keys must be parent-keyed: got \(refs)")

        // Each element record must hold the inline contents.
        XCTAssertEqual(client.graph.getRecord(refs[0])?["label"], .string("x"))
        XCTAssertEqual(client.graph.getRecord(refs[1])?["label"], .string("y"))
        XCTAssertEqual(client.graph.getRecord(refs[2])?["label"], .string("z"))
    }
}
