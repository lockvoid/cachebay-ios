import SwiftUI
import CachebayUI

@main
struct HarryPotterDemoApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .cachebayClient(store.client)   // provides the client to @CachebayQuery
        }
    }
}
