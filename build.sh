#!/usr/bin/env bash
# Builds MiniTab.app. Needs Xcode or the Command Line Tools (xcode-select --install).
#
#   ./build.sh             build into build/
#   ./build.sh --install   build, install to /Applications and launch
#
# Signing:
#   - Default: ad-hoc. macOS ties permissions to this exact binary, so each install needs
#     them re-enabled. --install clears the stale entries for you, so you only flip the
#     toggles when macOS asks (no removing / re-adding by hand).
#   - With scripts/setup-signing.sh: a stable local identity in its own locked keychain,
#     so permissions survive rebuilds. See "Code signing" in the README.
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)

# Optional stable signing identity created by scripts/setup-signing.sh (git-ignored).
if [[ -z "${SIGN_IDENTITY:-}" && -f .signing.env ]]; then
    # shellcheck disable=SC1091
    source .signing.env
fi

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

# --options runtime = hardened runtime: blocks DYLD_* injection, unsigned libraries and
# debugger attachment.
SIGN_ARGS=(--force --options runtime --sign "${SIGN_IDENTITY:--}")
if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then
    SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
    echo "Signing with the local MiniTab identity (macOS may ask for the keychain password; never choose \"Always Allow\")."
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|CodeDirectory|Signature|Authority)" || true

echo "Built $APP"

if [[ "${1:-}" != "--install" ]]; then
    echo "Run:  open $APP   (or ./build.sh --install to put it in /Applications)"
    exit 0
fi

pkill -x MiniTab || true
rm -rf /Applications/MiniTab.app
cp -R "$APP" /Applications/

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    # Ad-hoc: the old permission entries point to the previous binary and no longer work.
    # Clear them so MiniTab asks again and you only need to flip the toggles.
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    tccutil reset ScreenCapture "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "Permissions reset for this new build: turn MiniTab on when macOS asks"
    echo "(Accessibility, and Screen Recording if you use thumbnails)."
fi

open /Applications/MiniTab.app
echo "Installed to /Applications/MiniTab.app"

# macOS re-lists ad-hoc signed apps under Accessibility by itself, but not under Screen
# Recording: they have to be added by hand. Open the pane and reveal the app to make it quick.
THUMBNAILS=$(defaults read "$BUNDLE_ID" showThumbnails 2>/dev/null || echo 1)
if [[ -z "${SIGN_IDENTITY:-}" && "$THUMBNAILS" != "0" ]]; then
    echo
    echo "Screen Recording: drag MiniTab from the Finder window into the list (or use +),"
    echo "turn it on, then quit and reopen MiniTab. To skip this on every build, run"
    echo "scripts/setup-signing.sh once, or turn off Show Thumbnails."
    sleep 1
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    open -R /Applications/MiniTab.app
fi
