#!/usr/bin/env swift

import Foundation
import AppKit

let app = "Canopy.app"
let bundle = "\(app)/Contents"

print("Building for production...")

// Build
let buildProcess = Process()
buildProcess.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
buildProcess.arguments = ["build", "-c", "release"]
buildProcess.currentDirectoryURL = URL(fileURLWithPath: ".")
let buildOut = Pipe()
let buildErr = Pipe()
buildProcess.standardOutput = buildOut
buildProcess.standardError = buildErr

try buildProcess.run()
buildProcess.waitUntilExit()

if buildProcess.terminationStatus != 0 {
    print("Build failed!")
    let errData = buildErr.fileHandleForReading.readDataToEndOfFile()
    if let err = String(data: errData, encoding: .utf8) {
        print(err)
    }
    exit(1)
}

// Create .app structure
try? FileManager.default.removeItem(atPath: app)
try FileManager.default.createDirectory(atPath: "\(bundle)/MacOS", withIntermediateDirectories: true)
try FileManager.default.createDirectory(atPath: "\(bundle)/Resources", withIntermediateDirectories: true)

// Copy binary
try FileManager.default.copyItem(atPath: ".build/release/Canopy", toPath: "\(bundle)/MacOS/Canopy")

// Copy app icon
try FileManager.default.copyItem(atPath: "Sources/Resources/AppIcon.icns", toPath: "\(bundle)/Resources/AppIcon.icns")

// Write Info.plist
let infoPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Canopy</string>
    <key>CFBundleIdentifier</key>
    <string>com.canopy.app</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.3.2</string>
    <key>CFBundleExecutable</key>
    <string>Canopy</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
"""

try infoPlist.write(toFile: "\(bundle)/Info.plist", atomically: true, encoding: .utf8)

// Code sign - create entitlements first
let entitlements = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
</dict>
</plist>
"""

let entitlementsPath = "/tmp/canopy.entitlements"
try entitlements.write(toFile: entitlementsPath, atomically: true, encoding: .utf8)

let codeSignProcess = Process()
codeSignProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
codeSignProcess.arguments = ["--force", "--deep", "--sign", "-", "--entitlements", entitlementsPath, app]
let codeSignOut = Pipe()
codeSignProcess.standardOutput = codeSignOut

try codeSignProcess.run()
codeSignProcess.waitUntilExit()

print("Built: \(app)")
NSWorkspace.shared.open(URL(fileURLWithPath: app))