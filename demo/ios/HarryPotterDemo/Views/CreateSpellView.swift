import SwiftUI
import Cachebay

/// Optimistic-add flow: we prepend an entry to every matching
/// `Query.spells` connection, then run the mutation and either commit with
/// the server-assigned id or revert on failure.
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

        // Prepend an optimistic edge to every matching `Query.spells(...)` canonical.
        let tx = store.client.modifyOptimistic { b, _ in
            for key in store.client.inspect.getConnectionKeys(parent: .root, key: "spells") {
                let c = b.connection(key: key)
                c.addNode(optimisticNode, options: AddNodeOptions(position: .start))
            }
        }

        do {
            let input: [String: JSONValue] = [
                "name": .string(name),
                "category": .string(category),
                "creator": creator.isEmpty ? .null : .string(creator),
                "effect": .string(effect),
                "light": light.isEmpty ? .null : .string(light),
                "imageUrl": .null,
                "wikiUrl": .null,
            ]
            let result = try await store.client.executeMutation(
                query: CreateSpell.networkQuery,
                variables: ["input": .object(input)]
            )
            if let spell = result.data?["createSpell"]?["spell"]?.object,
               let realId = spell["id"]?.string {
                // Commit: drop the optimistic layer and rewrite it using the server id
                // so the new edge survives with the persisted Spell identity.
                tx.commit(.object(spell))
                // Also delete the stale temp entity.
                let cleanup = store.client.modifyOptimistic { b, _ in b.delete(.key("Spell:\(tempId)")) }
                cleanup.commit(nil)
                _ = realId
                dismiss()
            } else {
                tx.revert()
            }
        } catch {
            tx.revert()
        }
    }
}
