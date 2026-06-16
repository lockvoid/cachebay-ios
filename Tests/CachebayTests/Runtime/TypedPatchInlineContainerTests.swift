import XCTest
@testable import Cachebay

/// Typed KeyPath patch (`b.patch(fragment:id:) { $0.set(\.field, value) }`) over
/// inline (id-less) container fields. The builder routes through `patchFragment`
/// (plan-aware normalize), so an inline-container value lands as `.ref(synthetic)` +
/// a synthetic container record — the shape the strict materializer requires.

@CachebayData(typename: "Project")
private struct ProjectFieldsData: Identifiable, Sendable, Hashable, CachebayValue {
    let __typename: String
    let id: String
    let title: String
    let settings: Settings

    @CachebayData(typename: "Settings")
    struct Settings: Sendable, Hashable, CachebayValue {
        let __typename: String
        let exportQuality: String
        let captionStyle: String
    }
}

private enum ProjectFields: CachebayFragment {
    typealias Data = ProjectFieldsData
    static let fragmentName = "ProjectFields"
    static let onTypename = "Project"
    static let document: QueryDocument = .source(
        """
        fragment ProjectFields on Project {
            __typename
            id
            title
            settings { __typename exportQuality captionStyle }
        }
        """)
    static var __cachebayFieldNames: [AnyKeyPath: String] { ProjectFieldsData.__cachebayFieldNames }
}

@CachebayData(typename: "Project")
private struct ProjectWithTagsData: Identifiable, Sendable, Hashable, CachebayValue {
    let __typename: String
    let id: String
    let tags: [Tag]

    @CachebayData(typename: "Tag")
    struct Tag: Sendable, Hashable, CachebayValue {
        let __typename: String
        let label: String
        let weight: Int
    }
}

private enum ProjectWithTagsFields: CachebayFragment {
    typealias Data = ProjectWithTagsData
    static let fragmentName = "ProjectWithTagsFields"
    static let onTypename = "Project"
    static let document: QueryDocument = .source(
        """
        fragment ProjectWithTagsFields on Project {
            __typename
            id
            tags { __typename label weight }
        }
        """)
    static var __cachebayFieldNames: [AnyKeyPath: String] { ProjectWithTagsData.__cachebayFieldNames }
}

final class TypedPatchInlineContainerTests: XCTestCase {
    private func makeClient() -> CachebayClient {
        CachebayClient(
            options: CachebayOptions(
                transport: Transport(http: MockHTTPTransport()),
                cachePolicy: .cacheFirst,
                suspensionTimeout: 0
            ))
    }

    private static func makeProjectData(exportQuality: String = "720p") -> ProjectFields.Data {
        ProjectFields.Data(id: "p1", title: "Demo", settings: .init(exportQuality: exportQuality, captionStyle: "default"))
    }

    // 1. writeFragment baseline normalizes the inline container into a synthetic record.
    func test_writeFragment_normalizesInlineContainer() {
        let client = makeClient()
        client.modifyOptimistic { b in
            b.writeFragment(fragment: ProjectFields.self, id: "p1", data: Self.makeProjectData())
        }
        XCTAssertEqual(client.graph.getRecord("Project:p1")?["title"], .string("Demo"))
        XCTAssertEqual(client.graph.getRecord("Project:p1")?["settings"], .ref("Project:p1.settings"))
        XCTAssertEqual(client.graph.getRecord("Project:p1.settings")?["exportQuality"], .string("720p"))

        let read = client.readFragment(fragment: ProjectFields.self, id: "p1")
        XCTAssertEqual(read?.settings.exportQuality, "720p")
    }

    // 2. Typed patch on an inline-container field produces the .ref shape (not .object).
    func test_typedPatch_inlineContainer_producesRefShape() {
        let client = makeClient()
        client.modifyOptimistic { b in
            b.writeFragment(fragment: ProjectFields.self, id: "p1", data: Self.makeProjectData())
        }
        client.modifyOptimistic { b in
            b.patch(fragment: ProjectFields.self, id: "p1") {
                $0.set(\.settings, .init(exportQuality: "1080p", captionStyle: "default"))
            }
        }
        XCTAssertEqual(
            client.graph.getRecord("Project:p1")?["settings"], .ref("Project:p1.settings"),
            "typed patch on an inline-container field must produce a .ref, not an embedded .object")
        XCTAssertEqual(client.graph.getRecord("Project:p1.settings")?["exportQuality"], .string("1080p"))
    }

