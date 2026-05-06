// swift-tools-version: 5.10

import PackageDescription

let libtorrentPrefix = "/opt/homebrew/opt/libtorrent-rasterbar"

let package = Package(
    name: "Canopy",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Canopy", targets: ["Canopy"])
    ],
    targets: [
        .target(
            name: "ClibtorrentBridge",
            path: "Sources/Engine/Bridge/ObjC",
            sources: ["LibtorrentWrapper.mm"],
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags([
                    "-std=c++17",
                    "-I\(libtorrentPrefix)/include",
                    "-I/opt/homebrew/opt/boost/include",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-lc++",
                    "\(libtorrentPrefix)/lib/libtorrent-rasterbar.dylib",
                ]),
            ]
        ),
        .executableTarget(
            name: "Canopy",
            dependencies: ["ClibtorrentBridge"],
            path: "Sources",
            exclude: ["Engine/Bridge", "README.md", "Info.plist", "CanopyEngine", "LiveDownload", "SeedOnly", "LeechOnly"],
            resources: [.process("Assets.xcassets")],
            swiftSettings: [
                .interoperabilityMode(.C),
            ]
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
        .executableTarget(
            name: "LiveDownload",
            dependencies: ["CanopyEngine"],
            path: "Sources/LiveDownload"
        ),
        .executableTarget(
            name: "SeedOnly",
            dependencies: ["CanopyEngine"],
            path: "Sources/SeedOnly"
        ),
        .executableTarget(
            name: "LeechOnly",
            dependencies: ["CanopyEngine"],
            path: "Sources/LeechOnly"
        ),
    ]
)
