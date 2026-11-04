#!/usr/bin/env bash
# Builds MiniTab.app locally. Needs Xcode or the Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/MiniTab.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MiniTab "$APP/Contents/MacOS/MiniTab"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon: build AppIcon.icns from the 1024px PNG with macOS's own sips + iconutil.
mkdir -p "$APP/Contents/Resources"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/icon/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double Resources/icon/AppIcon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# "-" = ad-hoc signature. Set SIGN_IDENTITY to a self-signed code-signing cert
# so macOS keeps your permission grants across rebuilds (see README).
# --options runtime = hardened runtime: blocks DYLD_* injection, unsigned libraries,
# and debugger attachment to MiniTab.
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|CodeDirectory|Signature)" || true

echo "Built $APP"

# ./build.sh --install  -> replace /Applications/MiniTab.app and relaunch it
if [[ "${1:-}" == "--install" ]]; then
    pkill -x MiniTab || true
    rm -rf /Applications/MiniTab.app
    cp -R "$APP" /Applications/
    open /Applications/MiniTab.app
    echo "Installed to /Applications/MiniTab.app"
else
    echo "Run:  open $APP   (or ./build.sh --install to put it in /Applications)"
fi
