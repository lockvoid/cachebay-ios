# Cachebay (iOS)

**Reactive, normalized GraphQL cache for Swift.** Same architecture as [cachebay-web](https://github.com/lockvoid/cachebay), tuned for Apple platforms: SwiftPM-distributed, Swift 6 strict-concurrency, SQLite-backed persistence, build-time codegen via `cachebay-cli`.

```swift
let client = CachebayClient(options: CachebayOptions(
    transport: Transport(
        http: URLSessionHTTPTransport(url: URL(string: "https://api.example.com/graphql")!),
        ws:  URLSessionWebSocketTransport(url: URL(string: "wss://api.example.com/graphql")!)
    ),
    storage: SQLiteStorage.factory(options: .init(path: "/path/to/cache.sqlite"))
))

let result = try await client.executeQuery(
    query: GetPost.networkQuery,
    variables: ["id": "p1"]
)
```

## Why

- **Normalized graph** with typename/id identity + interface-aware addressing.
- **Relay-style connections** with infinite/page modes, edge dedup, cursor index.
- **Layered optimistic updates** with reconstructive revert.
- **SQLite persistence** with cross-process journal sync (multi-WebView Capacitor friendly).
- **Pre-baked CachePlans** via codegen — no runtime parser overhead.
- **Swift 6 strict** throughout — every type `Sendable`, lock discipline documented.

## Documentation

- **[Keynotes](./KEYNOTES.md)** — architecture in 5 minutes
- **[Installation](./INSTALLATION.md)** — SwiftPM setup
- **[Setup](./SETUP.md)** — `CachebayClient`, transports, identity
- **[Codegen](./CODEGEN.md)** — `cachebay-cli`, schema, operations
- **[Operations](./OPERATIONS.md)** — `executeQuery` / `executeMutation` / `executeSubscription`
- **[Queries](./QUERIES.md)** — `readQuery` / `writeQuery` / `watchQuery`
- **[Fragments](./FRAGMENTS.md)** — `readFragment` / `writeFragment` / `watchFragment`
- **[Mutations](./MUTATIONS.md)** — write merging, optimistic patterns
- **[Subscriptions](./SUBSCRIPTIONS.md)** — `graphql-transport-ws` over `URLSessionWebSocketTask`
- **[Relay Connections](./RELAY_CONNECTIONS.md)** — `@connection` directive
- **[Optimistic Updates](./OPTIMISTIC_UPDATES.md)** — layering, commit, revert
- **[Storage](./STORAGE.md)** — SQLite, cross-process sync, dispose

## Demo

A working SwiftUI demo lives at [`demo/ios/`](../demo/ios/). It mirrors the [web Harry Potter demo](https://harrypotter.exp.lockvoid.com/) and exercises every feature: pagination, search, optimistic create, live subscriptions, persistence.

```sh
cd demo/server && pnpm install && pnpm start    # graphql server on :4000
cd demo/ios && make all && open HarryPotterDemo.xcodeproj
```

---

MIT © LockVoid Labs ~●~
