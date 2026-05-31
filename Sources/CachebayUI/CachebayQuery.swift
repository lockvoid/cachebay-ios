import SwiftUI
import Cachebay

/// Declarative SwiftUI access to a Cachebay query — "`handle.update` for SwiftUI".
///
/// ```swift
/// struct CookView: View {
///     @CachebayQuery(GetCook.self, variables: .init(id: cookId)) private var query
///     var body: some View {
///         switch query.phase {
///         case .loading: ProgressView()
///         case .failed:  Text(query.error?.description ?? "error")
///         case .loaded:  if let cook = query.data?.cook { CookDetail(cook) }
///         }
///     }
/// }
/// ```
///
/// Inject the client once near the root: `RootView().cachebayClient(client)`.
///
/// **Dynamic variables just work.** Pass `variables:` as a normal expression; when it
/// changes (a `@State` filter, a pagination cursor, …) the wrapper calls the watcher's
/// in-place `update` — `@connection` then accumulates (cursor) or replaces (filter). No
/// `loadMore`, no churn. For full control, drop to `client.watch`/`read`/`execute`.
@propertyWrapper
public struct CachebayQuery<Op: CachebayOperation>: DynamicProperty {
    @Environment(\.cachebayClient) private var client
    @State private var controller = CachebayQueryController<Op>()
    private let variables: Op.Variables

    public init(_ op: Op.Type, variables: Op.Variables) {
        self.variables = variables
    }

    /// The query's observable state (`data` / `error` / `phase`).
    public var wrappedValue: CachebayQueryController<Op> { controller }

    /// Same controller via `$query` — for passing the state down or calling `stop()`.
    public var projectedValue: CachebayQueryController<Op> { controller }

    // `DynamicProperty.update()` is not main-actor in the protocol (hence no
    // `@MainActor` on the wrapper), but SwiftUI invokes it on the main thread —
    // so reconcile inside `assumeIsolated`.
    public func update() {
        let client = self.client
        let controller = self.controller
        let variables = self.variables
        MainActor.assumeIsolated {
            guard let client else {
                assertionFailure("@CachebayQuery: no client in the environment — call `.cachebayClient(client)` on an ancestor view.")
                return
            }
            controller.sync(client: client, variables: variables)
        }
    }
}

public extension CachebayQuery where Op.Variables == EmptyVariables {
    /// Convenience for variable-less operations.
    init(_ op: Op.Type) {
        self.init(op, variables: EmptyVariables())
    }
}
