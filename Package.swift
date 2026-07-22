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
let hostMajorVersion = max(14, ProcessInfo.processInfo.operatingSystemVersion.majorVersion)

let package = Package(
    name: "Canopy",
    // Homebrew bottles are built for the host macOS release. Match that
    // deployment target to avoid linking a newer bottle into an older target.
    platforms: [.macOS("\(hostMajorVersion).0")],
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
                // Match the exact feature and ABI flags exported by Homebrew's
                // libtorrent-rasterbar.pc file.
                .define("TORRENT_LINKING_SHARED"),
                .define("BOOST_ASIO_ENABLE_CANCELIO"),
                .define("BOOST_ASIO_NO_DEPRECATED"),
                .define("BOOST_SYSTEM_USE_UTF8"),
                .define("_SILENCE_CXX17_ALLOCATOR_VOID_DEPRECATION_WARNING"),
                .define("TORRENT_ABI_VERSION", to: "2"),
                .define("TORRENT_USE_OPENSSL", to: "1"),
                .define("TORRENT_USE_LIBCRYPTO", to: "1"),
                .define("TORRENT_SSL_PEERS", to: "1"),
                .define("OPENSSL_NO_SSL2", to: "1"),
                .define("OPENSSL_NO_SSL3", to: "1"),
                .define("OPENSSL_NO_TLS1", to: "1"),
                .define("OPENSSL_NO_TLS1_1", to: "1"),
                .define("OPENSSL_NO_DTLS1", to: "1"),
                .unsafeFlags([
                    "-fexceptions",
                    "-std=c++17",
                    "-I\(libtorrentPrefix)/include",
                    "-I\(boostPrefix)/include",
                    "-I\(opensslPrefix)/include",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-lc++",
                    "-L\(libtorrentPrefix)/lib",
                    "-ltorrent-rasterbar",
                    "-L\(homebrewPrefix)/lib",
                    "-L\(opensslPrefix)/lib",
                    "-lssl",
                    "-lcrypto",
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
