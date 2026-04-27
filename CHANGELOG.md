# Changelog

All notable changes to Cachebay-iOS are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
- 608+ tests across the suite. CI runs on every PR via `.github/workflows/test.yml`.

## [0.1.0] — Initial public release

First public version. The library was developed and battle-tested as part of the Ferment Cuts iOS app before being extracted; coverage parity with cachebay-web is locked in by the suite.

[Unreleased]: https://github.com/lockvoid/cachebay-ios/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/lockvoid/cachebay-ios/releases/tag/v0.1.0
