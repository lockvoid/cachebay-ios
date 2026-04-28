# Changelog

All notable changes to Cachebay-iOS are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_No unreleased changes yet._

## [0.3.1] — Operation-projection `nodes()` overload

### Added
- **`Sequence.nodes()` / `Optional<Sequence>.nodes()`** — operation-projection variant of `nodes(as:)`. Unwraps each edge's `node` into the operation-specific `Element.Node` type without any fragment cast. Use when call sites keep operation-typed helpers downstream (e.g. a `posterFromCachebay(_: Projects.Data.Projects.Edges.Node.Poster)` helper would break under `nodes(as: ProjectFields.self)` because the cast crosses the projection seam — `nodes()` preserves the type). The two overloads coexist: `.nodes()` for operation projection, `.nodes(as: F.self)` for fragment view.

## [0.3.0] — Typed connection-edge sugar

### Added
- **`ConnectionEdge` protocol + `Sequence.nodes(as:)` / `Optional<Sequence>.nodes(as:)` sugar.** Replaces the rote `edges?.compactMap { $0.node?.as(F.self) } ?? []` with `edges.nodes(as: F.self)`. The fragment cast stays explicit (`as: F.self`) — only the compactMap boilerplate disappears. `cachebay-cli` automatically emits the `: Cachebay.ConnectionEdge` conformance on every generated edge struct (any nested struct with a `node: Node?` shared child of object shape), so consumers don't write any conformance themselves. Marker-only protocol; no runtime cost.

### Migration
- **Rerun `cachebay-cli` codegen** to pick up the new `: Cachebay.ConnectionEdge` conformance on emitted `Edges` structs. Existing call sites continue to compile unchanged; opt-in to the sugar one connection at a time.

## [0.2.1] — WebSocket reliability hardening

### Added
- **`updateConnectionParams(_:reconnectIfConnected:)`** — replace the params payload sent in `connection_init`. Use for auth-token rotation (refresh-token flow, account switch, role change) without manually wrangling `disconnect()` → reset → `reconnect()`. With `reconnectIfConnected: true`, drops the live socket and re-handshakes immediately, replaying every `.subscribed` subscription after the new ack. With `false`, the params are stashed and take effect on the next natural reconnect. Inspired by Apollo iOS's `updateConnectingPayload(_:reconnectIfConnected:)`.
- **Optional client-initiated ping/pong** (`URLSessionWebSocketTransport(pingInterval:)`). Disabled by default. When set, the transport sends a `{"type":"ping"}` frame at the configured cadence after `connection_ack` lands, and answers any server-initiated `{"type":"ping"}` with `{"type":"pong"}`. Required for long-idle subscriptions behind NAT (typical NAT timeout 60–120s) or proxies with idle-disconnect policies. The ping Task uses the injected `clock`, so tests can drive cadence with `FakeClock` deterministically.

### Changed
- **Default WS connect timeout shortened to 10s** (`URLSessionWebSocketTransport.defaultConnectTimeout`). Previously the transport used `URLSession.shared`, which carries `timeoutIntervalForRequest = 60`. During a server-restart window, the dominant failure mode is "TCP handshake succeeded, WS upgrade stalled" — a 60s default would eat the entire backoff schedule on the first half-connected attempt. 10s is greater than `ReconnectPolicy.default.maxDelay` (5s) so each backoff cycle gets a full attempt, covers slow cold-start servers (k8s/fly.io 3–7s p95), and aligns with AWS/Cloudflare/Slack norms.
- Callers who pass their own `URLSession` are unaffected — cachebay no longer reads from `.shared` and won't mutate a caller-supplied session.
- `connectionParams` is now a snapshotting computed property (read-only). Mutate via `updateConnectionParams(_:reconnectIfConnected:)`. **Pre-1.0 breaking** for anyone who was assigning `transport.connectionParams = ...` directly (no callers in this repo or the Ferment Cuts consumer at the time of the change).

