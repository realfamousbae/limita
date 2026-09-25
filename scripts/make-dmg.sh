#!/bin/bash
# Builds Limita in Release and packages it as build/Limita-<version>.dmg with the
# drag-to-install window. The layout must match scripts/dmg-background.py.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Built outside the project folder: codesign rejects extended attributes that
# files there can pick up.
BUILD="${TMPDIR:-/tmp}/limita-dmg"
OUT="$ROOT/build"
WIDTH=660 HEIGHT=440 TITLEBAR=28 ICON_Y=210 APP_X=180 APPS_X=480 ICON=112

cd "$ROOT"
xcodebuild -project Limita.xcodeproj -scheme Limita -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$BUILD/DerivedData" build -quiet
APP="$BUILD/DerivedData/Build/Products/Release/Limita.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
VOLUME="Limita $VERSION"
mkdir -p "$OUT"
DMG="$OUT/Limita-$VERSION.dmg"

STAGE="$BUILD/dmg-stage"
rm -rf "$STAGE" "$BUILD/rw.dmg" "$DMG"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Limita.app"
ln -s /Applications "$STAGE/Applications"
tiffutil -cathidpicheck dmg/background.png dmg/background@2x.png -out "$STAGE/.background/background.tiff" 2>/dev/null

# Detach a volume left over from an interrupted run, or Finder lays out the wrong one.
if [ -d "/Volumes/$VOLUME" ]; then hdiutil detach "/Volumes/$VOLUME" -quiet -force; fi

hdiutil create -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ -format UDRW -ov "$BUILD/rw.dmg" -quiet
DEVICE="$(hdiutil attach "$BUILD/rw.dmg" -readwrite -noverify -noautoopen | awk '/Apple_HFS/ {print $1}')"
trap 'hdiutil detach "$DEVICE" -quiet -force 2>/dev/null || true' EXIT

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        -- Bounds include the title bar.
        set bounds of container window to {200, 120, 200 + $WIDTH, 120 + $TITLEBAR + $HEIGHT}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        -- With hidden files shown (Cmd-Shift-.), Finder lists these too and shifts the
        -- layout around them; parking them outside the window keeps it intact, also
        -- for users who show hidden files.
        repeat with hiddenName in {".background", ".fseventsd"}
            try
                set position of item hiddenName of container window to {$WIDTH + 200, $HEIGHT + 200}
            end try
        end repeat
        set position of item "Limita.app" of container window to {$APP_X, $ICON_Y}
        set position of item "Applications" of container window to {$APPS_X, $ICON_Y}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Finder occasionally ignores or shifts a position; never ship such a layout.
LAYOUT="$(osascript -e "tell application \"Finder\" to get {position of item \"Limita.app\", position of item \"Applications\"} of disk \"$VOLUME\"")"
if [ "$LAYOUT" != "$APP_X, $ICON_Y, $APPS_X, $ICON_Y" ]; then
    echo "DMG layout is wrong: icons at $LAYOUT, expected $APP_X, $ICON_Y, $APPS_X, $ICON_Y" >&2
    exit 1
fi

chmod -Rf go-w "/Volumes/$VOLUME" || true
sync
hdiutil detach "$DEVICE" -quiet
trap - EXIT
hdiutil convert "$BUILD/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
rm -rf "$STAGE" "$BUILD/rw.dmg"
echo "$DMG"
