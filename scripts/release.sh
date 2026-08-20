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

git tag -a "v$VERSION" -m "sAiity $VERSION" 2>/dev/null || echo "tag v$VERSION exists, reusing"

./build-app.sh --notarize

ZIP="build/sAiity.zip"
[ -f "$ZIP" ] || { echo "FATAL: $ZIP missing after notarize"; exit 1; }

# Sparkle's edSignature is a raw Ed25519 signature of the archive, base64.
SIG=$(openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$ZIP" | base64)
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
