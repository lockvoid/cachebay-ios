// swift-tools-version:6.0
import PackageDescription
import CompilerPluginSupport

let strictSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "Cachebay",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        // Runtime client. The library every consumer imports.
        .library(name: "Cachebay", targets: ["Cachebay"]),
        // Standalone GraphQL parser/printer. Only needed if you
        // compile GraphQL strings at runtime; codegen handles every
        // operation by default.
        .library(name: "CachebayGraphQL", targets: ["CachebayGraphQL"]),
        // Macro declarations (v1.0 typed structs). Consumers get these
        // re-exported from `Cachebay`; exposed as a product for codegen output.
        .library(name: "CachebayMacros", targets: ["CachebayMacros"]),
    ],
    dependencies: [
        // Swift macro support. 602.x matches the Swift 6.2 toolchain.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
    ],
    targets: [
        .target(
            name: "CachebayGraphQL",
            path: "Sources/CachebayGraphQL",
            swiftSettings: strictSettings
        ),
        .target(
            name: "Cachebay",
            dependencies: ["CachebayGraphQL"],
            path: "Sources/Cachebay",
            swiftSettings: strictSettings
        ),
        // The compiler plugin implementing the v1.0 macros. Host-side tooling;
        // no deployment target, default language mode to avoid SwiftSyntax
        // strict-concurrency noise.
        .macro(
            name: "CachebayMacrosImpl",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/CachebayMacrosImpl"
        ),
        // Public macro declarations. Emits the fully-qualified `Cachebay.JSONValue`
        // so this module needs no runtime dependency (no Cachebay <-> Macros cycle).
        .target(
            name: "CachebayMacros",
            dependencies: ["CachebayMacrosImpl"],
            path: "Sources/CachebayMacros",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "CachebayGraphQLTests",
            dependencies: ["CachebayGraphQL"],
            path: "Tests/CachebayGraphQLTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "CachebayTests",
            dependencies: ["Cachebay", "CachebayGraphQL", "CachebayMacros"],
            path: "Tests/CachebayTests",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "CachebayMacrosTests",
            dependencies: [
                "CachebayMacros",
                "CachebayMacrosImpl",
                "Cachebay",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            path: "Tests/CachebayMacrosTests",
            swiftSettings: strictSettings
        ),
    ]
)
