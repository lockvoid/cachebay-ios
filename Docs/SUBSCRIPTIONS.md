# Subscriptions

**Streaming updates** with Cachebay.

- Core API: `executeSubscription` → `AsyncThrowingStream<OperationResult<Op.Data>, Error>` (typed) or `AsyncThrowingStream<OperationResult<JSONValue>, Error>` (JSON-shaped).
- Default transport: `URLSessionWebSocketTransport` implementing the `graphql-transport-ws` subprotocol.

---

## `executeSubscription`

Typed:

```swift
let stream = try client.executeSubscription(
    subscription: PostUpdated.self,
    variables: .init(id: "p1")
)

for try await event in stream {
    if let post = event.data?.postUpdated {
        // ... update UI with typed `post`
    }
    if let err = event.error {
        // partial-data error from the server
    }
}
```

JSON-shaped overload (`query: String`, `variables: [String: JSONValue]`) is also available for ad-hoc subscriptions without codegen.

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

If your server uses a different subprotocol (legacy `subscriptions-transport-ws`), pass it via `subprotocol:` and adjust message names — the transport is small and easy to fork.

### Diagnostics

Pass an `os.Logger` to `CachebayOptions(logger:)` and Cachebay will emit `.warning`-level lines for actionable cache problems (materialize misses, watcher silencing) plus `.debug` lines for soft misses and reconnect bookkeeping. Use it together with `transport.events()` to wire a debug HUD or telemetry pipe.

```swift
import os
let logger = Logger(subsystem: "com.example.app", category: "Cachebay")
let client = CachebayClient(options: CachebayOptions(
    transport: Transport(http: httpTransport, ws: ws),
    logger: logger
))
```

---

## Auto-reconnect

The transport survives unexpected disconnects (server restart, network blip, app suspend/resume) and replays active subscriptions automatically. When the socket drops:

1. The receive loop exits with an error, and the transport tears down the dead `URLSessionWebSocketTask`.
2. If there are active subscriptions and `ReconnectPolicy.maxAttempts` allows it, the reconnector schedules a retry with exponential backoff + jitter. **Default nominal sequence: 0.5s → 1s → 2s → 4s → 5s → 5s → 5s … (cap 5s, ±30% jitter applied to each, retries forever)** — tight enough for real-time chat / live-update feeds. Each attempt's actual delay is `nominal × random(0.7, 1.3)`.
3. The reconnector opens a new `URLSessionWebSocketTask`, replays the `connection_init` handshake, and waits for `connection_ack`.
4. After `connection_ack` lands, every active subscription's `subscribe` message is re-sent automatically. Subscribers' `for try await` loops keep yielding — they don't see the gap.

```swift
let ws = URLSessionWebSocketTransport(
    url: wsURL,
    reconnectPolicy: .default            // 0.5s / 2× / 5s cap / ±30% / forever
    // .disabled                          // opt out — disconnects throw
    // .aggressive                        // 50ms / 2× / 5s cap (LAN/test)
    // ReconnectPolicy(initialDelay: 1, maxDelay: 30, maxAttempts: 5)  // custom
)
```

The 5s cap is deliberate. HTTPS-style retry libraries cap at 30s+ because requests are high-cost and idempotent retries can wait. WebSocket subscriptions are different — a 30s gap between server recovery and your UI catching up feels broken to users. If you actually want long backoffs (e.g., a low-traffic notification feed where battery matters more than freshness), construct a custom `ReconnectPolicy` with a higher `maxDelay`.

### Lifecycle observability

Bind to `transport.events()` (single-subscriber) or `transport.state` (snapshot) to drive a "Reconnecting…" UI:

```swift
public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case stopped(reason: TerminalReason)   // .userClosed / .unauthorized(code:) / .maxAttemptsExceeded
}

public enum ConnectionEvent: Sendable {
    case connecting
    case acked
    case messageSent(type: String, id: String?)
    case messageReceived(type: String, id: String?)
    case disconnected(reason: DisconnectReason)
    case reconnectScheduled(attempt: Int, delay: TimeInterval)
    case stopped(reason: TerminalReason)
}
```

### Caller-driven reconnect

`transport.reconnect()` is state-aware:

| Current state             | Effect                                                                  |
| ------------------------- | ----------------------------------------------------------------------- |
| `.connected`              | no-op                                                                   |
| `.connecting`             | no-op (already trying)                                                  |
| `.disconnected`           | start a fresh connect attempt                                           |
| `.reconnecting(N)`        | wake the pending backoff sleep, attempt now (counter unchanged)         |
| `.stopped(_)`             | reset, attempt now from scratch — replays subscriptions on success      |

