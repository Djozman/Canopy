#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/Info.plist)"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Sources/Info.plist)"

if [[ "$VERSION" != "3.0.0" || "$BUILD_VERSION" != "3.0.0" ]]; then
    echo "Expected version 3.0.0, found $VERSION ($BUILD_VERSION)" >&2
    exit 1
fi

./build_app.sh

APP="$PWD/Canopy.app"
EXECUTABLE="$APP/Contents/MacOS/Canopy"
FRAMEWORKS="$APP/Contents/Frameworks"
DIST="$PWD/dist"
QUEUE="$(mktemp)"
trap 'rm -f "$QUEUE"' EXIT

mkdir -p "$FRAMEWORKS" "$DIST"
printf '%s\n' "$EXECUTABLE" > "$QUEUE"

index=1
while target="$(sed -n "${index}p" "$QUEUE")" && [[ -n "$target" ]]; do
    index=$((index + 1))

    while IFS= read -r dependency; do
        case "$dependency" in
            /System/*|/usr/lib/*|@rpath/*|@loader_path/*|@executable_path/*)
                continue
                ;;
            /opt/homebrew/*|/usr/local/*)
                ;;
            *)
                continue
                ;;
        esac

        if [[ ! -f "$dependency" ]]; then
            echo "Missing dynamic library: $dependency" >&2
            exit 1
        fi

        library_name="$(basename "$dependency")"
        bundled_library="$FRAMEWORKS/$library_name"

        # A dylib lists its own install ID first. It was already rewritten
        # when copied, so only process actual load dependencies here.
        if [[ "$target" != "$EXECUTABLE" && "$(basename "$target")" == "$library_name" ]]; then
            continue
        fi

        if [[ ! -f "$bundled_library" ]]; then
            cp -L "$dependency" "$bundled_library"
            chmod u+w "$bundled_library"
            install_name_tool -id "@rpath/$library_name" "$bundled_library"
            printf '%s\n' "$bundled_library" >> "$QUEUE"
        fi

        if [[ "$target" == "$EXECUTABLE" ]]; then
            replacement="@executable_path/../Frameworks/$library_name"
        else
            replacement="@loader_path/$library_name"
        fi
        install_name_tool -change "$dependency" "$replacement" "$target"
    done < <(otool -L "$target" | tail -n +2 | awk '{print $1}')
done

while IFS= read -r binary; do
    if otool -L "$binary" | grep -E '/opt/homebrew|/usr/local' >/dev/null; then
        echo "Unbundled Homebrew dependency remains in $binary" >&2
        otool -L "$binary" >&2
        exit 1
    fi
done < "$QUEUE"

xattr -cr "$APP"
find "$FRAMEWORKS" -type f -exec codesign --force --sign - {} \;
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

rm -rf "$DIST/Canopy-$VERSION" "$DIST/Canopy-$VERSION-macOS.zip" "$DIST/Canopy-$VERSION-macOS.dmg"
mkdir -p "$DIST/Canopy-$VERSION"
cp -R "$APP" "$DIST/Canopy-$VERSION/"
ln -s /Applications "$DIST/Canopy-$VERSION/Applications"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/Canopy-$VERSION-macOS.zip"
hdiutil create \
    -volname "Canopy $VERSION" \
    -srcfolder "$DIST/Canopy-$VERSION" \
    -ov -format UDZO \
    "$DIST/Canopy-$VERSION-macOS.dmg"

(
    cd "$DIST"
    shasum -a 256 "Canopy-$VERSION-macOS.zip" "Canopy-$VERSION-macOS.dmg" \
        > "Canopy-$VERSION-SHA256SUMS.txt"
)

rm -rf "$DIST/Canopy-$VERSION"
echo "Release files are ready in $DIST"
