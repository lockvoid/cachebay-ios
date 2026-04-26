# Operations

Cachebay exposes three network operations, all on `CachebayClient`:

- `executeQuery` — fetch with cache policies, normalise into the cache.
- `executeMutation` — write to the server, merge result into the cache.
- `executeSubscription` — stream live updates over WebSocket.

For per-shape recipes:

- [Queries](./QUERIES.md) — `executeQuery` + `readQuery` / `writeQuery` / `watchQuery`
- [Mutations](./MUTATIONS.md)
- [Subscriptions](./SUBSCRIPTIONS.md)

## Result type

Every async API returns `OperationResult<JSONValue>`:

```swift
public struct OperationResult<TData: Sendable>: Sendable {
    public var data: TData?         // present on success (and on partial errors)
    public var error: CombinedError?
    public var meta: Meta?          // .source = .cache | .network
}
```

`CombinedError` carries either a `networkError` (transport failure) or a list of `graphqlErrors` (server-reported errors). See [Errors](#errors).

## `executeQuery`

```swift
@discardableResult
func executeQuery(
    query: String,
    variables: [String: JSONValue] = [:],
    cachePolicy: CachePolicy? = nil,
    onCacheData: ((JSONValue, _ willFetchFromNetwork: Bool) -> Void)? = nil,
    onNetworkData: ((JSONValue) -> Void)? = nil,
    onError: ((CombinedError) -> Void)? = nil
) async throws -> OperationResult<JSONValue>
```

```swift
let result = try await client.executeQuery(
    query: GetPost.networkQuery,
    variables: ["id": "p1"],
    cachePolicy: .cacheAndNetwork,
    onCacheData: { data, willFetchFromNetwork in
        // Fired synchronously when cache has a hit.
    }
)
```

The closures are imperative side-channels — the same data also flows through `result` and through any active `watchQuery` for the same canonical signature.

For full policy semantics see [SETUP.md#cache-policies](./SETUP.md#cache-policies).

## `executeMutation`

```swift
@discardableResult
func executeMutation(
    query: String,
    variables: [String: JSONValue] = [:],
    onData: ((JSONValue) -> Void)? = nil,
    onError: ((CombinedError) -> Void)? = nil
) async throws -> OperationResult<JSONValue>
```

```swift
let result = try await client.executeMutation(
    query: CreatePost.networkQuery,
    variables: ["input": .object(["title": "Hello"])]
)
```

Server response is normalised into the cache under a synthetic `@mutation.N` rootId, then merged into entities by `__typename:id`. Watchers depending on those entities update automatically. See [MUTATIONS.md](./MUTATIONS.md) for optimistic patterns.

## `executeSubscription`

```swift
func executeSubscription(
    query: String,
    variables: [String: JSONValue] = [:]
) throws -> AsyncThrowingStream<OperationResult<JSONValue>, Error>
```

```swift
let stream = try client.executeSubscription(query: PostUpdated.networkQuery, variables: ["id": "p1"])
for try await event in stream {
    if let data = event.data {
        // ... handle frame
    }
}
```

Frames are normalised under `@subscription.N` rootIds. Empty/null frames are silently dropped (handles `connection_ack`-style messages from the server). See [SUBSCRIPTIONS.md](./SUBSCRIPTIONS.md) for transport setup and protocol details.

## Errors

`CombinedError` is `Sendable` and `Hashable`:

```swift
public struct CombinedError: Error, Sendable, Hashable {
    public let networkError: String?           // transport-level
    public let graphqlErrors: [GraphQLResponseError]
}

public struct GraphQLResponseError: Error, Sendable, Hashable {
    public let message: String
    public let path: [String]?
    public let locations: [Location]?
    public let extensions: [String: JSONValue]?
}
```

Use the convenience factories for common cases:

```swift
.cacheMiss()         // no data for cache-only query
.stale()             // a newer request superseded this one
```

## Next steps

- [Queries](./QUERIES.md) — read/write/watch.
- [Mutations](./MUTATIONS.md) — write merging + optimistic patterns.
- [Subscriptions](./SUBSCRIPTIONS.md) — streaming.
