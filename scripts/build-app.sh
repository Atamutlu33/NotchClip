#!/usr/bin/env bash
# Builds NotchClip.app (universal: Apple silicon + Intel) into ./build and zips it.
# Usage: scripts/build-app.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-1.0.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
OUT="build"
APP="$OUT/NotchClip.app"

echo "▸ Compiling release build ($VERSION, build $BUILD_NUMBER)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/NotchClip"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchClip"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Building icon"
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "▸ Signing (ad hoc)"
codesign --force --deep --options runtime --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "▸ Zipping"
rm -f "$OUT/NotchClip.zip"
ditto -c -k --keepParent "$APP" "$OUT/NotchClip.zip"

lipo -info "$APP/Contents/MacOS/NotchClip"
echo "✓ $APP"
echo "✓ $OUT/NotchClip.zip"