### Fixed
- **Duplicate `.disconnected` events per failed attempt.** A single physical socket failure typically trips both the send path (the `connection_init` write fails) and the receive-loop catch (the `task.receive()` await throws). The first teardown left state at `.connecting` when subs were pending (`then: nil` in `handleUnexpectedDisconnect`), so the second teardown's gate (`task == nil && isAlreadyTornDown(_state)`) didn't match — `.connecting` isn't "torn down" — and a duplicate event slipped through. Smoke logs from a real failed-handshake retry cycle showed `[WS] disconnected: receiveLoopError` immediately followed by `[WS] disconnected: sendError` per attempt. Now `handleUnexpectedDisconnect` always transitions to `.disconnected` after teardown; the reconnectorLoop overwrites to `.reconnecting(N)` on its next iteration. Brief flicker, correct dedupe.
- **Double `subscribe` frame when calling `subscribe()` mid-handshake.** If a caller invoked `subscribe()` while the transport was in `.connecting` (or `.reconnecting`) and `connection_ack` arrived after registration, two `subscribe` frames went out for the same id: one from the caller's own awaiting Task waking up, one from the connection_ack replay loop. Strict graphql-transport-ws servers reject the duplicate with close code 4409 "Subscriber for `<id>` already exists"; tolerant servers double-yielded events. Mirrors Apollo iOS's two-phase registry: subscriptions are now tagged `.pending` (registered, frame not on the wire) or `.subscribed` (frame sent, awaiting `next`/`error`/`complete`). The ack handler replays only `.subscribed` entries.

## [0.2.0] — WebSocket auto-reconnect

### Added
- **Auto-reconnect for `URLSessionWebSocketTransport`** — survives unexpected disconnects (server restart, network blip, app suspend/resume). Tears down the dead socket, schedules a retry with exponential backoff + jitter, replays every active subscription's `subscribe` after the new `connection_ack`. Subscribers' `for try await` loops keep yielding across the gap.
- `ReconnectPolicy` struct configures the backoff. Defaults: `0.5s → 1s → 2s → 4s → 5s → 5s …` (cap 5s, ±30% jitter, retries forever) — tight enough for real-time chat / live-update feeds. Presets: `.default`, `.disabled`, `.aggressive`.
- New `ConnectionState` cases: `.reconnecting(attempt:)`, `.stopped(reason:)` with `TerminalReason` (`.userClosed` / `.unauthorized(code:)` / `.maxAttemptsExceeded`).
- New `ConnectionEvent` cases: `.reconnectScheduled(attempt:delay:)`, `.stopped(reason:)`.
- `transport.reconnect()` — state-aware caller-driven reconnect:
  - `.connected` / `.connecting` → no-op
  - `.reconnecting(N)` → wakes the pending backoff sleep, attempts now (counter unchanged)
  - `.stopped(_)` → resurrects, replays subscriptions
  - `.disconnected` with pending subs → starts a fresh attempt now
  - Use from UI "Reconnect" buttons, `NWPathMonitor.pathUpdateHandler` on `.satisfied`, or `UIApplication.didBecomeActiveNotification` observers — spamming is safe.
- Permanent-failure detection — WS close code 4401/4403 → `.stopped(.unauthorized)`; reconnect won't retry until caller refreshes auth and calls `reconnect()`.
- Subscription registry that survives reconnect — the transport keeps `(query, variables, continuation)` per subscription and replays them after the new `connection_ack`.
- Injectable `clock: any Clock<Duration>` parameter on `URLSessionWebSocketTransport.init` (defaults to `ContinuousClock()`). Tests pass a `FakeClock` to drive backoff sleeps deterministically — reconnect tests run in milliseconds without burning real wall-clock seconds.
- `Tests/CachebayTests/Helpers/FakeClock.swift` — reference fake-clock impl with `advance(by:)` / `releaseAllPending()` / `waitForPendingSleepThenAdvance(by:)`.
- 6 new reconnect tests in `WebSocketReconnectTests.swift` — backoff math, disabled-policy fail-fast, no-op reconnect, disconnect→stopped→resurrect, exponential growth + jitter range with `FakeClock`, userClosed-vs-maxAttemptsExceeded distinction.
- `Docs/SUBSCRIPTIONS.md` "Auto-reconnect" + "Background lifecycle & reliability" sections — covers all five reliability scenarios (server restart, app foreground, network back, auth-expiry, explicit disconnect), copy-paste consumer wiring with `NWPathMonitor` + foreground observer, testing recipe with `FakeClock`, optimization rationale, known limitations (no ping/pong heartbeats, no connection-level backpressure).

