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

if strings "$binary" | grep -Eq 'SAIITY_(AUTOSTART|TEST_HOOKS)'; then
    echo "FATAL: test-only hooks are present in the release executable." >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null
"$binary" --version >/dev/null
echo "release verification passed: $APP ($version/$build)"
