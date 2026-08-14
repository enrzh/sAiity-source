#!/bin/bash
# Build the drag-to-Applications disk image.  scripts/make-dmg.sh <version>
#
# Runs AFTER build-app.sh --notarize: the .app inside must already be notarised
# and stapled, because the app's own ticket is what lets it launch on a Mac that
# is offline. The image is then signed and notarised in its own right — a
# downloaded .dmg carries the quarantine flag itself, so an unsigned one makes
# macOS refuse the mount with "cannot be opened" no matter how good the app
# inside it is.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/make-dmg.sh <version>}"
NAME="sAiity"
APP="build/$NAME.app"
DMG="build/$NAME-$VERSION.dmg"
STAGE="build/dmg-stage"
VOLNAME="$NAME $VERSION"

[ -d "$APP" ] || { echo "FATAL: $APP missing — run ./build-app.sh --notarize first"; exit 1; }
if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
    echo "FATAL: $APP is not stapled. Ship a notarised app or the image is pointless."
    exit 1
fi

rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
# ditto, not cp -R: preserves the signature and the stapled ticket.
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"

# Finder background and volume icon. Presentation, so best-effort like the
# icon layout below — a machine where the drawing script or SetFile fails
# still ships a working image.
BG_LINE=""
mkdir -p "$STAGE/.background"
if swift scripts/make-dmg-background.swift "$STAGE/.background/installer.png" 2>/dev/null; then
    BG_LINE='set background picture of theViewOptions to file ".background:installer.png"'
else
    rm -rf "$STAGE/.background"
    echo "note: dmg background skipped (drawing script failed); the image still works"
fi
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns" 2>/dev/null || true

# A read-write image first, so the Finder can be told where the two icons go;
# then convert to a compressed read-only one for distribution.
RW="build/$NAME-rw.dmg"
rm -f "$RW"
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
    -format UDRW -ov "$RW" >/dev/null

MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -Eo '/Volumes/.*$' | head -1)
[ -n "$MOUNT" ] || { echo "FATAL: could not mount $RW"; exit 1; }

# The custom-icon flag is what makes the Finder honour .VolumeIcon.icns.
SetFile -a C "$MOUNT" 2>/dev/null || true

# Icon layout. Best-effort: this drives the Finder through AppleScript, which
# needs Automation permission, and a build machine that has not granted it still
# has to produce a working image. The Applications symlink is what actually
# makes the image installable; the arrangement is presentation.
osascript <<APPLESCRIPT >/dev/null 2>&1 || echo "note: Finder layout skipped (Automation permission); the image still works"
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 150, 800, 530}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        $BG_LINE
        set position of item "$NAME.app" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT" >/dev/null
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"; rm -rf "$STAGE"

SIGN_ID="${SAIITY_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
              | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
fi
[ -n "$SIGN_ID" ] || { echo "FATAL: no Developer ID Application identity; the image would not open"; exit 1; }

codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
echo "signed: $SIGN_ID"

PROFILE="${SAIITY_NOTARY_PROFILE:-saiity}"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

# Verify what actually ships, by mounting it the way a user would.
V=$(hdiutil attach -nobrowse -readonly "$DMG" | grep -Eo '/Volumes/.*$' | head -1)
xcrun stapler validate "$V/$NAME.app"
spctl --assess --type execute --verbose=2 "$V/$NAME.app"
[ -L "$V/Applications" ] && echo "drag target present: Applications -> $(readlink "$V/Applications")"
hdiutil detach "$V" >/dev/null

echo "built: $DMG ($(stat -f%z "$DMG") bytes, notarised + stapled)"
