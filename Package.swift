// swift-tools-version:5.9
import PackageDescription

// Apple Silicon Homebrew prefix (this project targets arm64 Macs).
// On Intel Macs change this to "/usr/local".
let brewPrefix = "/opt/homebrew"

let package = Package(
    name: "Canopy",
    platforms: [.macOS(.v14)],
    targets: [
        // Objective-C++ wrapper around libtorrent-rasterbar.
        // Public headers are pure Objective-C so Swift can import the module;
        // all libtorrent/Boost C++ types stay hidden inside the .mm file.
        .target(
            name: "LibtorrentKit",
            cxxSettings: [
                .unsafeFlags([
                    "-I\(brewPrefix)/include",
                    "-fobjc-arc",
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(brewPrefix)/lib",
                    "-ltorrent-rasterbar",
                ]),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .executableTarget(
            name: "Canopy",
            dependencies: ["LibtorrentKit"]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
