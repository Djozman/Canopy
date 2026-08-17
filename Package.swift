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

/// libtorrent changes C++ namespaces and exported symbols according to its
/// TORRENT_* build flags. Read the installed .pc file so the bridge always
/// compiles with the same ABI configuration as the linked Homebrew dylib.
func pkgConfigFlags(section: String, path: String) -> [String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        fatalError(
            "Missing libtorrent pkg-config metadata at \(path). "
                + "Run: brew install libtorrent-rasterbar boost"
        )
    }

    var variables: [String: String] = [:]
    var sectionValue: String?

    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("\(section):") {
            sectionValue = String(line.dropFirst(section.count + 1))
                .trimmingCharacters(in: .whitespaces)
            continue
        }
        guard let equals = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<equals])
        guard !key.contains(" "), !key.contains(":") else { continue }
        variables[key] = String(line[line.index(after: equals)...])
    }

    guard var expanded = sectionValue else {
        fatalError("Missing \(section) entry in \(path)")
    }

    // Variables may refer to other variables, such as libdir=${prefix}/lib.
    for _ in 0..<10 {
        let previous = expanded
        for (key, value) in variables {
            expanded = expanded.replacingOccurrences(of: "${\(key)}", with: value)
        }
        if expanded == previous { break }
    }

    return expanded.split(whereSeparator: { $0.isWhitespace }).map(String.init)
}

let pkgConfigPath = "\(libtorrentPrefix)/lib/pkgconfig/libtorrent-rasterbar.pc"
let libtorrentCFlags = pkgConfigFlags(section: "Cflags", path: pkgConfigPath)
let libtorrentLinkerFlags = pkgConfigFlags(section: "Libs", path: pkgConfigPath)

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
                .unsafeFlags(
                    [
                        "-std=c++17",
                        "-I\(boostPrefix)/include",
                        "-I\(opensslPrefix)/include",
                    ] + libtorrentCFlags
                ),
            ],
            linkerSettings: [
                .unsafeFlags(libtorrentLinkerFlags),
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
