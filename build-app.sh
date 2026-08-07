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

# Version from git, so a bug report can name the build it came from. Falls back
# to the Info.plist value outside a git checkout.
GIT_VERSION=$(git describe --tags --always --dirty 2>/dev/null || true)
GIT_COUNT=$(git rev-list --count HEAD 2>/dev/null || echo "1")

# Test hooks (SAIITY_AUTOSTART and friends) are compiled in for local builds and
# OUT for anything being notarised — one of them starts system-audio capture
# with no UI and no consent, which has no business in a shipped binary.
#
# Written as two explicit calls rather than an array of flags. macOS ships bash
# 3.2, where expanding an EMPTY array as "${arr[@]}" under `set -u` is an
# unbound-variable error — so the array form worked for every local build, where
# it holds the test-hook flags, and failed on the one path where it is empty:
# --notarize. That is the path nobody could run until there was a Developer ID
# certificate to run it with, so the first real release attempt was also the
# first time this line executed.
if [ "${1:-}" = "--notarize" ]; then
    swift build -c release
else
    swift build -c release -Xswiftc -DSAIITY_TEST_HOOKS
fi
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

# Localizations. SwiftUI keys against Bundle.main's Localizable table, so the
# compiled catalog goes straight into Contents/Resources — a bare swift-build
# binary simply falls back to the English keys.
if [ -f Resources/Localizable.xcstrings ]; then
    xcrun xcstringstool compile Resources/Localizable.xcstrings \
        --output-directory "$APP/Contents/Resources"
    echo "localized: $(ls -d "$APP/Contents/Resources/"*.lproj | wc -l | tr -d ' ') languages"
fi

# Stamp the build so a bug report can name it.
if [ -n "$GIT_VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $GIT_VERSION" \
        "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GIT_COUNT" \
        "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

# Third-party notices. The binary statically links Apache-2.0 code (FluidAudio,
# MLX, swift-transformers, speech-swift) and MIT code (WhisperKit, LLM.swift,
# and the vendored llama.framework). Apache-2.0 section 4 and the MIT notice
# clause both require these to travel with the binary — so they are assembled
# from the actual checkouts rather than transcribed by hand, which would go
# stale the first time a dependency changed.
CREDITS="$APP/Contents/Resources/Credits.txt"
{
    echo "sAiity"
    echo "Copyright (c) $(date +%Y). MIT licensed — see LICENSE in the source repository."
    echo
    echo "This application includes software from the following projects."
    echo "================================================================"
    for lic in $(find .build/checkouts -maxdepth 2 \
                 \( -iname "LICENSE" -o -iname "LICENSE.txt" -o -iname "LICENSE.md" \) \
                 2>/dev/null | sort); do
        proj=$(basename "$(dirname "$lic")")
        echo
        echo "--- $proj ---"
        cat "$lic"
    done
    echo
    echo "Model weights are downloaded at first use and are NOT distributed with"
    echo "this application. Each carries its own terms; the app shows them per"
    echo "model under Settings -> Models."
} > "$CREDITS"
echo "credits: $(grep -c '^--- ' "$CREDITS") third-party licences bundled"

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
    SUBMIT_ZIP="build/$NAME-submit.zip"

    # Order matters, and getting it wrong is invisible. Submission needs a zip;
    # the ticket is stapled to the .app, NOT to that zip. Building the
    # distributable first meant shipping an archive with no ticket while the
    # script cheerfully printed "notarised + stapled" — a Mac with no network
    # would then refuse to open it.
    rm -f "$ZIP" "$SUBMIT_ZIP"
    ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"
    xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait
    rm -f "$SUBMIT_ZIP"

    xcrun stapler staple "$APP"
    ditto -c -k --keepParent "$APP" "$ZIP"

    # Validate what actually ships, not the copy we happen to still have. An
    # archive that unpacks without a ticket is the whole failure mode here.
    VERIFY_DIR=$(mktemp -d)
    ditto -x -k "$ZIP" "$VERIFY_DIR"
    xcrun stapler validate "$VERIFY_DIR/$NAME.app"
    spctl --assess --type execute --verbose=2 "$VERIFY_DIR/$NAME.app"
    rm -rf "$VERIFY_DIR"
    echo "notarised + stapled, verified from the archive: $ZIP"
fi

if [ "${1:-}" = "--install" ]; then
    DEST="/Applications/$NAME.app"
    rm -rf "$DEST"
    # ditto, not cp -R: preserves the code signature and xattrs for bundles.
    ditto "$APP" "$DEST"
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$DEST"
    echo "installed: $DEST"
fi
