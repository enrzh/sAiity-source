#!/bin/bash
# Validate one generated Sparkle appcast against its local ZIP.
set -euo pipefail
cd "$(dirname "$0")/.."

APPCAST="${1:?usage: scripts/validate-appcast.sh <appcast.xml> <zip> [version]}"
ZIP="${2:?usage: scripts/validate-appcast.sh <appcast.xml> <zip> [version]}"
EXPECTED_VERSION="${3:-}"
[ -f "$APPCAST" ] || { echo "FATAL: appcast not found: $APPCAST" >&2; exit 1; }
[ -f "$ZIP" ] || { echo "FATAL: archive not found: $ZIP" >&2; exit 1; }
command -v xmllint >/dev/null || { echo "FATAL: xmllint is required." >&2; exit 1; }
xmllint --noout "$APPCAST"
unzip -tq "$ZIP" >/dev/null

xpath() { xmllint --xpath "string(($1)[1])" "$APPCAST"; }
version=$(xpath '//*[local-name()="shortVersionString"]')
length=$(xpath '//*[local-name()="enclosure"]/@length')
url=$(xpath '//*[local-name()="enclosure"]/@url')
signature=$(xpath '//*[local-name()="enclosure"]/@*[local-name()="edSignature"]')
[ -n "$version" ] || { echo "FATAL: appcast version is missing." >&2; exit 1; }
[ -z "$EXPECTED_VERSION" ] || [ "$version" = "$EXPECTED_VERSION" ] || {
    echo "FATAL: appcast version is $version, expected $EXPECTED_VERSION." >&2
    exit 1
}
actual_length=$(stat -f%z "$ZIP")
[ "$length" = "$actual_length" ] || {
    echo "FATAL: appcast length $length does not match $actual_length." >&2
    exit 1
}
[ -n "$url" ] || { echo "FATAL: appcast enclosure URL is missing." >&2; exit 1; }
[ -n "$signature" ] || { echo "FATAL: appcast Ed25519 signature is missing." >&2; exit 1; }
archive_name=$(basename "$ZIP")
case "$url" in
    */"$archive_name") ;;
    *) echo "FATAL: enclosure URL does not name $archive_name." >&2; exit 1 ;;
esac
echo "appcast verification passed: $APPCAST -> $archive_name ($actual_length bytes)"
