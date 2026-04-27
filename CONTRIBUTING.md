# Contributing to Cachebay-iOS

Thanks for your interest. This is a Swift port of [cachebay-web](https://github.com/lockvoid/cachebay), so behavior parity with the web version is the bar — anything that diverges needs a deliberate justification.

## Getting set up

```sh
git clone https://github.com/lockvoid/cachebay-ios
cd cachebay-ios
swift test                   # runs the full suite (608+ tests)
```

Requirements:
- Swift 6.0+
- macOS 14+ (Linux not yet supported)
- Rust toolchain — only if you touch the codegen CLI (`cli/`)

## Running the demo

```sh
# Server (Node 18+, pnpm, brew install xcodegen)
cd demo/server && pnpm install && pnpm start

# iOS client
cd ../ios && make all && open HarryPotterDemo.xcodeproj
```

## Project layout

| Path | Purpose |
|---|---|
| `Sources/Cachebay/` | The runtime client. Public API + internal subsystems. |
| `Sources/CachebayGraphQL/` | Standalone GraphQL parser/printer. Used at runtime only when callers compile GraphQL strings; codegen handles the common case. |
| `cli/` | Rust binary that emits Swift typed structs from `.graphql` files. |
| `Tests/CachebayTests/` | Unit + integration + performance tests, mirroring `Sources/Cachebay/` structure. |
| `demo/` | Working SwiftUI demo app + Node GraphQL server. |
| `Docs/` | Per-topic markdown docs. |

## Patterns expected of contributions

- **Tests first when fixing bugs.** Write a failing test that pins the bug, then fix. The user-facing rule: tests should fail before the fix and pass after.
- **Cross-check with cachebay-web** when adding/changing semantics. The web tests at `cachebay/packages/cachebay/test/` are the reference; if iOS diverges, document why in the source comment.
- **Strict concurrency.** Swift 6 mode is enabled. Every public type must be `Sendable`; lock-protected internals use `NSLock`/`NSRecursiveLock` with locking discipline documented near the lock declaration. No `@MainActor` on library types.
- **No `Self.foo` in stored property initializers.** Use `TypeName.foo` to avoid Swift 6 errors.
- **Public API discipline.** Anything `public` is SemVer-able. Subsystems internal-only get accessed by tests via `@testable import Cachebay`.
- **Doc comments on public types.** One-line `///` summary minimum; richer doc for entry-point types.

## Pull request flow

1. Fork, branch from `main`.
2. `swift test` must pass locally and in CI.
3. Update `CHANGELOG.md` under `## [Unreleased]` describing what changed.
4. If you change public API, update `Docs/` to match.
5. Open a PR; describe the bug or feature in plain English (server response shape, user-visible behavior, etc.) — not just the diff.

## Codegen changes

If you touch `cli/` (the Rust generator):

```sh
cd cli && cargo build --release
cd ../demo/ios && make codegen   # regenerate demo's Generated/
swift test                        # ensure runtime still agrees with emitted output
```

Generated output should be identical between runs given the same inputs (deterministic order, stable hashing).

## Performance regressions

The performance suite (`Tests/CachebayTests/Performance/`) has render-count and throughput assertions. If you suspect a regression, run:

```sh
swift test --filter Performance
```

For micro-benchmarks against Apollo iOS as a baseline, see `perf/` (kept as a separate SwiftPM package because it depends on Apollo).

## Reporting bugs

Open an issue with:
- Cachebay-iOS version
- Swift / Xcode versions
- Minimal repro: a `swift test`-style failing case is best
- Server response shape if relevant

## License

By contributing, you agree your contributions are licensed under the [MIT License](./LICENSE).
