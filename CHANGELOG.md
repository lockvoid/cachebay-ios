# Changelog

All notable changes to Cachebay-iOS are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`URLSessionWebSocketTransport.ConnectionEvent.subscriptionsChanged(active: Int)`** — emitted on every live-subscription count transition. Fires on `subscribe()` registration (+1), per-subscription teardown via consumer cancel / server `complete` / server `error` (−1), and bulk drains via `disconnect()` / terminal `stopWithTerminalReason` (→ 0). It does NOT fire on the auto-reconnect cycle (subscriptions are preserved across the gap), nor on the internal `.pending → .subscribed` status flip (count is unchanged), nor on bulk drains of an already-empty registry (no spurious 0→0 events).

  Use it to drive UI ("N subscriptions live"), telemetry, or to gate background-refresh logic on whether anything is listening.

  The `active` payload is captured **under `lock`** at the moment of the mutation — concurrent register/unregister callers can't reorder the count sequence consumers observe. (Internal: introduces an `emitLocked(_:)` helper that yields without releasing the lock; safe because `AsyncStream.Continuation.yield` is non-blocking and `onTermination` runs from the consumer's task, not synchronously from yield.)

### Source compatibility
- The new enum case is **source-breaking for downstream `switch` statements that don't have a `default` / `@unknown default`**. The cachebay-shipped consumer wiring example in `Docs/SUBSCRIPTIONS.md` was updated to fold the new case into the existing no-op branch.

## [0.6.0] — Pure-fragment-spread reuse in codegen

### Added
- **Codegen detects pure fragment spreads and reuses the fragment's emitted `Data` type at the parent position**, instead of emitting a structurally-identical fresh nested struct per query that spreads it. When a field's selection set is exactly `{ ...FragmentName }` (with no extra fields beyond the spread; user-written `__typename` is tolerated), the parent's typed accessor returns `[FragmentName.Data]` / `FragmentName.Data?` directly.

  ```swift
  // Before:
  public struct ProjectFields {
      public struct Data {
          public struct Elements: OperationData { … 460 lines of duplicate Element machinery … }
          public var elements: [Elements] { … }
      }
  }

  // After:
  public struct ProjectFields {
      public struct Data {
          public var elements: [ElementFields.Data] { … }
      }
  }
  ```

  The duplicate `AsVideoElement` / `AsAudioElement` / `AsImageElement` accessor trees and the duplicate factory methods at every parent position collapse to a single canonical site. Concretely in the `ferment-cuts-ios` consumer: `UserMessageFields.cachebay.swift` shrank from **1023 lines to 460** (-55%); `ProjectFields.cachebay.swift` shrank similarly. Every consumer-side converter that took `Project.Data.Project.Elements` *or* `UserMessageFields.Data.Attachments` *or* `ElementFields.Data` (three identical types) is now a single converter taking `ElementFields.Data`. **Polymorphic helpers across queries become possible** — a function that wants an Element from chat OR from a project query takes the same typed argument.

### Detection rule
- The position's selection set must contain exactly one `FragmentSpread` and zero other selections (Field / InlineFragment), with `__typename` field selections at the parent scope tolerated since cachebay auto-injects them anyway.
- Multiple spreads on the same position, inline fragments at the parent scope, or any extra named field at the parent scope → fall back to the v0.5.0 "fresh nested struct + factories" behavior. Detection happens against the AST before lowering; once selections are merged, the property is irrecoverable.

### Migration
- **Source-breaking** for consumers who explicitly named the per-position type (e.g. `Project.Data.Project.Elements` → no longer exists, use `[ElementFields.Data]`). Callers using `for el in project.elements` without naming the element type are transparent. In `ferment-cuts-ios` this was ~10 sites; bulk-replace with `perl -pi -e` and the build catches the rest.
- **Rerun `cachebay-cli` codegen** to pick up the dedup. v0.5.0 factories on per-position structs disappear for fields that now reuse the fragment type — call `FragmentName.Data.<subtype>(...)` from the canonical site.

### Precedent
- Relay-compiler reuses fragment data types directly at pure-spread positions; Apollo iOS solves the same problem via per-fragment protocol conformance. Cachebay matches Relay's simpler approach: the fragment's `Data` IS the reused type at every spread site.

## [0.5.0] — Compile-time fragment data factories

### Added
- **Codegen-emitted static factories on every generated `Data` / `AsX` struct.** Polymorphic fragments emit one factory per type-condition (`ProjectMessageFields.Data.projectUserMessage(...)`, `ElementFields.Data.videoElement(...)`); plain fragments emit a single `Data.make(...)`. Every selected non-null field is a required named parameter; nullable selections get `= nil` defaults. `__typename` is hardcoded into the dict body so callers never thread a typename string. Forgetting a required field is a compile error at the call site, replacing the v0.4.0 silent-watcher-silence failure mode where a missing selection-set field would only surface as a debug-level "no field" log at runtime.

  ```swift
  let element = ElementFields.Data.videoElement(
      id: att.id, kind: "video", state: "draft", intent: "STORY",
      name: att.name, derivatives: [], lockVersion: 1,
      colorSpace: v.colorSpace,
      music: 0, speech: 1, noise: 0,
      beatsAnalyzed: false, musicHighlighted: false, speechTranscribed: false,
      beats: [], downbeats: [], quantizedBeats: [], quantizedDownbeats: [],
      musicHighlights: []
      // duration, width, height, rotation, aiPrompt, content, … all optional, default nil
  )
  ```

  Mirroring `AsX` factories also emit at the subtype-struct level (`AsVideoElement.make(...)`) for callers who already have an `AsX` and want a sibling.

  At parent scope, subtype-specific nested types are qualified with `AsX.` (e.g. `[AsAudioElement.MusicHighlights]`) so they resolve outside the subtype struct. Shared nested types stay unqualified — they live as siblings on the parent.

