import SwiftUI
import Cachebay

/// Infinite-scrolling Relay connection with live search. Each keystroke bumps
/// variables (new canonical key → fresh results); scrolling to the bottom
/// appends the next page via `after` cursor.
struct SpellsListView: View {
    @EnvironmentObject private var store: AppStore
    @State private var search: String = ""
    @State private var rows: [SpellRow] = []
    @State private var endCursor: String? = nil
    @State private var hasNext: Bool = true
    @State private var totalCount: Int = 0
    @State private var isLoading = false
    @State private var watcher: WatchQueryHandle? = nil

    private var query: String { ListSpells.networkQuery }

    var body: some View {
        List {
            Section(header: Text(totalCount > 0 ? "\(totalCount) spells" : "Loading…")) {
                ForEach(rows) { row in
                    NavigationLink(destination: SpellDetailView(id: row.id)) {
                        SpellRowView(row: row)
                    }
                }
                if hasNext {
                    ProgressView().frame(maxWidth: .infinity, alignment: .center)
                        .onAppear { Task { await loadMore() } }
                }
            }
        }
        .searchable(text: $search, prompt: "Search spells")
        .onChange(of: search) { newValue in
            restart(searchText: newValue)
        }
        .task { restart(searchText: "") }
        .refreshable { restart(searchText: search) }
    }

    private func restart(searchText: String) {
        watcher?.unsubscribe()
        rows = []
        endCursor = nil
        hasNext = true
        totalCount = 0
        Task { await loadMore() }
        watcher = try? store.client.watchQuery(
            query: query,
            options: WatchQueryOptions(
                variables: makeVars(first: 20, after: nil, search: searchText),
                immediate: false,
                onData: { data in
                    Task { @MainActor in applyData(data) }
                }
            )
        )
    }

    private func loadMore() async {
        if isLoading || !hasNext { return }
        isLoading = true
        defer { isLoading = false }

        let vars = makeVars(first: 20, after: endCursor, search: search)
        do {
            let result = try await store.client.executeQuery(
                query: query,
                variables: vars,
                cachePolicy: endCursor == nil ? .cacheAndNetwork : .networkOnly
            )
            if let data = result.data {
                await MainActor.run { applyData(data) }
            }
        } catch {
            // surfaced via the watcher's onError in a richer demo; keeping quiet here.
        }
    }

    private func makeVars(first: Int, after: String?, search: String) -> [String: JSONValue] {
        var filter: [String: JSONValue] = [:]
        if !search.isEmpty { filter["query"] = .string(search) }
        var vars: [String: JSONValue] = [
            "first": .int(Int64(first)),
            "after": after.map(JSONValue.string) ?? .null,
        ]
        vars["filter"] = filter.isEmpty ? .null : .object(filter)
        return vars
    }

    private func applyData(_ data: JSONValue) {
        guard let posts = data["spells"]?.object else { return }
        totalCount = Int(posts["totalCount"]?.int ?? 0)
        let edges = posts["edges"]?.array ?? []
        let parsed: [SpellRow] = edges.compactMap { edge in
            guard let node = edge["node"]?.object,
                  let id = node["id"]?.string else { return nil }
            return SpellRow(
                id: id,
                name: node["name"]?.string ?? "",
                category: node["category"]?.string ?? "",
                creator: node["creator"]?.string,
                effect: node["effect"]?.string ?? "",
                light: node["light"]?.string,
                imageUrl: node["imageUrl"]?.string
            )
        }
        rows = parsed
        let pageInfo = posts["pageInfo"]?.object ?? [:]
        endCursor = pageInfo["endCursor"]?.string
        hasNext = pageInfo["hasNextPage"]?.bool ?? false
    }
}

struct SpellRow: Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let creator: String?
    let effect: String
    let light: String?
    let imageUrl: String?
}

struct SpellRowView: View {
    let row: SpellRow
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.name).font(.headline)
                Spacer()
                Text(row.category).font(.caption).foregroundStyle(.secondary)
            }
            Text(row.effect).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}
