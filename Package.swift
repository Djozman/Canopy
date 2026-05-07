// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Canopy",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Canopy", targets: ["Canopy"])
    ],
    targets: [
        .executableTarget(
            name: "Canopy",
            dependencies: ["CanopyEngine"],
            path: "Sources",
            exclude: ["README.md", "Info.plist", "CanopyEngine"],
            resources: [.process("Assets.xcassets")]
        ),
        .testTarget(
            name: "CanopyTests",
            dependencies: ["Canopy"],
            path: "Tests",
            exclude: ["CanopyEngine"]
        ),
        .target(
            name: "CanopyEngine",
            path: "Sources/CanopyEngine"
        ),
        .testTarget(
            name: "CanopyEngineTests",
            dependencies: ["CanopyEngine"],
            path: "Tests/CanopyEngine",
            resources: [.copy("TestTorrents")]
        ),
    ]
)
