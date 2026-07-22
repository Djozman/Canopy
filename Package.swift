// swift-tools-version: 5.10

import Foundation
import PackageDescription

let environment = ProcessInfo.processInfo.environment
#if arch(arm64)
let defaultHomebrewPrefix = "/opt/homebrew"
#else
let defaultHomebrewPrefix = "/usr/local"
#endif
let homebrewPrefix = environment["HOMEBREW_PREFIX"] ?? defaultHomebrewPrefix
let libtorrentPrefix = "\(homebrewPrefix)/opt/libtorrent-rasterbar"
let boostPrefix = "\(homebrewPrefix)/opt/boost"

let package = Package(
    name: "Canopy",
    platforms: [.macOS(.v14)],
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
                    "-I\(boostPrefix)/include",
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
            exclude: ["Engine/Bridge", "README.md", "Info.plist"],
            resources: [.process("Assets.xcassets")],
            swiftSettings: [
                .interoperabilityMode(.C),
            ]
        ),
        .testTarget(
            name: "CanopyTests",
            dependencies: ["Canopy"],
            path: "Tests"
        ),
    ]
)
