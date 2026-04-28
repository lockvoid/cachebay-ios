# Installation

Cachebay is distributed as a SwiftPM package.

## Requirements

- Swift **6.0+** (uses strict concurrency — `@Sendable` everywhere)
- iOS **16.0+** / macOS **13.0+** / tvOS **16.0+** / watchOS **9.0+** / visionOS **1.0+**
- Xcode **15+** for the demo app target

The platform floor is set at `Duration` / `Clock` / `Task.sleep(for:)` (iOS 16 / macOS 13). Cachebay uses these in its reconnect orchestrator and elsewhere; supporting earlier OS versions would mean a meaningfully different codebase. If you're targeting iOS 15, pin to a pre-1.0 tag.

## Add the package

In your app's `Package.swift`:

```swift
// Package.swift
let package = Package(
    name: "MyApp",
    dependencies: [
        .package(url: "https://github.com/lockvoid/cachebay-ios", from: "0.1.0"),
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "Cachebay", package: "cachebay-ios"),
            ]
        ),
    ]
)
```

Or in Xcode: **File → Add Package Dependencies… →** paste the URL → choose `Cachebay`.

## Optional products

| Product            | When you need it                                       |
| ------------------ | ------------------------------------------------------ |
| `Cachebay`         | Always — the runtime client.                            |
| `CachebayGraphQL`  | Only if you parse GraphQL strings at runtime (rare — codegen handles every operation by default). |

The `cachebay-cli` codegen tool lives in [`cli/`](../cli/) — built from the same repo, distributed as a Rust binary. See [CODEGEN.md](./CODEGEN.md).

## Verify

```swift
import Cachebay

let client = CachebayClient(options: CachebayOptions(
    transport: Transport(http: URLSessionHTTPTransport(url: URL(string: "https://example.com/graphql")!))
))
print(client)   // CachebayClient
```

## Next steps

Continue to [SETUP.md](./SETUP.md) to wire transports, identity, and persistence.
