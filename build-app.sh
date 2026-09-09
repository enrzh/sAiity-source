#!/bin/bash
# Builds sAiity.app.  ./build-app.sh [--install]
#
# A bare SwiftPM executable cannot hold Screen Recording permission: TCC keys off
# a bundle identifier + code signature, so system-audio capture silently fails
# outside a signed .app. Hence the bundle + ad-hoc signature below.
set -euo pipefail
cd "$(dirname "$0")"

# Use the full Xcode toolchain without changing the user's global xcode-select.
# CI and local callers can override this for another installed Xcode.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
if ! xcrun --find xcstringstool >/dev/null 2>&1; then
    echo "FATAL: Xcode is required. Set DEVELOPER_DIR to an installed Xcode developer directory." >&2
    exit 1
fi

NAME="sAiity"
APP="build/$NAME.app"

# Version from git, so a bug report can name the build it came from. Falls back
# to the Info.plist value outside a git checkout.
GIT_VERSION="${SAIITY_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || true)}"
# Tags are written v1.0.0; the version a user sees is 1.0.0. Without stripping
# the prefix the About window and Sparkle's update panel read "v1.0.0" while the
# appcast that offers the update says "1.0.0" — the same release, named two
# different ways in the one dialog where they appear side by side.
GIT_VERSION="${GIT_VERSION#v}"
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
NOTARIZE=0
for arg in "$@"; do [ "$arg" = "--notarize" ] && NOTARIZE=1; done

SIGN_ID="${SAIITY_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
              | grep -m1 "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)
fi
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
              | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
fi
if [ "$NOTARIZE" = 1 ]; then
    case "$SIGN_ID" in
        "Developer ID Application"*) ;;
        *) echo "FATAL: notarisation needs a Developer ID Application certificate." >&2
           echo "       Current identity: ${SIGN_ID:-ad-hoc}" >&2
           exit 1 ;;
    esac
    PROFILE="${SAIITY_NOTARY_PROFILE:-saiity}"
    if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        echo "FATAL: notarisation profile '$PROFILE' is not available in the keychain." >&2
        echo "       Store it with: xcrun notarytool store-credentials '$PROFILE'" >&2
        exit 1
    fi
fi
if [ "$NOTARIZE" = 1 ]; then
    swift build -c release
else
    swift build -c release -Xswiftc -DSAIITY_TEST_HOOKS
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# The filename here MUST match CFBundleExecutable exactly, capital A included.
# If it does not, codesign still succeeds and the app just silently fails to
# launch from Finder with no diagnostic.
cp ".build/release/$NAME" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# SwiftPM's product directory is architecture-specific (for example,
# .build/arm64-apple-macosx/release). Do not guess a legacy path: a guessed
# path leaves dynamic frameworks out of the bundle while codesign still passes.
FW_SRC=$(swift build -c release --show-bin-path)



