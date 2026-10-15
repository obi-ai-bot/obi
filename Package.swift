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
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.36.0"),
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
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ],
            path: "Runner",
            // The launchd plist is the Mac app's (apps/Oby.xcodeproj bundles it with the executable, #283).
            exclude: ["CSQLite", "README.md", "oby-runner.service", "com.deskree.oby.runner.plist"],
            swiftSettings: features
        ),
        // Oby's runner as an MCP server over stdio, for Claude Code and other assistants (docs/mcp.md).
        .executableTarget(name: "oby-mcp", path: "mcp/server", swiftSettings: features),
        // The apps/shared/ code the runner's tests cover; the rest of apps/shared/ needs the apps.
        .target(name: "ObyShared", path: "apps/shared", sources: ["Elapsed.swift", "JobList.swift", "RemoteRoute.swift", "Usage.swift", "VoiceSettings.swift", "WidgetToken.swift"], swiftSettings: features),
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
        .testTarget(name: "MCPTests", dependencies: ["oby-mcp"], path: "mcp/tests", swiftSettings: features),
    ],
    swiftLanguageModes: [.v5]
)
