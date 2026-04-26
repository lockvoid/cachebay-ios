# Subscriptions

**Streaming updates** with Cachebay.

- Core API: `executeSubscription` → `AsyncThrowingStream<OperationResult<JSONValue>, Error>`
- Default transport: `URLSessionWebSocketTransport` implementing the `graphql-transport-ws` subprotocol.

---

## `executeSubscription`

```swift
let stream = try client.executeSubscription(
    query: PostUpdated.networkQuery,
    variables: ["id": "p1"]
)

for try await event in stream {
    if let data = event.data {
        let typed = PostUpdated.Data(__data: data.object ?? [:])
        // ... update UI
    }
    if let err = event.error {
        // partial-data error from the server
    }
}
```

Each emitted frame is normalised into the cache under a synthetic `@subscription.N` rootId, then merged into entities by `__typename:id`. Watchers depending on those entities update automatically — your `for try await` is just one way to observe.

Empty / null frames are silently dropped:
- `{ data: null }` → ignored (handles `connection_ack`-style messages).
- `{ data: {} }`   → ignored.
- `{ data: { field: null } }` → normalised normally.

## Transport setup

Provide a `WSTransport` when constructing the client. Cachebay ships `URLSessionWebSocketTransport`:

```swift
let ws = URLSessionWebSocketTransport(
    url: URL(string: "wss://api.example.com/graphql")!,
    subprotocol: "graphql-transport-ws",
    connectionParams: ["authToken": .string(token)]
)

let client = CachebayClient(options: CachebayOptions(
    transport: Transport(http: httpTransport, ws: ws)
))
```

What it does:

- Opens a single shared `URLSessionWebSocketTask` lazily on the first `subscribe`.
- Negotiates `connection_init` → `connection_ack` once; subsequent subscribes reuse the connection.
- Multiplexes subscriptions over distinct `id`s (`subscribe` / `next` / `error` / `complete` messages).
- Cancels the per-subscription channel and sends a `complete` frame when the `AsyncThrowingStream` is dropped or its `Task` cancelled.

If your server uses a different subprotocol (legacy `subscriptions-transport-ws`), pass it via `subprotocol:` and adjust message names — the transport is small (~250 LOC) and easy to fork.

## Custom transport

Conform to `WSTransport`:

```swift
public protocol WSTransport: Sendable {
    func subscribe(_ context: WSContext) -> AsyncThrowingStream<OperationResult<JSONValue>, Error>
}
```

`WSContext` carries the network query string + variables. Your implementation yields `OperationResult` frames as they arrive, finishes the stream on completion, throws on protocol error.

---

## Cancellation

The stream is cancellable via the standard Swift concurrency APIs:

```swift
let task = Task {
    let stream = try client.executeSubscription(query: PostUpdated.networkQuery)
    for try await event in stream {
        // ...
    }
}

// ... later:
task.cancel()
```

When the consumer drops out of the `for await` loop or cancels the task, the transport sends a `complete` frame for that subscription id and tears down the per-subscription handler. The shared connection stays alive for other subscriptions.

---

## SwiftUI integration

```swift
struct LiveClock: View {
    @State private var time: String = "—"
    @State private var task: Task<Void, Never>? = nil

    var body: some View {
        Label(time, systemImage: "clock")
            .task {
                task?.cancel()
                task = Task { @Sendable in
                    do {
                        let stream = try client.executeSubscription(
                            query: HogwartsTime.networkQuery
                        )
                        for try await event in stream {
                            if let t = event.data?["hogwartsTimeUpdated"]?["time"]?.string {
                                await MainActor.run { time = t }
                            }
                        }
                    } catch { /* connection drop / cancellation */ }
                }
            }
            .onDisappear { task?.cancel(); task = nil }
    }
}
```

Always hop to `@MainActor` before mutating SwiftUI state. The subscription task may run anywhere.

---

## Next steps

- [Relay Connections](./RELAY_CONNECTIONS.md) — subscriptions are a natural fit for prepending live items into an infinite list (use `addNode` from inside the `for await`).
- [Mutations](./MUTATIONS.md) — write merging.
- [Storage](./STORAGE.md) — subscription-driven graph mutations are also persisted.
