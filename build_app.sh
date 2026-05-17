#!/bin/bash
set -e
cd "$(dirname "$0")"
swift build
rm -rf Canopy.app
mkdir -p Canopy.app/Contents/MacOS Canopy.app/Contents/Resources
cp .build/debug/Canopy Canopy.app/Contents/MacOS/
cp Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.icns Canopy.app/Contents/Resources/AppIcon.icns
cp Sources/Info.plist Canopy.app/Contents/Info.plist
plutil -replace CFBundleExecutable -string Canopy Canopy.app/Contents/Info.plist
plutil -replace CFBundleIdentifier -string com.canopy.client Canopy.app/Contents/Info.plist
plutil -replace CFBundleName -string Canopy Canopy.app/Contents/Info.plist
plutil -replace CFBundlePackageType -string APPL Canopy.app/Contents/Info.plist
plutil -replace CFBundleVersion -string 2.2 Canopy.app/Contents/Info.plist
plutil -replace CFBundleShortVersionString -string 2.2 Canopy.app/Contents/Info.plist
plutil -replace CFBundleIconFile -string AppIcon Canopy.app/Contents/Info.plist
chmod +x Canopy.app/Contents/MacOS/Canopy
touch Canopy.app
rm -rf /Applications/Canopy.app
cp -R Canopy.app /Applications/
killall Canopy 2>/dev/null || true
killall Finder Dock 2>/dev/null || true
echo "✓ Canopy.app → /Applications"
