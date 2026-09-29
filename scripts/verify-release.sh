#!/bin/bash
# Verify a built app bundle before it is archived, notarised, or uploaded.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:-build/sAiity.app}"
EXPECTED_VERSION="${2:-}"
[ -d "$APP" ] || { echo "FATAL: app bundle not found: $APP" >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || { echo "FATAL: Info.plist is missing." >&2; exit 1; }
plutil -lint "$PLIST" >/dev/null
executable=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST")
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
binary="$APP/Contents/MacOS/$executable"
[ -x "$binary" ] || { echo "FATAL: executable is missing: $binary" >&2; exit 1; }
[ -z "$EXPECTED_VERSION" ] || [ "$version" = "$EXPECTED_VERSION" ] || {
    echo "FATAL: version is $version, expected $EXPECTED_VERSION." >&2
    exit 1
}
[ "$build" != "1" ] || {
    echo "FATAL: bundle build number was not stamped." >&2
    exit 1
}

find "$APP/Contents" -type f -name '*.metallib' -size +0c -print -quit | grep -q . || {
    echo "FATAL: no non-empty MLX Metal library is bundled." >&2
    exit 1
}

# Test-only hooks, checked two ways because they can each be wrong.
#
# The plist says what the build *intended*, and the binary says what it
# *contains*. A build without `SAIITY_TEST_HOOKS` resolves `flag(...)` to a
# constant `false`, so the optimizer drops the branch and the flag name with it —
# which means the string really is a usable fingerprint, and really is absent
# from a clean build.
#
# The grep used `grep -q`, and that silently inverted the check: `grep -q` exits on
# the first match, `strings` then dies with SIGPIPE writing the rest of a 70 MB
# binary, and `set -o pipefail` turns that into a non-zero pipeline status — so
# the `if` took the else branch and printed "release verification passed" with the
# hook sitting right there. A gate that fails open is worse than no gate. `grep -c`
# reads the whole stream and cannot be killed early, so the status is grep's.
HOOKS=$(/usr/libexec/PlistBuddy -c "Print :SAIITYTestHooks" "$PLIST" 2>/dev/null || echo "")
if [ "$HOOKS" = "true" ]; then
    echo "FATAL: this bundle was built with the test-only hooks." >&2
    echo "       SAIITY_AUTOSTART starts system-audio capture with no consent." >&2
    echo "       build-app.sh only omits it for --notarize or --no-test-hooks." >&2
    exit 1
fi
if [ "$(strings "$binary" | grep -cE 'SAIITY_AUTOSTART' || true)" != "0" ]; then
    echo "FATAL: SAIITY_AUTOSTART is present in the release executable." >&2
    echo "       The plist does not claim a hook build, so the two disagree." >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null
"$binary" --version >/dev/null
echo "release verification passed: $APP ($version/$build)"
