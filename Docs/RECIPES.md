# Recipes

Patterns Cachebay doesn't ship as built-ins but you'll likely want. Copy, paste, adapt.

- [Combining multiple watchers](#combining-multiple-watchers)

---

## Combining multiple watchers

A view that depends on N queries needs all N data sets to render meaningfully. Cachebay's `watchQuery` fires one stream per watcher — no built-in "all-of" combinator — so the consumer wires composition. This recipe shows two patterns: a plain collector that fires when every watcher has loaded, and a SwiftUI view-model that exposes per-watcher state for the view body to compose.

### Why no built-in?

Composition is a UX-framework concern. Combine has `combineLatest`, Swift Concurrency has `AsyncStream`, TCA has its own state-driven model, plain UIKit consumers want callbacks. Cachebay stays out of it — the cache fires per-watcher emits, you compose them in whatever shape your UI layer prefers.

The one Cachebay-specific concern is **callback fan-out**: if a single graph write touches deps that all 4 watchers care about, you get 4 sequential `onData` callbacks (one per watcher) in the same tick, not one combined "everything's updated" notification. Both recipes below treat each callback as an independent state update. If this becomes a perf issue (e.g. 4 SwiftUI re-renders per write), open an issue — that's the signal for a built-in dep-aware coalescer.

### Pattern 1 — `CombinedWatchers` collector (gate-on-loaded)

Fires `onAllData` once every watcher has emitted at least once. Subsequent emits keep firing it. Errors surface via `onError` but don't suppress `onAllData` — once a watcher has data, transient errors don't blank the view.

```swift
import Cachebay

/// Index-based collector. Plug 1..N watcher emits into `update(index:data:)`
/// and `fail(index:error:)`; `onAllData` fires once every slot has data.
final class CombinedWatchers: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [JSONValue?]
    private let onAllData: @Sendable ([JSONValue]) -> Void
    private let onError: @Sendable (_ error: CombinedError, _ source: Int) -> Void

    init(
        count: Int,
        onAllData: @escaping @Sendable (_ data: [JSONValue]) -> Void,
        onError: @escaping @Sendable (_ error: CombinedError, _ source: Int) -> Void = { _, _ in }
    ) {
        self.slots = Array(repeating: nil, count: count)
        self.onAllData = onAllData
        self.onError = onError
    }

    func update(index: Int, data: JSONValue) {
        lock.lock()
        slots[index] = data
        // Snapshot under lock; fire outside to avoid holding it across host code.
        let snapshot: [JSONValue]? = slots.allSatisfy { $0 != nil }
            ? slots.compactMap { $0 } : nil
        lock.unlock()
        if let snapshot { onAllData(snapshot) }
    }

    func fail(index: Int, error: CombinedError) {
        // Errors don't clear the slot — preserve stale data per "gate-on-loaded" policy.
        // Sticky errors produce "once-errored, never recovered" UX; we don't want that.
        onError(error, index)
    }
}
```

**Usage:**

```swift
let combined = CombinedWatchers(count: 4) { datas in
    // All 4 have at least one data; safe to render.
    Task { @MainActor in
        self.viewModel.users    = GetUsers.Data(__data: datas[0].object ?? [:])
        self.viewModel.posts    = GetPosts.Data(__data: datas[1].object ?? [:])
        self.viewModel.comments = GetComments.Data(__data: datas[2].object ?? [:])
        self.viewModel.notifs   = GetNotifs.Data(__data: datas[3].object ?? [:])
    }
} onError: { error, source in
    logger.warning("watcher #\(source) errored: \(error)")
}

let h1 = try client.watchQuery(query: GetUsers.self, options: WatchQueryOptions(
    immediate: true,
    onData: { d in combined.update(index: 0, data: .object(d.__data)) },
    onError: { combined.fail(index: 0, error: $0) }
))
let h2 = try client.watchQuery(query: GetPosts.self, options: WatchQueryOptions(
    immediate: true,
    onData: { d in combined.update(index: 1, data: .object(d.__data)) },
    onError: { combined.fail(index: 1, error: $0) }
))
// ... h3, h4 ...

// Tear down all together.
let handles = [h1, h2, h3, h4]
defer { handles.forEach { $0.unsubscribe() } }
```

### Error semantics

- **Per-watcher errors are surfaced but don't gate `onAllData`.** Once a watcher has data, a transient network error on a refetch fires `onError(error, source: n)` without un-loading the slot. The view keeps showing the prior data; consumers typically banner the error.
- **Errors are not sticky.** A subsequent successful re-emit on the same watcher fires `onAllData` again with the fresh data — recovery is automatic.
- **All-error state isn't special-cased.** If every watcher fails on its initial emit, no `onAllData` fires (slots stay nil) and you'll get N `onError` calls. Render a generic "couldn't load" if your spinner has hung past a timeout.

### Pattern 2 — SwiftUI view model (full per-slot state)

For SwiftUI consumers who want the view body to compose. One `@Published` per watcher; the view decides what "loaded" means.

```swift
@MainActor
final class CombinedFeedViewModel: ObservableObject {
    @Published var users:    Result<GetUsers.Data,    CombinedError>?
    @Published var posts:    Result<GetPosts.Data,    CombinedError>?
    @Published var comments: Result<GetComments.Data, CombinedError>?
    @Published var notifs:   Result<GetNotifs.Data,   CombinedError>?

    private var handles: [WatchQueryHandle] = []

    func start(client: CachebayClient) {
        handles.append(try! client.watchQuery(query: GetUsers.self, options: .init(
            immediate: true,
            onData:  { [weak self] d in Task { @MainActor in self?.users = .success(d) } },
            onError: { [weak self] e in Task { @MainActor in self?.users = .failure(e) } }
        )))
        // ... repeat for posts, comments, notifs ...
    }

    func stop() {
        handles.forEach { $0.unsubscribe() }
        handles.removeAll()
    }
}

// In the view:
struct FeedView: View {
    @StateObject private var vm = CombinedFeedViewModel()
    let client: CachebayClient

    var body: some View {
        Group {
            if let users    = vm.users?.successValue,
               let posts    = vm.posts?.successValue,
               let comments = vm.comments?.successValue,
               let notifs   = vm.notifs?.successValue {
                FeedContent(users: users, posts: posts, comments: comments, notifs: notifs)
            } else if let firstError = [vm.users, vm.posts, vm.comments, vm.notifs]
                        .compactMap({ $0?.failureValue }).first {
                ErrorView(error: firstError, onRetry: { vm.stop(); vm.start(client: client) })
            } else {
                ProgressView()
            }
        }
        .onAppear { vm.start(client: client) }
        .onDisappear { vm.stop() }
    }
}

extension Result {
    var successValue: Success? { if case .success(let v) = self { return v } else { return nil } }
    var failureValue: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}
```

### When to use which

- **Pattern 1** for non-SwiftUI consumers, or when you want one "everything ready" callback to drive an imperative render.
- **Pattern 2** for SwiftUI — the view body composes naturally, and the per-slot `Result` lets you build sophisticated UIs (per-pane error banners, partial-load shimmers, retry-just-this-one-query).

### What these recipes don't do

- **No cross-watcher coalescing.** If one graph write triggers re-emits on all N watchers, you get N sequential `onAllData` (Pattern 1) or N `@Published` updates (Pattern 2) within one tick. SwiftUI usually coalesces consecutive `@Published` writes into a single re-render, so Pattern 2 is OK in practice. If Pattern 1 callers see real perf issues from the fan-out, file an issue — that's the signal to build a dep-aware coalescer into Cachebay.
- **No "wait for first network response" gate.** Both patterns fire `onAllData` as soon as each watcher has any data — cache or network. If you specifically need to wait for fresh network data, use `executeQuery(.cacheAndNetwork)` per watcher with an `onNetworkData` gate instead of `watchQuery`.
- **No type-safe tuple.** The collector uses index-based `JSONValue` slots and the consumer casts back to typed `Data`. Swift parameter packs (iOS 17+) would enable a typed `(GetUsers.Data, GetPosts.Data, ...)` tuple but at the cost of a hard min-OS bump. Keep it simple — the cast is one line per watcher.
