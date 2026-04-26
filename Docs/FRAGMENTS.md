# Fragments

**Reading & watching partial entity data**, keyed by entity id.

- `readFragment` — materialise from cache.
- `writeFragment` — seed an entity (test fixtures / SSR / restored snapshot).
- `watchFragment` — push updates when dependent fields change.

Each ships in **typed** (`fragment: F.Type, id: "p1"`) and **JSON-shaped** (`fragment: String, id: "Post:p1"`) variants. The typed overloads build the canonical cache key from the fragment's `onTypename` + the bare id — callers never write the typename twice.

> Mutations don't go through fragment writes. Use `modifyOptimistic { b.patch(fragment: F.self, id: ...) { ... } }` (typed) or `b.patch(.key("Post:p1"), [...], mode: .merge)` (JSON-shaped) — both participate in the layered commit/revert pipeline. See [OPTIMISTIC_UPDATES.md](./OPTIMISTIC_UPDATES.md).

> With interfaces enabled (e.g. `interfaces: ["Node": ["User", "Post"]]`), interface-keyed reads resolve to the concrete record once `__typename` is known.

---

## `readFragment`

Typed:

```swift
let post = client.readFragment(
    fragment: PostFields.self,
    id: "p1",                  // bare id; cache key built as "Post:p1" from F.onTypename
    variables: .init()
)
print(post?.title ?? "—")
```

`id` accepts any `LosslessStringConvertible`, so `"p1"` and `42` both work.

JSON-shaped (for ad-hoc fragments without codegen — full cache key required):

```swift
let json = client.readFragment(
    id: "Post:p1",
    fragment: "fragment PostFields on Post { id title author { id name } }",
    variables: [:]
)
```

Returns `nil` on cache miss in both forms.

---

## `writeFragment`

Direct base-cache writes — useful for seeding test fixtures, restoring snapshots, or pre-populating SSR state. Mutations should go through `modifyOptimistic`.

Typed:

```swift
try client.writeFragment(
    fragment: PostFields.self,
    id: "p1",
    variables: .init(),
    data: PostFields.Data(__data: [
        "__typename": .string("Post"),
        "id": .string("p1"),
        "title": .string("Hello"),
    ])
)
```

JSON-shaped:

```swift
try client.writeFragment(
    id: "Post:p1",
    fragment: "fragment PostFields on Post { id title }",
    data: .object(["__typename": .string("Post"), "id": .string("p1"), "title": .string("Hello")])
)
```

Same normalisation rules as a network response.

---

## `watchFragment`

Typed:

```swift
let handle = try client.watchFragment(
    fragment: PostFields.self,
    id: "p1",
    variables: .init(),
    immediate: true,
    onData: { data in /* `data` is typed PostFields.Data */ },
    onError: { err in /* ... */ }
)

// Retarget to a different entity (JSON-shape full cache key here):
handle.update("Post:p2", nil, true)

// On scope exit:
handle.unsubscribe()
```

Notes:

- Cache misses don't fire `onError` — the watcher waits for data to arrive (e.g. when a query lands).
- Internal dep index tracks the entity record + every record it transitively dereferences. Writes to those records trigger a re-materialise.
- Identical emissions are dropped by fingerprint so SwiftUI sees stable identity for unchanged subtrees.

---

## SwiftUI integration

```swift
struct PostDetailView: View {
    let id: String
    @State private var post: PostData? = nil
    @State private var watcher: WatchFragmentHandle? = nil

    var body: some View {
        Group {
            if let post {
                Text(post.title).font(.title)
            } else {
                ProgressView()
            }
        }
        .task {
            watcher = try? client.watchFragment(
                fragment: PostFields.self,
                id: id,
                variables: .init(),
                immediate: true,
                onData: { data in
                    Task { @MainActor in post = PostData(from: data) }
                }
            )
        }
        .onDisappear { watcher?.unsubscribe(); watcher = nil }
    }
}
```

`watchFragment` is the right primitive for "live entity panel" UIs — list, detail, drawer — because the panel re-renders on any mutation that touches that entity, including ones initiated from elsewhere in the app.

---

## Next steps

- [Mutations](./MUTATIONS.md) — write merging.
- [Optimistic Updates](./OPTIMISTIC_UPDATES.md) — entity helpers.
- [Relay Connections](./RELAY_CONNECTIONS.md) — pagination across fragment-loaded entities.
