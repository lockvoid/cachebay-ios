# Mutations

**Writing data** with Cachebay.

- Core API: `executeMutation`
- Optimistic helper: `modifyOptimistic`

---

## `executeMutation`

Sends a write to the server and merges the result into the cache.

```swift
let result = try await client.executeMutation(
    query: CreatePost.networkQuery,
    variables: ["input": .object([
        "title": "Hello",
        "category": "General"
    ])]
)

if let data = result.data {
    let typed = CreatePost.Data(__data: data.object ?? [:])
    print(typed.createPost?.post?.id ?? "—")
}
```

See [OPERATIONS.md#executemutation](./OPERATIONS.md#executemutation) for the full signature.

Notes:

- Partial responses are still written — useful fields are kept even when `error` is non-nil.
- Watchers update automatically via dependency tracking on entities the mutation merges into.
- The mutation result is also normalised under a synthetic `@mutation.N` rootId so re-reading from there gives back a clean per-call snapshot.

---

## Optimistic at a glance

For instant UI feedback before the network responds, wrap the mutation in `modifyOptimistic`:

```swift
let tx = client.modifyOptimistic { b, _ in
    b.patch(.key("Post:p1"), ["title": "Draft…"], mode: .merge)
}

do {
    let result = try await client.executeMutation(
        query: UpdatePost.networkQuery,
        variables: ["input": .object(["id": "p1", "title": "Real Title"])]
    )
    tx.commit(result.data?["updatePost"]?["post"])    // promote with server data
} catch {
    tx.revert()                                       // roll back
    throw error
}
```

`commit(data:)` re-runs the builder in `.commit` phase with the server payload and drops the layer; `revert()` removes the layer and replays surviving layers on the touched records.

Full layering semantics: [OPTIMISTIC_UPDATES.md](./OPTIMISTIC_UPDATES.md).

---

## Pattern: optimistic add

Prepend a new node into every matching `Query.posts` connection, commit with the server-assigned id.

```swift
let tempId = "temp:\(UUID().uuidString)"

let tx = client.modifyOptimistic { b, ctx in
    let optimisticNode: [String: JSONValue] = [
        "__typename": "Post",
        "id": ctx.data?["id"] ?? .string(tempId),
        "title": .string(title)
    ]
    for key in client.inspect.getConnectionKeys(parent: .root, key: "posts") {
        b.connection(key: key).addNode(optimisticNode, options: AddNodeOptions(position: .start))
    }
}

do {
    let result = try await client.executeMutation(
        query: CreatePost.networkQuery,
        variables: ["input": .object(["title": .string(title)])]
    )
    if let post = result.data?["createPost"]?["post"] {
        tx.commit(post)
    } else {
        tx.revert()
    }
} catch {
    tx.revert()
}
```

`getConnectionKeys` finds every canonical that matches `parent + key + filters`, so a single mutation can fan out across multiple visible lists (e.g. an "All posts" + a "My posts" feed).

---

## Pattern: optimistic remove

```swift
let tx = client.modifyOptimistic { b, _ in
    for key in client.inspect.getConnectionKeys(parent: .root, key: "posts") {
        b.connection(key: key).removeNode(.key("Post:\(id)"))
    }
}

do {
    _ = try await client.executeMutation(
        query: DeletePost.networkQuery,
        variables: ["input": .object(["id": .string(id)])]
    )
    tx.commit(nil)
} catch {
    tx.revert()
}
```

After commit, you may also `b.delete(.key("Post:\(id)"))` to drop the entity itself so any other watcher reading it falls into a `nil` state.

---

## Pattern: optimistic patch

Merge known fields immediately; promote with server payload on commit.

```swift
let tx = client.modifyOptimistic { b, ctx in
    let id: CacheKey = "Post:\(input.id)"
    if let payload = ctx.data {
        b.patch(.key(id), payload.object ?? [:], mode: .merge)
    } else {
        b.patch(.key(id), [
            "title": input.title.map(JSONValue.string) ?? .undefined
        ], mode: .merge)
    }
}

do {
    let result = try await client.executeMutation(
        query: UpdatePost.networkQuery,
        variables: ["input": .object(input.toCachebay())]
    )
    tx.commit(result.data?["updatePost"]?["post"])
} catch {
    tx.revert()
}
```

`mode: .merge` keeps existing fields; `mode: .replace` writes exactly what's in the patch and drops everything else from the record.

---

## Next steps

- [Subscriptions](./SUBSCRIPTIONS.md) — streaming live updates.
- [Optimistic Updates](./OPTIMISTIC_UPDATES.md) — full builder API + layering.
- [Relay Connections](./RELAY_CONNECTIONS.md) — `addNode` / `removeNode` / `patch` against canonicals.