### Changed (breaking)
- **Deployment targets bumped to iOS 16+ / macOS 13+ / tvOS 16+ / watchOS 9+** (visionOS unchanged at 1+). Required to use `Duration` / `Clock` / `Task.sleep(for:)` natively in the reconnect orchestrator and FakeClock test helper. iOS 15 consumers should pin to `v0.1.0`.

### Fixed
- Duplicate `disconnected` events emitted for the same physical disconnect (one from the send-error path, one from the receive-loop catch) — now collapsed via state-aware short-circuit in `teardown`.
- Race where `setState(.disconnected)` after a delayed `receiveLoop` cancellation could overwrite a `.stopped(_)` terminal state. `handleUnexpectedDisconnect` now no-ops when state is already `.stopped`.

## [0.1.0] — Initial public release

First public version. The library was developed and battle-tested as part of the Ferment Cuts iOS app before being extracted; coverage parity with cachebay-web is locked in by the suite (608 tests, all green).

### Added
- `OptimisticTransaction.dispose()` — drops the layer without restoring baselines or re-running the builder. Use when the server response is the authoritative state for touched records (most update mutations). Avoids the bug where `commit(...)`'s baseline restore wipes server-side fields the optimistic patch didn't touch.
- `client.modifyOptimistic(autoCommit: Bool, _:)` — single-phase variant. When `autoCommit: true`, the closure runs once at `.commit` phase against the base graph (no layer recorded, no double-write). Use for create-style mutations where you've already awaited the server response.
- `OptimisticTransaction.commit<O: OperationData>(_:)` — typed overload that wraps `data.__data` into the JSON shape the underlying closure expects.
- `addNode<N: OperationData, F: Fragment>(node:fragment:options:)` — plan-aware connection insert. Walks the fragment plan to (a) initialize nested `@connection` canonicals, (b) stamp `__typename` from `F.onTypename`, (c) strip selection-set fields from the entity-record patch (two-pass: plan-aware + shape-aware) so existing ref/refList links survive a merge.
- `ConnectionAPI.patch { prev in … }` — closure-form connection patch for read-modify-write on canonical scalars (parity with cachebay-web `c.patch(prev => ({...}))`).
- `Optimistic.replay(connectionKeys:) -> ReplayResult` — exposes `{added, removed}` entity sets from replayed layers (parity with cachebay-web `replayOptimistic`).
- Logger plumbing on `CachebayClient` for runtime diagnostics (materialize misses, watcher silencing).

### Changed
- Soft scalar materialize miss downgraded from `.warning` to `.debug` log level — was spamming Error-level lines for the harmless cursor-on-optimistic-edge case.
- `CachebayClient.{graph, planner, canonical, documents, queries, fragments, optimistic, operations}` properties now `internal` (still accessible from tests via `@testable`). Public surface narrowed to `inspect` + `storage` + the typed methods on the client itself. Reduces the SemVer-able surface.
- Removed unused `CachebayCodegen` library product and the `cachebay-cli` Swift executable stub from `Package.swift`. The actual codegen is the Rust binary in `cli/`.

### Tests
- Test suite cross-checks behavior with cachebay-web file-by-file: documents (normalize/materialize/rootId), operations (queries/mutations/subscriptions × cache policies × invalidation × watcher state), queries (watchers, refcount), optimistic (entity, connection, fragment-plan-aware, layering, two-phase commit), canonical (pagination/leader/edge cases/replay), compiler (planner/metadata/dedupe/operations/connections/formats/fragments), performance (render-count assertions), integration (typed-API doc routing, evictAll, connection watcher).
- 608 tests across the suite. CI runs on every PR via `.github/workflows/test.yml`.

[Unreleased]: https://github.com/lockvoid/cachebay-ios/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/lockvoid/cachebay-ios/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/lockvoid/cachebay-ios/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/lockvoid/cachebay-ios/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/lockvoid/cachebay-ios/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/lockvoid/cachebay-ios/releases/tag/v0.1.0
