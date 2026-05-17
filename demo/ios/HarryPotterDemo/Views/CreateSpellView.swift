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

        // Optimistic create: write the entity record FIRST (so watchers can
        // materialize it), THEN link it into every matching `Query.spells(...)`
        // canonical. Connection mutations (`linkNode`/`unlinkNode`) are
        // structural-only — they manage edge refs but never write entity
        // scalars. Entity records are owned by `documents.normalize` (auto
        // from server responses) or explicit `b.patch`/`b.writeFragment`.
        let tx = store.client.modifyOptimistic { b in
            b.patch(.key("Spell:\(tempId)"), optimisticNode, mode: .merge)
            for key in store.client.inspect.getConnectionKeys(parent: .root, key: "spells") {
                let c = b.connection(key: key)
                c.linkNode(.key("Spell:\(tempId)"), options: LinkNodeOptions(position: .start))
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
                // Commit closure captures `spell` (the server-authored
                // Spell record) and `realId` from outer scope. Baseline
                // restore drops Post:tempId AND its edges; the commit
                // closure writes the real entity + links it.
                tx.commit { b in
                    b.patch(.key("Spell:\(realId)"), spell, mode: .merge)
                    for key in store.client.inspect.getConnectionKeys(parent: .root, key: "spells") {
                        b.connection(key: key).linkNode(
                            .key("Spell:\(realId)"),
                            options: LinkNodeOptions(position: .start)
                        )
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