Use this from:
- A UI "Reconnect" button (`.stopped` → resurrect)
- `NWPathMonitor.pathUpdateHandler` on `.satisfied` (network back → skip backoff)
- `UIApplication.didBecomeActiveNotification` observers (foreground → skip backoff)

### Consumer wiring (copy-paste)

The library is platform-agnostic — branch-1 immediate-reconnect signals are wired at the consumer side. Drop this into your app once at startup:

```swift
import Cachebay
import Network
import UIKit

@MainActor @Observable
final class WSStateMonitor {
    enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int, nextAttemptIn: TimeInterval?)
        case stopped(reason: StoppedReason)

        enum StoppedReason: Sendable, Equatable {
            case userClosed
            case unauthorized(code: Int)
            case maxAttemptsExceeded
        }
    }
    private(set) var state: State = .disconnected
    private var pathMonitor: NWPathMonitor?

    func attach(transport: URLSessionWebSocketTransport) {
        // Drain lifecycle events.
        Task { [weak self, transport] in
            for await event in transport.events() {
                await self?.handle(event)
            }
        }

        // Branch-1: NWPathMonitor — skip backoff when network is back.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak transport] path in
            if path.status == .satisfied { transport?.reconnect() }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor

        // Branch-1: foreground — same idea.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak transport] _ in transport?.reconnect() }
    }

    private func handle(_ event: URLSessionWebSocketTransport.ConnectionEvent) {
        switch event {
        case .connecting:                    state = .connecting
        case .acked:                         state = .connected
        case .reconnectScheduled(let n, let d):
            state = .reconnecting(attempt: n, nextAttemptIn: d)
        case .stopped(let reason):
            switch reason {
            case .userClosed:                state = .stopped(reason: .userClosed)
            case .unauthorized(let code):    state = .stopped(reason: .unauthorized(code: code))
            case .maxAttemptsExceeded:       state = .stopped(reason: .maxAttemptsExceeded)
            }
        case .disconnected, .messageSent, .messageReceived:
            break  // either reconnect kicks in, or .stopped follows
        }
    }
}
```

## Background lifecycle & reliability

Real-world subscription apps deal with four reliability scenarios beyond "happy path":

### Scenario A: server restart / network blip

What happens: socket drops, OS reports a receive-loop error within milliseconds.

What cachebay does: tears down the dead socket, kicks the reconnector into the backoff schedule (0.5s → 1s → 2s → 4s → 5s → …). After the next successful `connection_ack`, every active subscription is replayed automatically.

What consumers see: their `for try await` loops on the subscription stream **don't yield anything during the gap, but don't error either**. Once the new socket lands, frames resume normally. UI bound to `WSStateMonitor.state` flips: `.connected` → `.reconnecting(attempt:nextAttemptIn:)` → `.connected`.

