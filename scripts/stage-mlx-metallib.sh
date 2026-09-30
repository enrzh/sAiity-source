#!/bin/bash
# Stage MLX's compiled Metal shaders where `swift test` can find them.
#
# ## Why this is needed
#
# Every MLX backend operation aborts with "Failed to load the default metallib"
# under `swift test`. MLX resolves the library through `NSBundle`: it walks
# `NSBundle.allBundles()` looking for a resource bundle, and falls back to a path
# resolved against the running binary. Under the test runner, `Bundle.main` is
# Xcode's helper tool rather than the app, so the bundle that works perfectly in
# `build/sAiity.app` is invisible. `build-app.sh` solves it for the app by running
# xcodebuild for the Cmlx target and embedding `mlx-swift_Cmlx.bundle`; nothing did
# that for the test bundle, which is why `MADLADRealModelTests` recorded the same
# failure as an unfixable dead end.
#
# ## What it does
#
# Copies the metallib bundle the app build already produced into the test bundle,
# and also drops a copy beside the test binary. Both layouts are needed: the
# bundle carries both a macOS app layout (`Contents/...`) and a SwiftPM resource
# layout (files at the bundle root), and MLX tries them in turn.
#
# ## Usage
#
#   scripts/stage-mlx-metallib.sh            # stage, if a built app exists
#   scripts/stage-mlx-metallib.sh --check    # report where the library would land
#
# Re-run after `swift build` — SwiftPM empties the test bundle's Resources on a
# rebuild, which silently undoes this. That is why the probe documents the
# failure rather than assuming the library is still there.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_BUNDLE="build/sAiity.app/Contents/Resources/mlx-swift_Cmlx.bundle"
TESTS=".build/out/Products/Release/sAiityTests.xctest"
MACOS_DIR="$TESTS/Contents/MacOS"

if [ ! -f "$APP_BUNDLE/default.metallib" ]; then
    echo "FATAL: no metallib at $APP_BUNDLE — run ./build-app.sh first." >&2
    exit 1
fi

if [ "${1:-}" = "--check" ]; then
    echo "source:  $APP_BUNDLE/default.metallib"
    echo "bundle:  $TESTS/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"
    echo "colocated: $MACOS_DIR/default.metallib"
    exit 0
fi

# SwiftPM leaves an empty mlx-swift_Cmlx.bundle behind. Copying into it nests a
# second copy one level down, which MLX does not find — so replace it outright.
rm -rf "$TESTS/Contents/Resources/mlx-swift_Cmlx.bundle"
mkdir -p "$TESTS/Contents/Resources"
cp -R "$APP_BUNDLE" "$TESTS/Contents/Resources/"

# The colocated fallback: relative to the running binary.
mkdir -p "$MACOS_DIR/Resources"
cp "$APP_BUNDLE/default.metallib" "$MACOS_DIR/default.metallib"
cp "$APP_BUNDLE/default.metallib" "$MACOS_DIR/Resources/mlx.metallib"

echo "staged MLX metallib for $TESTS"
