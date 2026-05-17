#!/bin/bash
set -e

CONFIG=${1:-debug}

# Kill any running instance — otherwise the binary is locked and the copy silently fails
pkill -x Canopy 2>/dev/null || true
sleep 0.3

echo "Building ($CONFIG)..."
swift build -c "$CONFIG"

BINARY=".build/$CONFIG/Canopy"
APP="Canopy.app/Contents/MacOS/Canopy"

cp "$BINARY" "$APP"
echo "Copied $(stat -f %z "$BINARY") bytes — $(stat -f %Sm "$BINARY")"

codesign --force --deep --sign - Canopy.app 2>/dev/null && echo "Signed" || echo "Signing skipped"

echo "Launching..."
open Canopy.app

echo
echo "=== Streaming Canopy engine logs (Ctrl+C to stop) ==="
echo "    subsystem=com.canopy.engine, level=info+"
echo
exec log stream --level info \
    --predicate 'subsystem == "com.canopy.engine"'
