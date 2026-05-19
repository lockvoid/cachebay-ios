# Operations

Cachebay exposes three network operations, all on `CachebayClient`:

- `executeQuery` — fetch with cache policies, normalise into the cache.
- `executeMutation` — write to the server, merge result into the cache.
- `executeSubscription` — stream live updates over WebSocket.

Each one ships **two surfaces**:

1. **Typed** (recommended) — pass a generated `Op.Type` + typed `Variables`, get back `OperationResult<Op.Data>`. Callers never touch `JSONValue`.
2. **JSON-shaped** — pass a source string + `[String: JSONValue]`. Available for ad-hoc operations or when working without codegen.

The typed overloads are zero-cost wrappers around the JSON ones, so behaviour (cache policies, dedupe, normalise, errors) is identical.

Each typed operation also ships **two completion shapes**:

- **`async throws`** — the primary form. `try await` returns `OperationResult<Op.Data>` (or `AsyncThrowingStream<…>` for subscriptions).
- **Sync overload with `onData`/`onError` callbacks** — returns a `CachebayToken`, never blocks. Use this from SwiftUI view actions and other sync contexts where wrapping in `Task { ... }` would defer same-tick work (notably a `modifyOptimistic` patch) past the next render frame. See [Sync overloads](#sync-overloads) below.

For per-shape recipes:

- [Queries](./QUERIES.md) — `executeQuery` + `readQuery` / `writeQuery` / `watchQuery`
- [Mutations](./MUTATIONS.md) — `executeMutation` + `modifyOptimistic` for typed optimistic patches and connection inserts/removes
- [Subscriptions](./SUBSCRIPTIONS.md)
- [Fragments](./FRAGMENTS.md) — `readFragment` / `writeFragment` / `watchFragment`
- [Optimistic Updates](./OPTIMISTIC_UPDATES.md) — typed `b.patch(fragment:id:_:)` + connection `linkNode`/`unlinkNode`

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

Typed:

```swift
@discardableResult
func executeQuery<Op: Operation>(
    query: Op.Type,
    variables: Op.Variables,
    cachePolicy: CachePolicy? = nil,
    onCacheData: ((Op.Data, _ willFetchFromNetwork: Bool) -> Void)? = nil,
    onNetworkData: ((Op.Data) -> Void)? = nil,
    onError: ((CombinedError) -> Void)? = nil
) async throws -> OperationResult<Op.Data>
```

```swift
let result = try await client.executeQuery(
    query: GetPost.self,
    variables: .init(id: "p1"),
    cachePolicy: .cacheAndNetwork
)
print(result.data?.post?.title ?? "—")
```

JSON-shaped (callable when you don't have codegen for the operation):

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

The closures are imperative side-channels — the same data also flows through `result` and through any active `watchQuery` for the same canonical signature.

For full policy semantics see [SETUP.md#cache-policies](./SETUP.md#cache-policies).

## `executeMutation`

Typed:

```swift
@discardableResult
func executeMutation<Op: Operation>(
    mutation: Op.Type,
    variables: Op.Variables,
    onData: ((Op.Data) -> Void)? = nil,
    onError: ((CombinedError) -> Void)? = nil
) async throws -> OperationResult<Op.Data>
```

```swift
let result = try await client.executeMutation(
    mutation: CreatePost.self,
    variables: .init(input: .init(title: "Hello"))
)
print(result.data?.createPost?.id ?? "—")
```

Server response is normalised into the cache under a synthetic `@mutation.N` rootId, then merged into entities by `__typename:id`. Watchers depending on those entities update automatically. See [MUTATIONS.md](./MUTATIONS.md) for optimistic patterns.

## `executeSubscription`

Typed:

```swift
func executeSubscription<Op: Operation>(
    subscription: Op.Type,
    variables: Op.Variables
) throws -> AsyncThrowingStream<OperationResult<Op.Data>, Error>
```

```swift
let stream = try client.executeSubscription(
    subscription: PostUpdated.self,
    variables: .init(id: "p1")
)
for try await event in stream {
    if let post = event.data?.postUpdated {
        // ... handle frame
    }
}
```

Frames are normalised under `@subscription.N` rootIds. Empty/null frames are silently dropped (handles `connection_ack`-style messages from the server). See [SUBSCRIPTIONS.md](./SUBSCRIPTIONS.md) for transport setup and protocol details.

## Sync overloads

Every typed execute call has a sync sibling that takes the same callbacks as the async form but returns a `CachebayToken` instead of an async result. The call itself never blocks; the network runs on an internal detached task.

```swift
@discardableResult
func executeMutation<Op: Operation>(
    mutation: Op.Type,
    variables: Op.Variables,
    onData: ((Op.Data) -> Void)? = nil,
    onError: ((CombinedError) -> Void)? = nil
) -> CachebayToken

@discardableResult
func executeQuery<Op: Operation>(
    query: Op.Type,
    variables: Op.Variables,
    cachePolicy: CachePolicy? = nil,
    onCacheData: ((Op.Data, _ willFetchFromNetwork: Bool) -> Void)? = nil,
    onNetworkData: ((Op.Data) -> Void)? = nil,
    onError: ((CombinedError) -> Void)? = nil
) -> CachebayToken

@discardableResult
func executeSubscription<Op: Operation>(
    subscription: Op.Type,
    variables: Op.Variables,
    onData: ((Op.Data) -> Void)? = nil,
    onError: ((CombinedError) -> Void)? = nil
) -> CachebayToken
```

### When to reach for the sync overload

The async form is the default. Reach for the sync overload when:

1. **You're in a SwiftUI view action** (button handler, `onTapGesture`, etc.) and you need a `modifyOptimistic` patch sequenced right before the call to be observable in the cache **on the same render tick**. Wrapping in `Task { await executeMutation(...) }` defers the optimistic past the next frame:

   ```swift
   // Same render tick — both writes commit before any subsequent observation:
   let tx = client.modifyOptimistic { b in b.patch(fragment: PostFields.self, id: id) { ... } }
   client.executeMutation(
       UpdatePost.self,
       variables: .init(input: input),
       onData: { _ in tx.dispose() },
       onError: { err in tx.revert(); /* toast … */ }
   )
   ```

2. **You want the operation to survive caller teardown.** The internal task is `Task.detached` — a SwiftUI view tearing down between the call and the server response does NOT cancel the operation. (The async form, called from `Task { await ... }`, inherits the caller's structured-concurrency cancellation.)

3. **You don't have a meaningful `try await` site** to put the call in — fire-and-forget from a service or VM method that doesn't itself need to be `async`.

Stick with the async form when you already have a `try await` chain, when you want to read `OperationResult.meta` / `.error` programmatically, or when you need explicit `Task` lifetime for testing.

### `CachebayToken`

```swift
public final class CachebayToken: Sendable {
    public func cancel()        // idempotent; flips isCancelled synchronously
    public var isCancelled: Bool
}
```

`cancel()` does two things:

1. Cancels the internal detached task (the network request, where the transport supports cancellation).
2. Wraps all callbacks so any fire after cancel is a no-op — airtight regardless of whether the response was already in-flight.

Discarding the token (the common case for fire-and-forget) is fine: the operation runs to natural completion and callbacks fire normally. The overloads are `@discardableResult`.

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
