import SwiftUI
import Cachebay
import CachebayUI

// The list, two ways — same query, same live cache. Flip the segment and the data
// is identical; an optimistic create in another screen updates BOTH instantly.
// Declarative = @CachebayQuery; Imperative = client.watch. Both render the generated
// typed structs (ListSpells.Data) — no hand-written shadow rows, no JSONValue prodding.

private typealias SpellsConnection = ListSpells.Data.Spells
private typealias SpellNode = ListSpells.Data.Spells.Edges.Node

private enum ListStyle: String, CaseIterable {
    case declarative = "Declarative"
    case imperative = "Imperative"
}

struct SpellsListView: View {
    @State private var search: String = ""
    @State private var style: ListStyle = .declarative

    var body: some View {
        VStack(spacing: 0) {
            Picker("Style", selection: $style) {
                ForEach(ListStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top], 12)

            switch style {
            case .declarative: DeclarativeSpellsList(search: search)
            case .imperative:  ImperativeSpellsList(search: search)
            }
        }
        .searchable(text: $search, prompt: "Search spells")
    }
}

// MARK: - Declarative (@CachebayQuery)

private struct DeclarativeSpellsList: View {
    @EnvironmentObject private var store: AppStore
    let search: String

    // Variables are dynamic (the search filter), so override the wrapper in init —
    // the @FetchRequest pattern. @CachebayQuery watches; the .task fires the fetch.
    @CachebayQuery(ListSpells.self, variables: .init(first: 20)) private var query

    init(search: String) {
        self.search = search
        let filter: GraphQLNullable<SpellFilter> = search.isEmpty ? nil : .some(SpellFilter(query: .some(search)))
        _query = CachebayQuery(ListSpells.self, variables: .init(first: 20, after: nil, filter: filter))
    }

    var body: some View {
        SpellsListContent(spells: query.data?.spells) { after in
            Task { await fetch(after: after) }
        }
        .task(id: search) { await fetch(after: nil) }
    }

    private func fetch(after: String?) async {
        let filter: GraphQLNullable<SpellFilter> = search.isEmpty ? nil : .some(SpellFilter(query: .some(search)))
        _ = try? await store.client.execute(
            ListSpells.self,
            variables: .init(first: 20, after: GraphQLNullable(after), filter: filter),
            cachePolicy: after == nil ? .cacheAndNetwork : .networkOnly
        )
    }
}

// MARK: - Imperative (client.watch)

private struct ImperativeSpellsList: View {
    @EnvironmentObject private var store: AppStore
    let search: String

    @State private var data: ListSpells.Data? = nil
    @State private var watcher: WatchQueryHandle? = nil

    private var filter: GraphQLNullable<SpellFilter> { search.isEmpty ? nil : .some(SpellFilter(query: .some(search))) }

    var body: some View {
        SpellsListContent(spells: data?.spells) { after in
            Task { await fetch(after: after) }
        }
        .task(id: search) { restart() }
        .onDisappear { watcher?.unsubscribe(); watcher = nil }
    }

    private func restart() {
        watcher?.unsubscribe()
        data = nil
        watcher = try? store.client.watch(
            ListSpells.self,
            variables: .init(first: 20, after: nil, filter: filter),
            immediate: true
        ) { d in
            Task { @MainActor in data = d }
        }
        Task { await fetch(after: nil) }
    }

    private func fetch(after: String?) async {
        _ = try? await store.client.execute(
            ListSpells.self,
            variables: .init(first: 20, after: GraphQLNullable(after), filter: filter),
            cachePolicy: after == nil ? .cacheAndNetwork : .networkOnly
        )
    }
}

// MARK: - Shared content

private struct SpellsListContent: View {
    let spells: SpellsConnection?
    let onLoadMore: (_ after: String?) -> Void

    var body: some View {
        if let spells {
            List {
                Section(header: Text("\(spells.totalCount) spells")) {
                    ForEach(spells.edges, id: \.node.id) { edge in
                        NavigationLink(destination: SpellDetailView(id: edge.node.id)) {
                            SpellRowView(node: edge.node)
                        }
                    }
                    if spells.pageInfo.hasNextPage {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .onAppear { onLoadMore(spells.pageInfo.endCursor) }
                    }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct SpellRowView: View {
    let node: SpellNode
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(node.name).font(.headline)
                Spacer()
                Text(node.category).font(.caption).foregroundStyle(.secondary)
            }
            Text(node.effect).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}
