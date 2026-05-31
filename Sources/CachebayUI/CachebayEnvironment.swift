import SwiftUI
import Cachebay

private struct CachebayClientKey: EnvironmentKey {
    static let defaultValue: CachebayClient? = nil
}

public extension EnvironmentValues {
    /// The `CachebayClient` used by `@CachebayQuery`. Inject it once near the root:
    /// `RootView().cachebayClient(client)`.
    var cachebayClient: CachebayClient? {
        get { self[CachebayClientKey.self] }
        set { self[CachebayClientKey.self] = newValue }
    }
}

public extension View {
    /// Provide the `CachebayClient` to `@CachebayQuery` wrappers below this view.
    func cachebayClient(_ client: CachebayClient) -> some View {
        environment(\.cachebayClient, client)
    }
}
