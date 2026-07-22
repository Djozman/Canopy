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
let opensslPrefix = "\(homebrewPrefix)/opt/openssl@3"

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
                // Homebrew libtorrent 2.1 enables WebTorrent/RTC and is built
                // against OpenSSL. Consumers must compile with the same backend.
                .define("TORRENT_USE_OPENSSL", to: "1"),
                .unsafeFlags([
                    "-std=c++17",
                    "-I\(libtorrentPrefix)/include",
                    "-I\(boostPrefix)/include",
                    "-I\(opensslPrefix)/include",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-lc++",
                    "-L\(opensslPrefix)/lib",
                    "-lssl",
                    "-lcrypto",
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
