// swift-tools-version:6.2
import PackageDescription
import CompilerPluginSupport

let strictSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .swiftLanguageMode(.v6),
]

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
    products: [
        // Runtime client. The library every consumer imports.
        .library(name: "Cachebay", targets: ["Cachebay"]),
        // Standalone GraphQL parser/printer. Only needed if you
        // compile GraphQL strings at runtime; codegen handles every
        // operation by default.
        .library(name: "CachebayGraphQL", targets: ["CachebayGraphQL"]),
        // SwiftUI integration: the @CachebayQuery property wrapper. Optional —
        // import only in SwiftUI targets so the core stays framework-agnostic.
        .library(name: "CachebayUI", targets: ["CachebayUI"]),
    ],
    dependencies: [
        // Swift macro support. 602.x matches the Swift 6.2 toolchain.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
        // yyjson C JSON parser — Cachebay's JSON ⇄ bytes codec (Phase 1).
        // Used by the `Cachebay` target's parse/hydration/persist path.
        .package(url: "https://github.com/ibireme/yyjson.git", from: "0.12.0"),
    ],
    targets: [
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
        // Depends only on yyjson (not Cachebay) so it builds fast and isolates
        // the JSONDecoder-vs-yyjson comparison. Drop this target + Tools/YYBench
        // once Phase 2 profiling concludes.
        .executableTarget(
            name: "YYBench",
            dependencies: [.product(name: "yyjson", package: "yyjson")],
            path: "Tools/YYBench"
        ),
    ]
)
