# Fragments

**Reading & watching partial entity data**, keyed by canonical record id (e.g. `"Post:p1"`).

- `readFragment` — materialise from cache.
- `writeFragment` — write data under an entity id.
- `watchFragment` — push updates when dependent fields change.

> IDs are canonical: `"Typename:value"` (e.g. `"Post:p1"`). With interfaces enabled (e.g. `interfaces: ["Node": ["User", "Post"]]`), interface-keyed reads (`"Node:42"`) resolve to the concrete record once `__typename` is known.

---

## `readFragment`

```swift
let json = client.readFragment(
    id: "Post:p1",
    fragment: """
        fragment PostFields on Post { id title author { id name } }
    """,
    variables: [:]
)
```

Returns `JSONValue?`; `nil` on cache miss. Cast through codegen for typed access:

```swift
if let json {
    let post = PostFields.Data(__data: json.object ?? [:])
    print(post.title)
}
```

Equivalent overload for a pre-compiled plan:

```swift
client.readFragment(id: "Post:p1", fragment: .plan(PostFields.cachePlan))
```

---

## `writeFragment`

Write raw data under a record id.

```swift
try client.writeFragment(
    id: "Post:p1",
    fragment: "fragment PostFields on Post { id title }",
    data: .object([
        "__typename": "Post", "id": "p1", "title": "Hello"
    ])
)
```

Same normalisation rules as a network response: nested entities are dereferenced into their canonical records; connection fields under the entity, if any, are canonicalised.

---

## `watchFragment`

```swift
let handle = try client.watchFragment(
    id: "Post:p1",
    fragment: "fragment PostFields on Post { id title author { id name } }",
    options: WatchFragmentOptions(
        immediate: true,
        onData: { data in /* ... */ },
        onError: { err in /* ... */ }
    )
)

// Retarget to a different entity or change variables:
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
                id: "Post:\(id)",
                fragment: "fragment PostFields on Post { id title author { id name } }",
                options: WatchFragmentOptions(
                    immediate: true,
                    onData: { data in
                        Task { @MainActor in post = PostData.from(data) }
                    }
                )
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
