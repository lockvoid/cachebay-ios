// swift-tools-version:6.2
import PackageDescription
import CompilerPluginSupport
import Foundation

let strictSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .swiftLanguageMode(.v6),
]

// MARK: - Codegen plugin: dev (local binary) vs release (GitHub artifact)
//
// `cachebay-cli` is a Rust binary SwiftPM can't compile, so it ships as a
// prebuilt `binaryTarget` artifact bundle. The mode is chosen by the
// `CACHEBAY_CLI` environment variable:
//
//   off      (default) — no plugin/binaryTarget; `swift build`/`test` untouched.
//   local              — use Artifacts/cachebay-cli.artifactbundle, built by
//                        `scripts/build-cli-bundle.sh` (CLI development).
//   release            — download the notarized bundle from the GitHub Release
//                        (what consumers get).
//
// FIRST-RELEASE ACTIVATION: once the release workflow has published a bundle,
// change `defaultCLIMode` to "release" and set `cliReleaseChecksum` below; the
// plugin then "just works" for consumers with no env var. (The release workflow
// does this edit automatically — see .github/workflows/release-cli.yml.)
let defaultCLIMode = "off"
let cliMode = ProcessInfo.processInfo.environment["CACHEBAY_CLI"] ?? defaultCLIMode

let cliRepo = "lockvoid/cachebay-ios"          // GitHub <owner>/<repo> for release assets
let cliReleaseTag = "v1.2.0"                    // tag whose bundle we pin
let cliReleaseChecksum = "REPLACE_AT_FIRST_RELEASE" // swift package compute-checksum output

var products: [Product] = [
    // Runtime client. The library every consumer imports.
    .library(name: "Cachebay", targets: ["Cachebay"]),
    // Standalone GraphQL parser/printer. Only needed if you
    // compile GraphQL strings at runtime; codegen handles every
    // operation by default.
    .library(name: "CachebayGraphQL", targets: ["CachebayGraphQL"]),
    // SwiftUI integration: the @CachebayQuery property wrapper. Optional —
    // import only in SwiftUI targets so the core stays framework-agnostic.
    .library(name: "CachebayUI", targets: ["CachebayUI"]),
    // Ably realtime transport: a `WSTransport` backed by Ably channels, for
    // backends that deliver GraphQL subscriptions over Ably. Optional — only
    // consumers that add this product pull in ably-cocoa (target-based
    // resolution keeps it out of core `Cachebay`'s dependency graph).
    .library(name: "CachebayAbly", targets: ["CachebayAbly"]),
]

