import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        NavigationStack {
            SpellsListView()
                .navigationTitle("Spellbook")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink { CreateSpellView() } label: { Image(systemName: "plus") }
                    }
                    ToolbarItem(placement: .topBarLeading) { HogwartsTimeView() }
                }
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AppStore())
}
