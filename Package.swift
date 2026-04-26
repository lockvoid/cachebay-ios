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
        .library(name: "Cachebay", targets: ["Cachebay"]),
        .library(name: "CachebayGraphQL", targets: ["CachebayGraphQL"]),
        .library(name: "CachebayCodegen", targets: ["CachebayCodegen"]),
        .executable(name: "cachebay-cli", targets: ["cachebay-cli"]),
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
        .target(
            name: "CachebayCodegen",
            dependencies: ["Cachebay", "CachebayGraphQL"],
            path: "Sources/CachebayCodegen",
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "cachebay-cli",
            dependencies: ["CachebayCodegen"],
            path: "Sources/cachebay-cli",
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
        .testTarget(
            name: "CachebayCodegenTests",
            dependencies: ["CachebayCodegen"],
            path: "Tests/CachebayCodegenTests",
            swiftSettings: strictSettings
        ),
    ]
)
