// swift-tools-version: 6.2
import PackageDescription

/// What the Xcode project compiles Oby's Swift with, so Engine/ compiles the same way here.
let features: [SwiftSetting] = [
    "MemberImportVisibility", "BareSlashRegexLiterals",
    // SWIFT_APPROACHABLE_CONCURRENCY, spelled out.
    "DisableOutwardActorInference", "GlobalActorIsolatedTypesUsability", "InferIsolatedConformances",
    "InferSendableFromCaptures", "NonisolatedNonsendingByDefault",
].map { .enableUpcomingFeature($0) }

let package = Package(
    name: "Oby",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.27.1"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.0"),
    ],
    targets: [
        // Linux has no SQLite3 module; macOS does.
        .systemLibrary(name: "CSQLite", path: "Runner/CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(
            name: "ObyEngine",
            dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux]))],
            path: "Engine",
            // ponytail: the runner reads the engine with @testable import rather than a public API,
            // so release builds need testing on too. Make the API public if Engine ships on its own.
            swiftSettings: features + [.defaultIsolation(MainActor.self), .unsafeFlags(["-enable-testing"])]
        ),
        .executableTarget(
            name: "oby-runner",
            dependencies: [
                "ObyEngine",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
            ],
            path: "Runner",
            exclude: ["CSQLite", "README.md", "oby-runner.service"],
            swiftSettings: features
        ),
        // The apps' Shared/ code the runner's tests cover; the rest of Shared/ needs the apps.
        .target(name: "ObyShared", path: "Shared", sources: ["Elapsed.swift", "JobList.swift", "Usage.swift", "WidgetToken.swift"], swiftSettings: features),
        .testTarget(
            name: "RunnerTests",
            dependencies: [
                "oby-runner", "ObyEngine", "ObyShared",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "RunnerTests",
            swiftSettings: features
        ),
    ],
    swiftLanguageModes: [.v5]
)
