import SwiftUI
import Cachebay

/// Detail reads via `watchFragment` on `Spell:<id>`. Any mutation that writes
/// the entity (including the create-path merge) propagates here via deps.
struct SpellDetailView: View {
    @EnvironmentObject private var store: AppStore
    let id: String

    @State private var spell: SpellData? = nil
    @State private var watcher: WatchFragmentHandle? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let spell {
                    Text(spell.name).font(.largeTitle).bold()
                    badge(spell.category, color: .accentColor)
                    if let creator = spell.creator { Text("Creator: \(creator)").font(.subheadline).foregroundStyle(.secondary) }
                    if let light = spell.light { badge(light, color: .yellow) }
                    Divider()
                    Text(spell.effect).font(.body)
                } else {
                    ProgressView()
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { subscribe() }
        .onDisappear { watcher?.unsubscribe(); watcher = nil }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { Task { await delete() } } label: { Image(systemName: "trash") }
            }
        }
    }

    private func subscribe() {
        let fragment = "fragment SpellFields on Spell { id name category creator effect light imageUrl wikiUrl }"
        // Kick a network fetch if we don't have it yet.
        Task {
            _ = try? await store.client.executeQuery(
                query: SpellDetail.networkQuery,
                variables: ["id": .string(id)],
                cachePolicy: .cacheFirst
            )
        }
        watcher = try? store.client.watchFragment(
            id: "Spell:\(id)",
            fragment: fragment,
            options: WatchFragmentOptions(
                immediate: true,
                onData: { data in Task { @MainActor in spell = SpellData.from(data) } }
            )
        )
    }

    private func delete() async {
        _ = try? await store.client.executeMutation(
            query: DeleteSpell.networkQuery,
            variables: ["input": .object(["id": .string(id)])]
        )
        // Remove the entity from cache so the list drops it on next read.
        let tx = store.client.modifyOptimistic { b in b.delete(.key("Spell:\(id)")) }
        tx.dispose()
    }

    @ViewBuilder private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.15)).foregroundColor(color).clipShape(Capsule())
    }
}

struct SpellData: Equatable, Sendable {
    var id: String
    var name: String
    var category: String
    var creator: String?
    var effect: String
    var light: String?
    var imageUrl: String?

    static func from(_ v: JSONValue) -> SpellData? {
        guard let id = v["id"]?.string else { return nil }
        return SpellData(
            id: id,
            name: v["name"]?.string ?? "",
            category: v["category"]?.string ?? "",
            creator: v["creator"]?.string,
            effect: v["effect"]?.string ?? "",
            light: v["light"]?.string,
            imageUrl: v["imageUrl"]?.string
        )
    }
}