    // 3. After the typed patch, a fragment read sees the new value (no watcher silence).
    func test_typedPatch_inlineContainer_isReadable() {
        let client = makeClient()
        client.modifyOptimistic { b in
            b.writeFragment(fragment: ProjectFields.self, id: "p1", data: Self.makeProjectData())
        }
        client.modifyOptimistic { b in
            b.patch(fragment: ProjectFields.self, id: "p1") {
                $0.set(\.settings, .init(exportQuality: "1080p", captionStyle: "default"))
            }
        }
        let read = client.readFragment(fragment: ProjectFields.self, id: "p1")
        XCTAssertEqual(read?.settings.exportQuality, "1080p", "new value must round-trip through materialize")
    }

    // 4. Revert restores the inline container's baseline at the synthetic key.
    func test_typedPatch_inlineContainer_revertRestoresBaseline() {
        let client = makeClient()
        client.modifyOptimistic { b in
            b.writeFragment(fragment: ProjectFields.self, id: "p1", data: Self.makeProjectData())
        }
        let tx = client.modifyOptimistic { b in
            b.patch(fragment: ProjectFields.self, id: "p1") {
                $0.set(\.settings, .init(exportQuality: "1080p", captionStyle: "default"))
            }
        }
        XCTAssertEqual(client.graph.getRecord("Project:p1.settings")?["exportQuality"], .string("1080p"))

        tx.revert()

        XCTAssertEqual(
            client.graph.getRecord("Project:p1.settings")?["exportQuality"], .string("720p"),
            "revert must restore the inline container's baseline")
        XCTAssertEqual(client.graph.getRecord("Project:p1")?["settings"], .ref("Project:p1.settings"))
    }

    // 5. A single patch touching a scalar AND an inline container — both apply.
    func test_typedPatch_mixedScalarAndInlineContainer_inOneDraft() {
        let client = makeClient()
        client.modifyOptimistic { b in
            b.writeFragment(fragment: ProjectFields.self, id: "p1", data: Self.makeProjectData())
        }
        client.modifyOptimistic { b in
            b.patch(fragment: ProjectFields.self, id: "p1") {
                $0.set(\.title, "Renamed")
                $0.set(\.settings, .init(exportQuality: "4K", captionStyle: "default"))
            }
        }
        XCTAssertEqual(client.graph.getRecord("Project:p1")?["title"], .string("Renamed"))
        XCTAssertEqual(client.graph.getRecord("Project:p1")?["settings"], .ref("Project:p1.settings"))
        XCTAssertEqual(client.graph.getRecord("Project:p1.settings")?["exportQuality"], .string("4K"))
    }

    // 6. mode: .replace drops parent fields not in the patch (typed writes complete
    //    container structs, so container-level partial-replace is N/A by design).
    func test_typedPatch_inlineContainer_replaceMode() {
        let client = makeClient()
        client.modifyOptimistic { b in
            b.writeFragment(fragment: ProjectFields.self, id: "p1", data: Self.makeProjectData())
        }
        client.modifyOptimistic { b in
            b.patch(fragment: ProjectFields.self, id: "p1", mode: .replace) {
                $0.set(\.settings, .init(exportQuality: "8K", captionStyle: "default"))
            }
        }
        let parent = client.graph.getRecord("Project:p1")
        XCTAssertEqual(parent?["settings"], .ref("Project:p1.settings"))
        XCTAssertNil(parent?["title"], "title not in the replace patch — replace must drop it from the parent")
        XCTAssertEqual(client.graph.getRecord("Project:p1.settings")?["exportQuality"], .string("8K"))
    }

    // 7. Inline-container LIST (id-less array) -> refList of synthetic keys.
    func test_typedPatch_inlineContainerList_producesRefListShape() {
        let client = makeClient()
        client.modifyOptimistic { b in
            b.writeFragment(
                fragment: ProjectWithTagsFields.self, id: "p1",
                data: .init(
                    id: "p1",
                    tags: [.init(label: "a", weight: 1), .init(label: "b", weight: 2)]
                ))
        }
        client.modifyOptimistic { b in
            b.patch(fragment: ProjectWithTagsFields.self, id: "p1") {
                $0.set(\.tags, [.init(label: "x", weight: 10), .init(label: "y", weight: 20), .init(label: "z", weight: 30)])
            }
        }
        guard case .refList(let refs)? = client.graph.getRecord("Project:p1")?["tags"] else {
            return XCTFail("tags must be a refList")
        }
        XCTAssertEqual(refs.count, 3)
        XCTAssertTrue(refs.allSatisfy { $0.hasPrefix("Project:p1.tags.") }, "synthetic keys must be parent-keyed: \(refs)")
        XCTAssertEqual(client.graph.getRecord(refs[0])?["label"], .string("x"))
        XCTAssertEqual(client.graph.getRecord(refs[2])?["label"], .string("z"))
    }
}
