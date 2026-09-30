#!/bin/bash
# Build a LOCAL drag-to-Applications image — signed by the app inside it, but
# not notarized. scripts/make-local-dmg.sh <version>
#
# ## When this is the right script
#
# For looking at a build on this Mac. `scripts/make-dmg.sh` is the shipping
# path: it submits the image to Apple, waits, staples the ticket, and fails if
# any of that does not hold. That is correct for a release and wrong for a
# working copy — it spends an Apple notary submission on a build that may be
# dirty, and the wait is minutes for something that will be rebuilt anyway.
#
# ## What the user actually gets
#
# Gatekeeper refuses this image on any Mac that did not build it, because the
# image itself carries the quarantine flag and has no stapled ticket. So: fine
# to run here, "cannot be opened" everywhere else. That is the trade, and it is
# why the filename says `-local` — a `-local.dmg` that somehow reached a user
# would be a bug, not a shortcut.
#
# Everything up to the signing steps is shared with the release path by
# construction: same stage, same ditto (which preserves the app's signature and
# any stapled ticket already on it), same compression.
#
# ## Usage
#
#   ./build-app.sh --no-test-hooks     # or --notarize for a signed app
#   scripts/make-local-dmg.sh 2.6.0
#
# The image lands in build/, then is copied to ~/Downloads.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/make-local-dmg.sh <version>}"
NAME="sAiity"
APP="build/$NAME.app"
DMG="build/$NAME-$VERSION-local.dmg"
STAGE="build/dmg-stage"
VOLNAME="$NAME $VERSION"

[ -d "$APP" ] || { echo "FATAL: $APP missing — run ./build-app.sh first"; exit 1; }

# A "local" image of an app that was never signed would not even run here, so
# refuse rather than produce something that fails on double-click.
codesign --verify --deep --strict "$APP" 2>/dev/null \
    || { echo "FATAL: $APP is unsigned. Run ./build-app.sh before this."; exit 1; }

rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
# ditto, not cp -R: preserves the signature and any stapled ticket.
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$STAGE/.background"
if swift scripts/make-dmg-background.swift "$STAGE/.background/installer.png" 2>/dev/null; then
    BG_LINE='set background picture of theViewOptions to file ".background:installer.png"'
else
    rm -rf "$STAGE/.background"
    BG_LINE=""
    echo "note: dmg background skipped; the image still works"
fi
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns" 2>/dev/null || true

RW="build/$NAME-rw.dmg"
rm -f "$RW"
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
    -format UDRW -ov "$RW" >/dev/null

MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | grep -Eo '/Volumes/.*$' | head -1)
[ -n "$MOUNT" ] || { echo "FATAL: could not mount $RW"; exit 1; }

SetFile -a C "$MOUNT" 2>/dev/null || true

# Presentation only, and only if Finder Automation has been granted. A machine
# that has not granted it still has to get a working image, and the AppleScript
# would otherwise hang — bound it the same way the release script does.
if ! perl -e 'alarm 20; exec @ARGV' /usr/bin/osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Finder"
    tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 150, 900, 590}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        $BG_LINE
        set position of item "$NAME.app" of container window to {170, 220}
        set position of item "Applications" of container window to {530, 220}
        update without registering applications
        delay 2
        update without registering applications
    end tell
end tell
APPLESCRIPT
then
    echo "note: Finder layout skipped (Automation permission or timeout); the image still works"
fi

sync
hdiutil detach "$MOUNT" >/dev/null
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW"; rm -rf "$STAGE"

# No codesign, no notarytool, no stapler: that is the whole difference from
# scripts/make-dmg.sh, and deliberately the only difference.
V=$(hdiutil attach -nobrowse -readonly "$DMG" | grep -Eo '/Volumes/.*$' | head -1)
[ -d "$V/$NAME.app" ] || { echo "FATAL: image mounted without the app"; exit 1; }
codesign --verify --deep --strict "$V/$NAME.app" \
    || { hdiutil detach "$V" >/dev/null; echo "FATAL: app signature broken by the image"; exit 1; }
[ -L "$V/Applications" ] || echo "note: no Applications symlink"
hdiutil detach "$V" >/dev/null

DOWNLOADS="$HOME/Downloads"
if [ -d "$DOWNLOADS" ]; then
    cp "$DMG" "$DOWNLOADS/"
    echo "copied: $DOWNLOADS/$(basename "$DMG")"
fi

echo "built (LOCAL, not notarized): $DMG ($(stat -f%z "$DMG") bytes)"
echo "runs on this Mac; Gatekeeper will refuse it elsewhere."