Caveats:
- Frames the server sent **during the gap are lost** unless your server has session/queue support (e.g., AnyCable Pro buffers frames per-subscription-id during the disconnect window). Without it, you might miss a `messageCreated` that fired between your last received frame and the reconnect.
- If you *do* have buffering, after replay the consumer might receive the same frame twice (server's queue + replay). Cachebay's normalizer keys by `__typename + id`, so duplicate entity writes are idempotent — but mutations driven from inside subscription handlers would need their own dedup if you have any.

### Scenario B: app backgrounded then foregrounded

What iOS does: when your app moves to background, the OS gives you ~30s to wrap up. After that the process is suspended; the kernel typically tears down active `URLSessionWebSocketTask` connections (sometimes immediately, sometimes during the OS housekeeping window). When the user returns to your app, sockets are dead even if you haven't been notified yet.

What cachebay does on its own: nothing. The transport doesn't observe app lifecycle — that's a UI concern.

What consumers should do (already in the wiring example above): observe `UIApplication.didBecomeActiveNotification` and call `transport.reconnect()`. The call is **state-aware**:
- If the socket survived the background → `.connected`, reconnect() is a no-op.
- If the socket died → `.disconnected` with pending subscriptions, reconnect() kicks the reconnector immediately (skipping the backoff sleep). Recovery is typically <100ms.
- If there are no active subscriptions → reconnect() just transitions internal state, doesn't open any connection. Free to call.

This is why spamming `reconnect()` on every notification is safe and recommended.

### Scenario C: device offline → online

What happens: the user goes through a tunnel, switches Wi-Fi networks, gets on a flight, etc. The socket dies, sometimes silently (no FIN packet), sometimes with an explicit error.

What cachebay does: the receive loop eventually times out or errors out, the reconnector kicks in. With our default 5s cap, recovery is bounded.

What consumers should do (already in the wiring example): wire `NWPathMonitor` and call `transport.reconnect()` on `.satisfied`. The OS notifies you the moment the network is reachable — way faster than waiting for the backoff timer to fire. Same state-aware no-op semantics apply.

### Scenario D: auth token expires mid-session

What happens: server sends a close frame with code `4401` / `4403` (the graphql-transport-ws spec's auth-failure codes), or a `connection_init` payload with `errors`.

What cachebay does: emits `.stopped(reason: .unauthorized(code:))` and **stops retrying**. The reconnector won't run from this state — backing off won't help.

What consumers should do:
1. Detect `.stopped(.unauthorized(code:))` in your `WSStateMonitor` state handler.
2. Refresh the auth token (refresh-token flow, redirect to login, etc.).
3. Update `transport.connectionParams` with the new token.
4. Call `transport.reconnect()` — resurrects from `.stopped` and tries fresh.

```swift
// In WSStateMonitor.handle(_:)
case .stopped(.unauthorized(let code)):
    Task { @MainActor in
        await refreshAuthToken()
        transport.connectionParams["authToken"] = .string(newToken)
        transport.reconnect()
    }
```

### Scenario E: explicit user-driven disconnect

What happens: the user signs out, switches accounts, or your app explicitly calls `transport.disconnect()`.

What cachebay does: tears down the socket, finishes every active subscription with an error, sets state to `.stopped(reason: .userClosed)`. **Auto-reconnect does NOT run from this state** — that's the contract: explicit disconnect means "I want this off until I say otherwise". A subsequent `transport.reconnect()` resurrects the transport and replays subscriptions if any are still registered (in practice, none — the disconnect finished them).

If `disconnect()` is called *while* the reconnector is already running (e.g., the app suspends mid-backoff), the in-flight reconnector is cancelled and the transport jumps straight to `.stopped(.userClosed)`. No reconnect attempts will fire from this state until `reconnect()` is called.

### Limitations

- **No graphql-transport-ws `ping` / `pong` heartbeats** — the transport doesn't periodically check liveness. Long-idle sockets may be killed by NAT timeouts or proxy idle-disconnect policies (typical: 60-120s). The reconnect logic recovers from this, but you may see a `.disconnected` → `.reconnecting` cycle on first activity after an idle period. If your server actively heartbeats, the receive loop catches the heartbeat and idle-kill won't happen.
- **No connection-level backpressure** — if your server bursts thousands of frames at the client, they all get queued by `URLSessionWebSocketTask`. In practice subscription feeds don't hit this, but high-fanout entities could.
- **One shared connection per `URLSessionWebSocketTransport` instance** — multiplexed via `id`. If you need multiple distinct WS endpoints (rare), instantiate multiple transports.

### Optimization rationale

`transport.reconnect()` is **deliberately cheap to call**. The state-aware logic short-circuits in three of five states (`.connected`, `.connecting`, `.disconnected` with no subscriptions). NWPathMonitor often fires multiple times during a real network transition; foreground notifications can fire on every app switch; UI "Reconnect" buttons can be mashed. None of that creates connection storms — at most one socket open per logical reconnect.

The same applies to `events()` drainers: a single drainer with `for await` is cheap; the AsyncStream buffers up to 64 events before dropping the oldest, so a backgrounded drainer won't lose recent events.

### Testing reliability paths

For unit tests, the transport accepts an injectable `clock: any Clock<Duration>` (defaults to `ContinuousClock`). Drop in a fake clock to drive backoff sleeps deterministically — your test runs in milliseconds rather than burning real wall-clock seconds:

```swift
let clock = FakeClock()
let ws = URLSessionWebSocketTransport(
    url: deadURL,
    reconnectPolicy: .init(initialDelay: 0.05, maxAttempts: 4),
    clock: clock
)
// Drive each backoff attempt without sleeping:
for _ in 0..<4 {
    try await clock.waitForPendingSleepThenAdvance(by: .seconds(1))
}
// Assert on transport.events() / transport.state.
```

`Tests/CachebayTests/Helpers/FakeClock.swift` ships a reference impl. For tests that don't care about backoff timing, `ReconnectPolicy.aggressive` (50ms initial / 1s cap) keeps real-clock waits sub-second.

For integration smoke against a real server:
1. Open a subscription in your app.
2. Kill the server (`Ctrl-C` your dev backend).
3. Watch logs: `[WS] disconnected: receiveLoopError` → `[WS] reconnect scheduled attempt=1 delay=0.50s` → growing each attempt.
4. Restart the server. Within the next backoff window: `[WS] connecting` → `[WS] acked (connected)`. Subscriptions replay automatically — no caller-side retry needed.

If a reconnect cycle ever takes longer than your `maxDelay`-cap budget, you have a server-side or network-stack issue, not a cachebay bug.

---

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
