#!/bin/bash
# Cut a release: notarised build, EdDSA-signed archive, appcast entry.
#
#   scripts/release.sh 1.2.0
#
# Produces build/sAiity.zip and build/appcast.xml. The archive is uploaded to
# the public GitHub release, and the signed appcast is published to the public
# repository root after that asset is available. The script does not publish
# either one as a side effect of a local build.
#
# Prerequisites, one-time:
#   - a "Developer ID Application" certificate (build-app.sh --notarize refuses
#     without one)
#   - notarytool credentials stored as profile "saiity"
#   - scripts/sparkle_ed25519_private.pem (git-ignored; its public half is baked
#     into Info.plist as SUPublicEDKey — losing the private key means shipped
#     apps can never verify another update, so back it up)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version>   (git tag vX.Y.Z is created)}"
KEY="scripts/sparkle_ed25519_private.pem"
RELEASE_REPO="enrzh/sAiity"
RELEASE_ASSET_URL="https://github.com/$RELEASE_REPO/releases/download/v$VERSION/sAiity-$VERSION.zip"
[ -f "$KEY" ] || { echo "FATAL: $KEY missing — generate with: openssl genpkey -algorithm ED25519 -out $KEY"; exit 1; }

# Sparkle's signer expects its base64-encoded Ed25519 seed, while the checked
# out private key is kept as a PKCS#8 PEM. Apple's LibreSSL cannot sign
# Ed25519, so use Sparkle's own signer and convert only into a temporary file.
SPARKLE_SIGNER="${SPARKLE_SIGNER:-.build/artifacts/sparkle/Sparkle/bin/sign_update}"
[ -x "$SPARKLE_SIGNER" ] || {
    echo "FATAL: Sparkle signer missing at $SPARKLE_SIGNER; resolve Sparkle first." >&2
    exit 1
}
SPARKLE_KEY="$KEY"
SPARKLE_KEY_TEMP=""
if grep -q "BEGIN PRIVATE KEY" "$KEY"; then
    SPARKLE_KEY_TEMP=$(mktemp "${TMPDIR:-/tmp}/saiity-sparkle-key.XXXXXX")
    awk '/BEGIN PRIVATE KEY/{inside=1; next} /END PRIVATE KEY/{inside=0} inside {print}' "$KEY" \
        | tr -d '\r\n' | base64 -D | tail -c 32 | base64 > "$SPARKLE_KEY_TEMP"
    SPARKLE_KEY="$SPARKLE_KEY_TEMP"
fi
cleanup_sparkle_key() { [ -z "$SPARKLE_KEY_TEMP" ] || rm -f "$SPARKLE_KEY_TEMP"; }
trap cleanup_sparkle_key EXIT

if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
    echo "FATAL: version must be valid SemVer, for example 2.4.0 or 2.4.0-rc.1" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "FATAL: release requires a clean working tree; refusing to tag or ship local changes." >&2
    exit 1
fi

if git rev-parse --verify --quiet "refs/tags/v$VERSION" >/dev/null; then
    echo "FATAL: tag v$VERSION already exists; choose a new version or inspect the existing release." >&2
    exit 1
fi

SAIITY_VERSION="$VERSION" ./build-app.sh --notarize

# Refuse to create release metadata for a bundle that is structurally invalid or
# no longer passes Apple's local signature verifier.
plutil -lint build/sAiity.app/Contents/Info.plist >/dev/null
test -x build/sAiity.app/Contents/MacOS/sAiity
codesign --verify --deep --strict build/sAiity.app
./scripts/verify-release.sh build/sAiity.app "$VERSION"

ZIP="build/sAiity.zip"
[ -f "$ZIP" ] || { echo "FATAL: $ZIP missing after notarize"; exit 1; }

# Sparkle's edSignature is a raw Ed25519 signature of the archive, base64.
SIG=$("$SPARKLE_SIGNER" -p --ed-key-file "$SPARKLE_KEY" "$ZIP")
LEN=$(stat -f%z "$ZIP")
DATE=$(date -R)

cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>sAiity</title>
    <item>
      <title>sAiity $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$(git rev-list --count HEAD)</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url="$RELEASE_ASSET_URL"
                 length="$LEN"
                 type="application/octet-stream"
                 sparkle:edSignature="$SIG"/>
    </item>
  </channel>
</rss>
XML

cp "$ZIP" "build/sAiity-$VERSION.zip"
./scripts/validate-appcast.sh build/appcast.xml "build/sAiity-$VERSION.zip" "$VERSION"

# Only create the tag after the notarised archive, signature, appcast, and
# release copy have all completed. A failed release must not leave a tag
# behind.
git tag -a "v$VERSION" -m "sAiity $VERSION"

echo
echo "Release artifacts ready:"
echo "  build/sAiity-$VERSION.zip   ($LEN bytes, notarised, stapled)"
echo "  build/appcast.xml           (Ed25519-signed entry)"
echo
echo "Publish the GitHub release assets first, then publish the appcast last"
echo "so it never advertises a ZIP that is not available yet:"
echo
echo "  repository: https://github.com/$RELEASE_REPO"
echo "  file:       appcast.xml (repository root)"
echo "  feed:       https://enrzh.github.io/sAiity/appcast.xml"
