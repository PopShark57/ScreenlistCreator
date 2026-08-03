#!/bin/bash
# Builds ScreenlistCreator and assembles "Screenlist Creator.app" in dist/.
# Uses swiftc directly (no Xcode required — Command Line Tools are enough).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$DIST/Screenlist Creator.app"
ARCH="$(uname -m)"

mkdir -p "$BUILD"

# With bare Command Line Tools, the newest SDK declares SwiftUI property wrappers
# as macros whose compiler plugin only ships with full Xcode. Fall back to an
# older installed SDK in that case. Override with SDK=/path/to/SDK if needed.
compile() {
    if [ -n "${1:-}" ]; then
        swiftc -O -swift-version 5 -parse-as-library -sdk "$1" \
            -target "$ARCH-apple-macos14.0" \
            "$ROOT/Sources/ScreenlistCreator/"*.swift \
            -o "$BUILD/ScreenlistCreator" 2> "$BUILD/compile.log"
    else
        swiftc -O -swift-version 5 -parse-as-library \
            -target "$ARCH-apple-macos14.0" \
            "$ROOT/Sources/ScreenlistCreator/"*.swift \
            -o "$BUILD/ScreenlistCreator" 2> "$BUILD/compile.log"
    fi
}

echo "==> Compiling (swiftc, $ARCH, macOS 14+)"
if ! compile "${SDK:-}"; then
    fallback=""
    for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX2*.sdk; do
        [ -d "$candidate" ] || continue
        iface="$candidate/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule"
        ls "$iface"/*.swiftinterface >/dev/null 2>&1 || continue
        if ! grep -qs "macro State" "$iface"/*.swiftinterface; then
            fallback="$candidate"   # newest SDK with non-macro property wrappers wins
        fi
    done
    if [ -n "$fallback" ]; then
        echo "==> Default SDK failed, retrying with $fallback"
        compile "$fallback" || { cat "$BUILD/compile.log" >&2; exit 1; }
    else
        cat "$BUILD/compile.log" >&2
        exit 1
    fi
fi

echo "==> Rendering app icon"
if [ ! -f "$BUILD/AppIcon.icns" ]; then
    swift "$ROOT/scripts/make_icon.swift" "$BUILD/AppIcon-1024.png"
    ICONSET="$BUILD/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for sz in 16 32 128 256 512; do
        sips -z $sz $sz "$BUILD/AppIcon-1024.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
        dbl=$((sz * 2))
        sips -z $dbl $dbl "$BUILD/AppIcon-1024.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$BUILD/AppIcon.icns"
fi

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/ScreenlistCreator" "$APP/Contents/MacOS/ScreenlistCreator"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Code signing (ad-hoc)"
codesign --force --sign - "$APP"

echo "==> Done: $APP"