var targets: [Target] = [
    .target(
        name: "CachebayGraphQL",
        path: "Sources/CachebayGraphQL",
        swiftSettings: strictSettings
    ),
    // Runtime client + the v1.0 macro declarations (re-exported to consumers
    // via `import Cachebay`). The macro *implementation* is the separate
    // `.macro` plugin below — required to be its own compiler-plugin target.
    .target(
        name: "Cachebay",
        dependencies: [
            "CachebayGraphQL",
            "CachebayMacros",
            // Phase 1: yyjson is the JSON ⇄ bytes codec (parse edges +
            // SQLite hydration). The normalized store, refs, materialize,
            // and the macro decode contract all stay on JSONValue.
            .product(name: "yyjson", package: "yyjson"),
        ],
        path: "Sources/Cachebay",
        swiftSettings: strictSettings
    ),
    // The compiler plugin implementing the v1.0 macros. Host-side tooling;
    // no deployment target, default language mode to avoid SwiftSyntax
    // strict-concurrency noise.
    .macro(
        name: "CachebayMacros",
        dependencies: [
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        ],
        path: "Sources/CachebayMacros"
    ),
    .testTarget(
        name: "CachebayGraphQLTests",
        dependencies: ["CachebayGraphQL"],
        path: "Tests/CachebayGraphQLTests",
        swiftSettings: strictSettings
    ),
    .testTarget(
        name: "CachebayTests",
        dependencies: ["Cachebay", "CachebayGraphQL"],
        path: "Tests/CachebayTests",
        swiftSettings: strictSettings
    ),
    .target(
        name: "CachebayUI",
        dependencies: ["Cachebay"],
        path: "Sources/CachebayUI",
        swiftSettings: strictSettings
    ),
    // Ably realtime transport. Depends on `Cachebay` (the `WSTransport`
    // protocol) + ably-cocoa. Isolated so non-Ably consumers don't pull Ably.
    .target(
        name: "CachebayAbly",
        dependencies: [
            "Cachebay",
            .product(name: "Ably", package: "ably-cocoa"),
        ],
        path: "Sources/CachebayAbly",
        swiftSettings: strictSettings
    ),
    .testTarget(
        name: "CachebayAblyTests",
        dependencies: ["CachebayAbly", "Cachebay"],
        path: "Tests/CachebayAblyTests",
        swiftSettings: strictSettings
    ),
    .testTarget(
        name: "CachebayUITests",
        dependencies: ["CachebayUI", "Cachebay"],
        path: "Tests/CachebayUITests",
        swiftSettings: strictSettings
    ),
    .testTarget(
        name: "CachebayMacrosTests",
        dependencies: [
            "CachebayMacros",
            "Cachebay",
            .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
        ],
        path: "Tests/CachebayMacrosTests",
        swiftSettings: strictSettings
    ),
    // TEMP (perf spike): standalone bench, `swift run -c release YYBench`.
    // Depends on Cachebay so it can profile the *real* JSONValue codec
    // (`from(json:)`, etc.) plus raw yyjson for A/B comparisons. Drop this
    // target + Tools/YYBench once Phase 2 profiling concludes.
    .executableTarget(
        name: "YYBench",
        dependencies: [
            "Cachebay",
            .product(name: "yyjson", package: "yyjson"),
        ],
        path: "Tools/YYBench"
    ),
]

// Append the codegen plugin + its prebuilt-CLI binary target when enabled.
if cliMode != "off" {
    let cliTarget: Target
    switch cliMode {
    case "local":
        cliTarget = .binaryTarget(
            name: "cachebay-cli",
            path: "Artifacts/cachebay-cli.artifactbundle"
        )
    default: // "release"
        cliTarget = .binaryTarget(
            name: "cachebay-cli",
            url: "https://github.com/\(cliRepo)/releases/download/\(cliReleaseTag)/cachebay-cli.artifactbundle.zip",
            checksum: cliReleaseChecksum
        )
    }
    targets.append(cliTarget)
    targets.append(
        .plugin(
            name: "CachebayCodegen",
            capability: .command(
                intent: .custom(
                    verb: "cachebay-codegen",
                    description: "Generate typed Swift from .graphql via cachebay-cli"
                ),
                permissions: [
                    .writeToPackageDirectory(reason: "writes generated GraphQL Swift into your package")
                ]
            ),
            dependencies: ["cachebay-cli"],
            path: "Plugins/CachebayCodegen"
        )
    )
    products.append(.plugin(name: "CachebayCodegen", targets: ["CachebayCodegen"]))
}

let package = Package(
    name: "Cachebay",
    platforms: [
        // v1.0 minimums (proposal §10): iOS 18+. Macros require the Swift 6.2
        // toolchain (swift-syntax 602 / Xcode 26).
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: products,
    dependencies: [
        // Swift macro support. 602.x matches the Swift 6.2 toolchain.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
        // yyjson C JSON parser — Cachebay's JSON ⇄ bytes codec (Phase 1).
        // Used by the `Cachebay` target's parse/hydration/persist path.
        .package(url: "https://github.com/ibireme/yyjson.git", from: "0.12.0"),
        // Ably realtime SDK — used ONLY by the optional `CachebayAbly` target.
        // With SwiftPM target-based resolution, consumers that depend only on the
        // `Cachebay` product never fetch this.
        .package(url: "https://github.com/ably/ably-cocoa.git", from: "1.2.0"),
    ],
    targets: targets
)
