#!/usr/bin/env bash
# Builds Canopy with SwiftPM and wraps the binary into a .app bundle.
# Works with the Command Line Tools only (no full Xcode needed).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Canopy"
BUNDLE_ID="com.djozman.canopy"

# Parse args: optional config (debug|release) and --run flag.
CONFIG="debug"
RUN=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --run) RUN=1 ;;
    *) echo "unknown arg: $arg" ;;
  esac
done

# 1. Verify libtorrent is installed (Homebrew).
BREW_PREFIX="/opt/homebrew"
if ! ls "$BREW_PREFIX"/lib/libtorrent-rasterbar*.dylib >/dev/null 2>&1; then
  echo "=============================================================="
  echo " libtorrent-rasterbar was not found under $BREW_PREFIX/lib"
  echo ""
  echo " Install it first (one time):"
  echo "     brew install libtorrent-rasterbar"
  echo ""
  echo " On an Intel Mac, also edit Package.swift and set"
  echo "     brewPrefix = \"/usr/local\""
  echo "=============================================================="
  exit 1
fi

echo "==> swiftc  : $(xcrun --find swiftc 2>/dev/null || command -v swiftc)"
echo "==> config  : $CONFIG"
echo "==> brew    : $BREW_PREFIX"

# 2. Build with SwiftPM.
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP"

# 3. Assemble the .app bundle.
BUNDLE="build/$APP.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>Canopy</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>0.2</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Canopy connects to peers on your local network.</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# 4. Ad-hoc codesign so macOS will launch it.
codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || true

echo "==> built $BUNDLE"
if [ "$RUN" -eq 1 ]; then
  echo "==> launching"
  open "$BUNDLE"
fi
