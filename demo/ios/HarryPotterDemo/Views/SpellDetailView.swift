import SwiftUI
import Cachebay

/// Detail reads via the typed `watchFragment` on `SpellFields` / `Spell:<id>`.
/// `spell` is the generated `SpellFields.Data` — no hand-written shadow struct,
/// no `JSONValue` prodding. Any mutation that writes the entity propagates here.
struct SpellDetailView: View {
    @EnvironmentObject private var store: AppStore
    let id: String

    @State private var spell: SpellFields.Data? = nil
    @State private var watcher: WatchFragmentHandle? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let spell {
                    Text(spell.name).font(.largeTitle).bold()
                    badge(spell.category, color: .accentColor)
                    if let creator = spell.creator {
                        Text("Creator: \(creator)").font(.subheadline).foregroundStyle(.secondary)
                    }
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
        // Kick a network fetch if we don't have it yet (cache-first).
        Task {
            _ = try? await store.client.execute(SpellDetail.self, variables: .init(id: id), cachePolicy: .cacheFirst)
        }
        watcher = try? store.client.watchFragment(fragment: SpellFields.self, id: id, immediate: true) { data in
            Task { @MainActor in spell = data }
        }
    }

    private func delete() async {
        _ = try? await store.client.execute(mutation: DeleteSpell.self, variables: .init(input: .init(id: id)))
        // Remove the entity from cache so the list drops it on next read.
        let tx = store.client.modifyOptimistic { b in b.delete(.key("Spell:\(id)")) }
        tx.dispose()
    }

    @ViewBuilder private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.15)).foregroundColor(color).clipShape(Capsule())
    }
}