# Bundle any frameworks the dependencies ship as binary targets. LLM.swift
# vendors llama.framework this way, and a hand-assembled .app does not pick it
# up — the app builds and signs fine, then dies at launch with
# "Library not loaded: @rpath/llama.framework/...". Copy them in and point the
# binary's rpath at Contents/Frameworks.
frameworks=()
for fw in "$FW_SRC"/*.framework; do
    [ -d "$fw" ] || continue
    frameworks+=("$fw")
done
if [ "${#frameworks[@]}" -eq 0 ]; then
    echo "FATAL: no framework products found in $FW_SRC" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
for fw in "${frameworks[@]}"; do
    ditto "$fw" "$APP/Contents/Frameworks/$(basename "$fw")"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/$NAME" 2>/dev/null || true

# A valid outer signature does not prove that dyld can resolve all nested code.
# Fail before signing if any @rpath dependency is absent from the bundle.
while IFS= read -r dependency; do
    relative="${dependency#@rpath/}"
    [ "$relative" = "$dependency" ] && continue
    [ -e "$APP/Contents/Frameworks/$relative" ] || {
        echo "FATAL: missing bundled dependency $dependency" >&2
        exit 1
    }
done < <(otool -L "$APP/Contents/MacOS/$NAME" | awk '$1 ~ /^@rpath\// { print $1 }')
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

    # Assert the stamp landed. Both Sets above swallow their errors, and the
    # fallbacks in Resources/Info.plist are 0.1.0/1 — which the appcast would
    # then out-rank forever, so Sparkle would offer the same update after every
    # install, in a loop, with the About window reading 0.1.0.
    STAMPED=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
    [ "$STAMPED" = "$GIT_COUNT" ] || {
        echo "FATAL: CFBundleVersion is '$STAMPED', expected '$GIT_COUNT' — the"
        echo "       appcast advertises the latter, so shipping this builds an"
        echo "       app that re-offers its own update forever."; exit 1; }
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
    echo "The sAiity application source is public for inspection. No license is granted to copy, modify, or redistribute it."
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
sign_code() {   # $1 = bundle or Mach-O to sign
    if [ -n "${SIGN_ID:-}" ] && [ "${SIGN_ID:-}" != "-" ]; then
        codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$1"
    else
        codesign --force --sign - "$1"
    fi
}

# Signing runs INSIDE-OUT, and that ordering is the whole point.
#
# Nested code must be signed before the bundle containing it, or codesign
# rejects the outer one with "code object is not signed at all". The vendored
# llama.framework arrives unsigned, and Sparkle.framework arrives carrying
# Sparkle's own signature on four *separate* nested executables — an
# Updater.app, two XPC services, and a bare Autoupdate helper. Signing the
# framework does not reach any of them: they keep whatever signature they
# shipped with, which has no Team ID and no secure timestamp.
#
# Nothing local catches that. The app builds, signs, launches and updates
# perfectly with the inner code left alone — Apple's notary service is the
# first thing that looks, and it rejected the first submission with sixteen
# errors across exactly those four binaries.
if [ -d "$APP/Contents/Frameworks" ]; then
    # 1. Nested bundles, deepest first.
    while IFS= read -r -d '' nested; do
        sign_code "$nested"
    done < <(find "$APP/Contents/Frameworks" -depth \( -name "*.xpc" -o -name "*.app" \) -print0)

    # 2. Loose Mach-O helpers inside a framework (Sparkle's Autoupdate). Anything
    #    inside a bundle from step 1 is already covered by that bundle.
    #
    #    Match on the path RELATIVE to Frameworks/, not the absolute one. The
    #    app bundle is itself called sAiity.app, so every absolute path under it
    #    contains ".app/" — testing the full path skipped every loose executable
    #    including the one this step exists for, and Apple's second rejection was
    #    Autoupdate alone.
    FW_ROOT="$APP/Contents/Frameworks"
    while IFS= read -r -d '' exe; do
        rel="${exe#"$FW_ROOT/"}"
        case "$rel" in *.app/*|*.xpc/*) continue ;; esac
        file -b "$exe" 2>/dev/null | grep -q "Mach-O" || continue
        sign_code "$exe"
    done < <(find "$FW_ROOT" -type f -perm +111 -print0)

    # 3. The frameworks themselves, now that everything within them is signed.
    for fw in "$APP/Contents/Frameworks"/*.framework; do
        [ -d "$fw" ] || continue
        sign_code "$fw"
    done
fi

if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "-" ]; then
    # Hardened runtime + secure timestamp are both required for notarisation, and
    # harmless before it. The entitlements file matters under hardened runtime:
    # without audio-input there, the opt-in microphone mixing fails silently in
    # exactly the signed builds users run.
    codesign --force --options runtime --timestamp \
             --entitlements Resources/sAiity.entitlements --sign "$SIGN_ID" "$APP"
    echo "signed: $SIGN_ID"
else
    codesign --force --sign - "$APP"
    echo "signed: ad-hoc (no Developer ID or Apple Development identity found)"
fi

# Fail loudly on the one mismatch that is otherwise invisible.
PLIST_EXEC=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist")
[ -x "$APP/Contents/MacOS/$PLIST_EXEC" ] || { echo "FATAL: CFBundleExecutable '$PLIST_EXEC' missing in Contents/MacOS"; exit 1; }
"$APP/Contents/MacOS/$NAME" --version >/dev/null || {
    echo "FATAL: built app failed its --version launch smoke test" >&2
    exit 1
}
echo "launch smoke: --version passed"
echo "built: $APP"

# Notarisation. Requires a Developer ID Application certificate and a stored
# credential profile — create that yourself, once, so no secret ever passes
# through this script:
#   # Nothing with a test hook in it may be notarised. SAIITY_AUTOSTART starts
#   # system-audio capture with no window and no consent, so a hook surviving
#   # into a signed, stapled build is the one mistake here that is a security
#   # problem rather than an inconvenience.
#   if strings "$APP/Contents/MacOS/sAiity" | grep -q "SAIITY_AUTOSTART"; then
#       echo "FATAL: test hooks are compiled into this binary; refusing to notarise."
#       exit 1
#   fi
#   xcrun notarytool store-credentials "saiity" \
#         --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
if [ "${1:-}" = "--notarize" ]; then
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
