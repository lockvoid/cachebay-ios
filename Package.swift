// swift-tools-version:6.0
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .swiftLanguageMode(.v6),
]

let package = Package(
    name: "Cachebay",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        // Runtime client. The library every consumer imports.
        .library(name: "Cachebay", targets: ["Cachebay"]),
        // Standalone GraphQL parser/printer. Only needed if you
        // compile GraphQL strings at runtime; codegen handles every
        // operation by default.
        .library(name: "CachebayGraphQL", targets: ["CachebayGraphQL"]),
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
    ]
)
