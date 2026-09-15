// swift-tools-version: 5.10
import PackageDescription

let crypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))

let package = Package(
    name: "AutolithCompanion",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "autolith-bridge", targets: ["AutolithBridge"])],
    dependencies: [
        // Pin the dependency graph to releases compatible with Nix's Swift 5.10.
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.76.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.10.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", exact: "1.2.0"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.1.4"),
        .package(url: "https://github.com/apple/swift-system.git", exact: "1.4.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.3.0"),
    ],
    targets: [
        .target(name: "CBridgePOSIX"),
        .target(name: "ClientCore", dependencies: [crypto], path: "Shared"),
        .testTarget(name: "ClientCoreTests", dependencies: ["ClientCore"]),
        .target(name: "BridgeCore", dependencies: [crypto]),
        .executableTarget(name: "AutolithBridge", dependencies: [
            "BridgeCore", "ClientCore", "CBridgePOSIX", crypto,
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"]),
        .testTarget(name: "MessageServiceTests", dependencies: ["AutolithBridge", "ClientCore"]),
        .testTarget(name: "EventStreamTests", dependencies: ["AutolithBridge"]),
    ]
)
