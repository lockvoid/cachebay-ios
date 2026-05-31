import SwiftUI
import Cachebay

/// Optimistic-add flow. The mutation is typed (`execute(mutation:)`); the
/// optimistic/connection writes use the imperative builder — mutations and
/// optimistic layering are inherently imperative (no declarative equivalent).
struct CreateSpellView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var category: String = "Charm"
    @State private var creator: String = ""
    @State private var effect: String = ""
    @State private var light: String = ""
    @State private var submitting = false

    var body: some View {
        Form {
            Section("Spell") {
                TextField("Name", text: $name)
                TextField("Category", text: $category)
                TextField("Creator (optional)", text: $creator)
                TextField("Effect", text: $effect, axis: .vertical).lineLimit(3...6)
                TextField("Light (optional)", text: $light)
            }
            Section {
                Button(submitting ? "Casting…" : "Cast Spell") { Task { await submit() } }
                    .disabled(submitting || name.isEmpty || effect.isEmpty)
            }
        }
        .navigationTitle("New Spell")
    }

    private func submit() async {
        submitting = true
        defer { submitting = false }

        let tempId = "temp:\(UUID().uuidString)"
        let optimisticNode: [String: JSONValue] = [
            "__typename": .string("Spell"),
            "id": .string(tempId),
            "name": .string(name),
            "category": .string(category),
            "creator": creator.isEmpty ? .null : .string(creator),
            "effect": .string(effect),
            "light": light.isEmpty ? .null : .string(light),
            "imageUrl": .null,
            "wikiUrl": .null,
        ]

        // Optimistic create: write the entity record FIRST, THEN link it into every
        // matching `Query.spells(...)` canonical (connection writes are structural-only).
        let tx = store.client.modifyOptimistic { b in
            b.patch(.key("Spell:\(tempId)"), optimisticNode, mode: .merge)
            for key in store.client.inspect.getConnectionKeys(parent: .root, key: "spells") {
                b.connection(key: key).linkNode(.key("Spell:\(tempId)"), options: LinkNodeOptions(position: .start))
            }
        }

        do {
            let input = CreateSpellInput(
                name: name,
                category: category,
                creator: creator.isEmpty ? nil : creator,
                effect: effect,
                light: light.isEmpty ? nil : light
            )
            let result = try await store.client.execute(mutation: CreateSpell.self, variables: .init(input: input))
            if let spell = result.data?.createSpell.spell {
                // The mutation response was normalized into the cache (Spell:realId is
                // already written). The commit just links the real id into the connections;
                // baseline restore drops the temp entity + its edges.
                let realId = spell.id
                tx.commit { b in
                    for key in store.client.inspect.getConnectionKeys(parent: .root, key: "spells") {
                        b.connection(key: key).linkNode(.key("Spell:\(realId)"), options: LinkNodeOptions(position: .start))
                    }
                }
                dismiss()
            } else {
                tx.revert()
            }
        } catch {
            tx.revert()
        }
    }
}
