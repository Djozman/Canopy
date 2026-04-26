#!/bin/bash
set -e

APP="Canopy.app"
BUNDLE="$APP/Contents"

# Build
swift build -c release 2>&1

# Create .app structure
rm -rf "$APP"
mkdir -p "$BUNDLE/MacOS" "$BUNDLE/Resources"

# Copy binary
cp .build/release/Canopy "$BUNDLE/MacOS/Canopy"

# App icon
cp Sources/Resources/AppIcon.icns "$BUNDLE/Resources/AppIcon.icns"

# Info.plist
cat > "$BUNDLE/Info.plist" << 'EOF'
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
EOF

# Re-sign with entitlements so macOS reads Info.plist for ATS
cat > /tmp/canopy.entitlements << 'ENTEOF'
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
ENTEOF

codesign --force --deep --sign - --entitlements /tmp/canopy.entitlements "$APP"

echo "Built: $APP"
open "$APP"
