// swift-tools-version: 6.0

import PackageDescription

let libtorrentPrefix = "/opt/homebrew/opt/libtorrent-rasterbar"

let package = Package(
    name: "Canopy",
    platforms: [.macOS(.v15)],
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
            exclude: ["Engine/Bridge", "README.md"],
            resources: [.process("Assets.xcassets")],
            swiftSettings: [
                .interoperabilityMode(.C),
            ]
        ),
    ]
)
