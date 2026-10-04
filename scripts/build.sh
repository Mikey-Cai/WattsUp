#!/bin/bash
# Builds ./build/WattsUp.app.
#
# Signing is optional. With nothing configured the app is signed ad hoc and
# built without the desktop widget (a widget needs an App Group, and an App
# Group needs your Team ID). To get the widget, set both:
#   WATTSUP_SIGN_IDENTITY  a codesigning identity (name or SHA-1), e.g. "Apple Development: you@example.com (XXXXXXXXXX)"
#   WATTSUP_TEAM_ID        the Team ID of that certificate (its OU), e.g. ABCDE12345
# either in the environment or in scripts/local.env (ignored by git).
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f scripts/local.env ]] && source scripts/local.env
IDENTITY="${WATTSUP_SIGN_IDENTITY:--}"
TEAM_ID="${WATTSUP_TEAM_ID:-}"
if [[ -n "$TEAM_ID" && ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
    echo "WATTSUP_TEAM_ID should be a 10-character Team ID, got: $TEAM_ID" >&2; exit 1
fi
if [[ -n "$TEAM_ID" && "$IDENTITY" == "-" ]]; then
    echo "WATTSUP_TEAM_ID is set but WATTSUP_SIGN_IDENTITY is not; an App Group needs a real identity." >&2; exit 1
fi
APP_GROUP="${TEAM_ID:+$TEAM_ID.io.github.mikey-cai.wattsup}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" build
# Use SwiftPM's direct backend; an app does not require the Xcode backend's
# optional dSYM-generation service. Keep a dependency-free optimized build.
swift build --build-system native --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -debug-info-format none -c release
BIN_DIR="$(swift build --build-system native --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" -debug-info-format none -c release --show-bin-path)"
APP="$PWD/build/WattsUp.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Replace the executable with a fresh inode instead of overwriting a previously
# signed/running Mach-O, whose code-signing state may still be cached by macOS.
EXECUTABLE_STAGE="$(mktemp "$APP/Contents/MacOS/.WattsUp.XXXXXX")"
trap 'rm -f "$EXECUTABLE_STAGE"' EXIT
cp "$BIN_DIR/WattsUp" "$EXECUTABLE_STAGE"
chmod 755 "$EXECUTABLE_STAGE"
mv -f "$EXECUTABLE_STAGE" "$APP/Contents/MacOS/WattsUp"
trap - EXIT
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp LICENSE THIRD_PARTY.md "$APP/Contents/Resources/"
APPEX="$APP/Contents/PlugIns/WattsUpWidget.appex"
GEN="$PWD/.build/generated"
mkdir -p "$GEN"
# Fill in (or drop) the App Group placeholder in a plist or entitlements file.
fill_group() {
    if [[ -n "$APP_GROUP" ]]; then sed "s/__APP_GROUP__/$APP_GROUP/g" "$1" > "$2"
    else cp "$1" "$2"; fi
}

if [[ -n "$APP_GROUP" ]]; then
    plutil -replace WattsUpAppGroup -string "$APP_GROUP" "$APP/Contents/Info.plist"
    # v0.3 desktop widget: a hand-assembled WidgetKit .appex (no Xcode project).
    mkdir -p "$APPEX/Contents/MacOS"
    WIDGET_STAGE="$(mktemp "$APPEX/Contents/MacOS/.WattsUpWidget.XXXXXX")"
    trap 'rm -f "$WIDGET_STAGE"' EXIT
    cp "$BIN_DIR/WattsUpWidget" "$WIDGET_STAGE"
    chmod 755 "$WIDGET_STAGE"
    mv -f "$WIDGET_STAGE" "$APPEX/Contents/MacOS/WattsUpWidget"
    trap - EXIT
    fill_group Resources/Widget/Info.plist "$APPEX/Contents/Info.plist"
    plutil -lint "$APPEX/Contents/Info.plist"
    fill_group Resources/Widget/WattsUpWidget.entitlements "$GEN/WattsUpWidget.entitlements"
    fill_group Resources/WattsUp.entitlements "$GEN/WattsUp.entitlements"
else
    plutil -remove WattsUpAppGroup "$APP/Contents/Info.plist"
    rm -rf "$APP/Contents/PlugIns"
    echo "No WATTSUP_TEAM_ID: building without the desktop widget." >&2
fi

# The executables and plists have changed; earlier resource seals are invalid.
# Do not leave them behind if the requested identity is inaccessible.
rm -rf "$APP/Contents/_CodeSignature" "$APPEX/Contents/_CodeSignature"
plutil -lint "$APP/Contents/Info.plist"
# Deliberately no hardened runtime (-o runtime), helper, or installer.
# Inside-out signing: the extension is sandboxed with the shared App Group;
# the main app stays unsandboxed and only declares the same App Group.
if [[ -n "$APP_GROUP" ]]; then
    codesign --force --sign "$IDENTITY" --timestamp=none --entitlements "$GEN/WattsUpWidget.entitlements" "$APPEX"
    codesign --force --sign "$IDENTITY" --timestamp=none --entitlements "$GEN/WattsUp.entitlements" "$APP"
else
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
fi
codesign --verify --strict --deep --verbose=2 "$APP"
printf 'Built and signed: %s\n' "$APP"
