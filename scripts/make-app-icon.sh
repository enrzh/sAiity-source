#!/bin/bash
# Recompile Resources/AppIcon.icns from the Icon Composer source.
#
# ## Why this exists
#
# The app icon is a compiled artifact: `build-app.sh` copies
# `Resources/AppIcon.icns` into the bundle, and `make-dmg.sh` /
# `make-local-dmg.sh` reuse that same file as the disk image's volume icon. For
# a long time the `.icns` was the only thing in git — a binary with no source,
# which meant the icon could be swapped but never rebuilt.
#
# `Resources/AppIcon.icon` is that source: an Icon Composer package (three SVG
# layers on an automatic gradient, with translucency and a neutral shadow).
# Icon Composer is a GUI, and its compiler is not a standalone tool — it is
# `actool`, which Xcode's build system invokes as the Asset Catalog Compiler
# for the `folder.iconcomposer.icon` file type. So this script is just that
# invocation, written down.
#
# ## What it produces
#
# `--standalone-icon-behavior all` is what makes an `.icns` appear at all.
# Without it actool folds the icon into `Assets.car`, which the app does not
# ship — a hand-assembled bundle has no asset catalog step. `all` writes every
# representation (16 through 1024, plus the @2x variants) rather than the
# default subset, so Finder's largest icon view and the Dock both stay sharp.
#
# The result is byte-identical run to run, so an unchanged source is a no-op
# and `git status` stays clean. The `.car` and the partial Info.plist that
# actool also writes are discarded: the app keys off `CFBundleIconFile`, which
# `Resources/Info.plist` already sets to `AppIcon`.
#
# ## Usage
#
#   scripts/make-app-icon.sh            # rebuild Resources/AppIcon.icns
#
# Afterwards, refresh the 1024 PNG the appiconset keeps alongside it:
#
#   sips -s format png Resources/AppIcon.icns \
#       --out Resources/AppIcon.appiconset/icon_1024.png
#
# Requires Xcode's command line tools (`DEVELOPER_DIR`), not just the CLT
# package — `actool` ships with Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="Resources/AppIcon.icon"
OUTPUT="Resources/AppIcon.icns"
PNG="Resources/AppIcon.appiconset/icon_1024.png"

[ -d "$SOURCE" ] || { echo "FATAL: $SOURCE not found." >&2; exit 1; }

# LSMinimumSystemVersion in Resources/Info.plist. actool reads this to decide
# which representations are worth emitting; matching the app avoids generating
# sizes the app can never ask for.
MIN_TARGET=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

xcrun actool --compile "$WORK" \
    --platform macosx \
    --minimum-deployment-target "$MIN_TARGET" \
    --app-icon AppIcon \
    --standalone-icon-behavior all \
    --output-partial-info-plist "$WORK/partial.plist" \
    --output-format human-readable-text \
    "$SOURCE" >/dev/null

[ -f "$WORK/AppIcon.icns" ] || {
    echo "FATAL: actool produced no AppIcon.icns." >&2
    exit 1
}

if [ -f "$OUTPUT" ] && cmp -s "$WORK/AppIcon.icns" "$OUTPUT"; then
    echo "unchanged: $OUTPUT already matches $SOURCE"
else
    cp "$WORK/AppIcon.icns" "$OUTPUT"
    echo "wrote: $OUTPUT ($(wc -c <"$OUTPUT" | tr -d ' ') bytes)"
fi

# The appiconset PNG is unreferenced by the build but is kept in step with the
# .icns so the two never disagree about what the icon looks like.
xcrun sips -s format png "$OUTPUT" --out "$PNG" >/dev/null
echo "wrote: $PNG"

echo "source: $SOURCE"
