# SwiftUI — `@CachebayQuery` (CachebayUI)

`CachebayUI` is a small, optional library with one job: declarative SwiftUI access to a
Cachebay query. It's pure sugar over `client.watch` — same cache, same eager-decoded
structs, same dependency tracking. The core `Cachebay` stays framework-agnostic; you import
`CachebayUI` only in your SwiftUI targets.

**Requirements:** iOS 18+ / macOS 15+ (uses `@Observable`).

```swift
import CachebayUI
```

## 1. Inject the client once

Provide your `CachebayClient` to the view tree via the environment, near the root:

```swift
@main
struct MyApp: App {
    let client = CachebayClient(options: .init(transport: …))
    var body: some Scene {
        WindowGroup { RootView().cachebayClient(client) }
    }
}
```

## 2. Query in a view

```swift
struct CookView: View {
    @CachebayQuery(GetCook.self, variables: .init(id: cookId)) private var query

    var body: some View {
        switch query.phase {
        case .loading: ProgressView()
        case .failed:  Text(query.error?.description ?? "Something went wrong")
        case .loaded:
            if let cook = query.data?.cook {
                CookDetail(cook)          // cook is the typed @CachebayData struct
            }
        }
    }
}
```

The wrapper subscribes on first render and stays live: any cache change that touches the
query's records re-emits and the view redraws. It tears down when the view leaves the tree.

For a variable-less operation: `@CachebayQuery(ListSpells.self) private var query`.

### The state you read

`query` exposes the observable controller:

| Member | Type | Meaning |
|---|---|---|
| `query.data` | `Op.Data?` | the eagerly-decoded typed result (nil until the first emit / on a cache miss) |
| `query.error` | `CombinedError?` | last error, if any |
| `query.phase` | `.loading` / `.loaded` / `.failed` | coarse state for `switch` |
| `$query` | the controller | for manual control, e.g. `$query.stop()` |

## 3. Dynamic variables — just pass an expression

Pass `variables:` as a normal expression. When it changes (a filter, a search term, a
pagination cursor), the wrapper swaps the watcher's variables **in place** via the runtime's
`handle.update` — no unsubscribe/re-subscribe, no flicker.

```swift
struct CookList: View {
    let filter: Category                 // a `let` so the wrapper re-reads on change

    @CachebayQuery(ListCooks.self, variables: .init(filter: filter)) private var query

    var body: some View {
        List(query.data?.cooks ?? []) { CookRow($0) }
    }
}

// parent drives it from @State:
struct Screen: View {
    @State private var filter: Category = .all
    var body: some View {
        VStack {
            Picker("Filter", selection: $filter) { /* … */ }
            CookList(filter: filter)
        }
    }
}
```

> Tip: put the wrapper in a child view that takes the variable as a `let` (as above). That
> guarantees the wrapper's init re-runs with the new value — the same pattern you'd use with
> `@FetchRequest`. It works inline too, but the child-with-`let` shape is bulletproof.

### Pagination is the same mechanism

You don't need a `loadMore`. `@connection` decides replace-vs-accumulate from *which*
variable changed:

- a **filter** (a canonical var) → new canonical connection → **replace**;
- a **cursor** (`after:`, a window arg) → merges into the same canonical → **accumulate**.

Both are just a variable change the wrapper forwards to `handle.update`:

```swift
// on scroll-to-bottom, advance the cursor in @State; the list grows automatically:
@State private var after: String? = nil
@CachebayQuery(Feed.self, variables: .init(first: 20, after: after)) private var query
```

## 4. When you need more control — drop to imperative

`@CachebayQuery` is convenience; the imperative API is the substrate and is always available
for custom lifecycles, background prefetch, combining watchers, or non-SwiftUI code:

```swift
let cook   = client.read(GetCook.self, variables: .init(id: id))          // one-shot cache read
let handle = try client.watch(GetCook.self, variables: …) { data in … }   // manual subscription
let result = try await client.execute(GetCook.self, variables: …)          // cache + network
```

Both deliver the same macro structs — `@CachebayQuery` just drives `client.watch` for you on
SwiftUI's render cycle.

## Why a separate library?

So the core `Cachebay` never imports SwiftUI. UIKit/AppKit apps, server-side code, and tests
use `Cachebay` directly; only SwiftUI views pull in `CachebayUI`.
