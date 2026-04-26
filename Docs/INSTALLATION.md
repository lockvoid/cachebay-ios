# Installation

Cachebay is distributed as a SwiftPM package.

## Requirements

- Swift **6.0+** (uses strict concurrency — `@Sendable` everywhere)
- iOS **15.0+** / macOS **12.0+** / tvOS **15.0+** / watchOS **8.0+** / visionOS **1.0+**
- Xcode **15+** for the demo app target

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
