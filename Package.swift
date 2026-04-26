// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Canopy",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0")
    ],
    targets: [
        .executableTarget(
            name: "Canopy",
            dependencies: ["BigInt"],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("SystemConfiguration")
            ]
        )
    ]
)