### Migration
- **Rerun `cachebay-cli` codegen** to pick up the new factories. Existing `F.Data(__data: [...])` call sites continue to compile; opt-in to the typed factories one call site at a time.

## [0.4.0] — Optimistic `writeFragment` (normalize-with-baselines)

### Added
- **`OptimisticBuilder.writeFragment(...)`** — plan-aware optimistic write that walks the fragment plan + data, captures baselines for every entity record it touches, and normalizes nested entities (single + list) into separate cache records linked by `.ref` / `.refList`. Mirrors `CachebayClient.writeFragment` but goes through the optimistic layer — `revert()` / `dispose()` work, layered commit replays surviving siblings correctly. Use for OPTIMISTIC CREATE flows where a fresh entity tree is built client-side (e.g. an outbound chat message + its attachments). The strict materializer requires `.ref` / `.refList` for selection-set link fields, so embedded objects (`.array of .object`) silence the watcher with "unexpected link shape" — `writeFragment` produces the right shape automatically.

  ```swift
  client.modifyOptimistic { b, _ in
      b.writeFragment(fragment: ProjectMessageFields.self, id: userId, data: messageData)
  }
  ```

  Exposed in two forms: a JSON-shaped primitive on the protocol (`document:fragmentName:rootId:variables:data:`), and typed extensions in `Optimistic+Typed.swift` (`fragment:id:[variables:]data:`). The variable-less overload covers fragments with `Variables == EmptyVariables`.

### Limitation
- Only entity-shaped records (objects with `__typename + id`) get baselines captured. Inline-container synthetic keys (e.g. `Element:42.derivatives.0`) write into the graph but aren't tracked for revert. For fresh-create flows this is harmless (no prior state to restore); flows that optimistically MUTATE pre-existing inline containers should stay on `b.patch(...)`.

### Internals
- `Optimistic.init(graph:planner:documents:)` now takes the `Documents` engine so the optimistic layer can route writes through `documents.normalize` while injecting baseline captures. Pre-1.0 internal-only signature change; `CachebayClient.init` is the only caller.

## [0.3.3] — Stable codegen source paths

### Fixed
- **Generated `// Source:` and `/// Fragment X:` headers now use paths relative to `--operations`** instead of absolute paths into the caller's staging tempdir. Wrappers (e.g. `ferment-cuts-ios`'s `Scripts/cachebay-codegen`) typically copy operations into a randomized `/var/folders/.../cachebay-codegen-XXXXXX.<random>/` tree before invoking the cli; embedding that path in every emitted file caused two problems: (a) leaked the host's tempdir layout into checked-in code, and (b) churned every generated file's diff on every codegen run as the random suffix changed. Now an emitted header reads `// Source: Fragments/ProjectFragment.graphql` regardless of where the cli was invoked from. Path resolution canonicalizes both the operations roots and each file before stripping the prefix, so symlinks (e.g. macOS `/var` → `/private/var`) don't defeat the match.

## [0.3.2] — Reconnector resurrection race; test-seam handshake; CI perf threshold

### Fixed
- **`startReconnector` could resurrect after `.stopped`.** Race window: a delayed `receiveLoopError` from a now-dead socket can land in `handleUnexpectedDisconnect` after `stopWithTerminalReason` has nulled `reconnectorTask` and flipped state to `.stopped`. The disconnect path's `startReconnector` call only checked `reconnectorTask != nil`, not state — so it would spawn a fresh reconnector and emit one bonus `.reconnectScheduled(attempt: 1, ...)` past the terminal `.stopped` event. `test_reconnect_emitsReconnectScheduledEvents_withGrowingDelays` flaked at ~30–60% on macOS runners. Fixed by guarding `startReconnector` against `.stopped` state — public `reconnect()` paths resurrect state out of `.stopped` before calling, so they're not blocked. Pre-existing bug; deterministic across 30/30 stress runs after fix.
- **`takeConnectionState` opened a real WebSocket task even when test seams were active.** `test_subscribeDuringConnecting_doesNotDoubleSubscribeOnAck` would race the real (failing) handshake against the test's injected `connection_ack` and pass locally / fail on slower CI runners. Added `.testSeamConnect` decision: when an outbound sink is installed, drive the handshake through the sink without opening a real socket.

### Tests
- `test_perf_addNode_preload_5000_tail_latency` p99/p50 ratio threshold raised from 5× to 10×. Local M-series runners land at ~1.3×; GitHub-hosted macos-15 shared hardware routinely hits 4–6× under noisy-neighbour load. 10× still catches pathological regressions (e.g. an O(n²) regression that would push the ratio past 20×).

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

[Unreleased]: https://github.com/lockvoid/cachebay-ios/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/lockvoid/cachebay-ios/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/lockvoid/cachebay-ios/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/lockvoid/cachebay-ios/compare/v0.3.3...v0.4.0
[0.3.3]: https://github.com/lockvoid/cachebay-ios/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/lockvoid/cachebay-ios/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/lockvoid/cachebay-ios/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/lockvoid/cachebay-ios/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/lockvoid/cachebay-ios/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/lockvoid/cachebay-ios/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/lockvoid/cachebay-ios/releases/tag/v0.1.0
