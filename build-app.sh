#!/bin/bash
# Builds sAiity.app.  ./build-app.sh [--install]
#
# A bare SwiftPM executable cannot hold Screen Recording permission: TCC keys off
# a bundle identifier + code signature, so system-audio capture silently fails
# outside a signed .app. Hence the bundle + ad-hoc signature below.
set -euo pipefail
cd "$(dirname "$0")"

NAME="sAiity"
APP="build/$NAME.app"

swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# The filename here MUST match CFBundleExecutable exactly, capital A included.
# If it does not, codesign still succeeds and the app just silently fails to
# launch from Finder with no diagnostic.
FW_SRC=".build/out/Products/Release"
cp ".build/release/$NAME" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

SIGN_ID="${SAIITY_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
              | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
fi
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
              | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
fi



# Bundle any frameworks the dependencies ship as binary targets. LLM.swift
# vendors llama.framework this way, and a hand-assembled .app does not pick it
# up — the app builds and signs fine, then dies at launch with
# "Library not loaded: @rpath/llama.framework/...". Copy them in and point the
# binary's rpath at Contents/Frameworks.
if compgen -G "$FW_SRC/*.framework" >/dev/null; then
    mkdir -p "$APP/Contents/Frameworks"
    for fw in "$FW_SRC"/*.framework; do
        ditto "$fw" "$APP/Contents/Frameworks/$(basename "$fw")"
    done
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP/Contents/MacOS/$NAME" 2>/dev/null || true
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM resource bundles. MLX ships its Metal shader library
# (mlx.metallib) inside mlx-swift_Cmlx.bundle; without it every MLX call dies
# with "Failed to load the default metallib" the moment a model runs.
if compgen -G "$FW_SRC/*.bundle" >/dev/null; then
    for b in "$FW_SRC"/*.bundle; do
        ditto "$b" "$APP/Contents/Resources/$(basename "$b")"
    done
fi

# Signing identity, best available first:
#   Developer ID Application  -> distributable to other Macs (after notarisation)
#   Apple Development         -> local use; gives a stable Team ID, which is what
#                                makes TCC permission survive a rebuild
#   ad-hoc                     -> fallback; permission resets on every rebuild
# Override with SAIITY_SIGN_ID="Developer ID Application: ..." or SAIITY_SIGN_ID=-
# Nested code must be signed BEFORE the app that contains it, or codesign
# rejects the bundle with "code object is not signed at all". The vendored
# llama.framework arrives unsigned.
if [ -d "$APP/Contents/Frameworks" ]; then
    for fw in "$APP/Contents/Frameworks"/*.framework; do
        [ -d "$fw" ] || continue
        if [ -n "${SIGN_ID:-}" ] && [ "${SIGN_ID:-}" != "-" ]; then
            codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$fw"
        else
            codesign --force --sign - "$fw"
        fi
    done
fi

if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then
    # Hardened runtime + secure timestamp are both required for notarisation, and
    # harmless before it.
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
    echo "signed: $SIGN_ID"
else
    codesign --force --sign - "$APP"
    echo "signed: ad-hoc (no Developer ID or Apple Development identity found)"
fi

# Fail loudly on the one mismatch that is otherwise invisible.
PLIST_EXEC=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist")
[ -x "$APP/Contents/MacOS/$PLIST_EXEC" ] || { echo "FATAL: CFBundleExecutable '$PLIST_EXEC' missing in Contents/MacOS"; exit 1; }
echo "built: $APP"

# Notarisation. Requires a Developer ID Application certificate and a stored
# credential profile — create that yourself, once, so no secret ever passes
# through this script:
#   xcrun notarytool store-credentials "saiity" \
#         --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
if [ "${1:-}" = "--notarize" ]; then
    case "$SIGN_ID" in
        "Developer ID Application"*) ;;
        *) echo "FATAL: notarisation needs a Developer ID Application certificate."
           echo "       Current identity: ${SIGN_ID:-ad-hoc}"
           echo "       Create one in Xcode → Settings → Accounts → Manage Certificates → +"
           exit 1 ;;
    esac
    PROFILE="${SAIITY_NOTARY_PROFILE:-saiity}"
    ZIP="build/$NAME.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    echo "notarised + stapled: $APP"
fi

if [ "${1:-}" = "--install" ]; then
    DEST="/Applications/$NAME.app"
    rm -rf "$DEST"
    # ditto, not cp -R: preserves the code signature and xattrs for bundles.
    ditto "$APP" "$DEST"
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$DEST"
    echo "installed: $DEST"
fi
