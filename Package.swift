// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Canopy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Canopy", targets: ["Canopy"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-extras.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Canopy",
            dependencies: ["CanopyEngine"],
            path: "Sources",
            exclude: ["README.md", "Info.plist", "CanopyEngine", "SwiftTorrent"],
            resources: [.process("Assets.xcassets")]
        ),
        .target(
            name: "CanopyEngine",
            dependencies: ["SwiftTorrent"],
            path: "Sources/CanopyEngine"
        ),
        .target(
            name: "SwiftTorrent",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOExtras", package: "swift-nio-extras"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/SwiftTorrent"
        ),
        .testTarget(
            name: "CanopyTests",
            dependencies: ["Canopy"],
            path: "Tests",
            exclude: ["CanopyEngine"]
        ),
    ]
)
