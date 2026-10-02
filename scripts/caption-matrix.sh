#!/bin/bash
# Run the opt-in, local-only live-caption benchmark.
#
#   SAIITY_CAPTION_BENCHMARK_DIR=/path/to/fixtures scripts/caption-matrix.sh
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    cat <<'USAGE'
Usage:
  SAIITY_CAPTION_BENCHMARK_DIR=/absolute/fixtures scripts/caption-matrix.sh
  scripts/caption-matrix.sh --check-only

The fixture directory must contain 1...12 mono Float32 16 kHz WAV files and
manifest.json. Set SAIITY_CAPTION_MATRIX_REQUIRE_MACOS27=1 to require macOS 27
and Apple Silicon for a release-device run.
SAIITY_CAPTION_BENCHMARK_MODELS accepts a comma-separated list of nemotron,
qwen-small, qwen-large, whisper (default: nemotron). Missing weights fail.
SAIITY_BENCHMARK_INCLUDE_TEXT=1 explicitly enables transcript logging.
USAGE
}

if [ "${1:-}" = "--help" ]; then usage; exit 0; fi

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "FATAL: required command '$1' is unavailable." >&2
        exit 1
    }
}

require_command xcrun
require_command sw_vers
require_command sysctl

os_major=$(sw_vers -productVersion | awk -F. '{print $1}')
arch=$(uname -m)
if [ "${SAIITY_CAPTION_MATRIX_REQUIRE_MACOS27:-0}" = "1" ]; then
    [ "$os_major" = "27" ] || {
        echo "FATAL: this run requires macOS 27; found $(sw_vers -productVersion)." >&2
        exit 1
    }
    [ "$arch" = "arm64" ] || {
        echo "FATAL: this run requires Apple Silicon; found $arch." >&2
        exit 1
    }
fi

xcrun --find swift >/dev/null || {
    echo "FATAL: Xcode's Swift toolchain is unavailable." >&2
    exit 1
}

if [ "${1:-}" = "--check-only" ]; then
    echo "caption matrix prerequisites: macOS $(sw_vers -productVersion), arch=$arch"
    echo "developer dir: $DEVELOPER_DIR"
    exit 0
fi

FIXTURES="${SAIITY_CAPTION_BENCHMARK_DIR:-}"
[ -n "$FIXTURES" ] || {
    echo "FATAL: set SAIITY_CAPTION_BENCHMARK_DIR to a local fixture directory." >&2
    usage >&2
    exit 1
}
[ -d "$FIXTURES" ] || {
    echo "FATAL: fixture directory does not exist: $FIXTURES" >&2
    exit 1
}
[ -f "$FIXTURES/manifest.json" ] || {
    echo "FATAL: golden fixture manifest is missing: $FIXTURES/manifest.json" >&2
    exit 1
}

wav_count=$(find "$FIXTURES" -maxdepth 1 -type f -iname '*.wav' | wc -l | tr -d ' ')
case "$wav_count" in
    1|2|3|4|5|6|7|8|9|10|11|12) ;;
    *) echo "FATAL: expected 1...12 WAV fixtures, found $wav_count." >&2; exit 1 ;;
esac

REPORT_DIR="${SAIITY_CAPTION_MATRIX_OUT:-build/caption-matrix}"
models="${SAIITY_CAPTION_BENCHMARK_MODELS:-nemotron}"
case ",$models," in
    *,,*) echo "FATAL: empty model selection." >&2; exit 1 ;;
esac
IFS=',' read -r -a selected_models <<< "$models"
for model in "${selected_models[@]}"; do
    case "$model" in
        nemotron|qwen-small|qwen-large|whisper) ;;
        *) echo "FATAL: unknown caption benchmark model: $model" >&2; exit 1 ;;
    esac
done

# MLX resolves shaders beside the image containing its native code, which in
# Swift Testing is the xctest image. A preflight override alone cannot fix that.
skip_build=0
if [[ ",$models," == *",qwen-"* ]] || [ "${SAIITY_CAPTION_BENCHMARK_TRANSLATION:-off}" = "madlad" ]; then
    # Use the test build mode once, then preserve the staged resources. Switching
    # from swift build --build-tests to swift test rebuilds dependencies on Xcode 27.
    xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --list-tests >/dev/null
    scripts/stage-mlx-metallib.sh
    export SAIITY_BENCHMARK_RESOURCE_ROOT="$PWD/.build/release/sAiityTests.xctest/Contents/MacOS"
    skip_build=1
fi
mkdir -p "$REPORT_DIR"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
log="$REPORT_DIR/caption-matrix-$stamp.log"
meta="$REPORT_DIR/caption-matrix-$stamp.meta"
{
    echo "date=$stamp"
    echo "macOS=$(sw_vers -productVersion)"
    echo "arch=$arch"
    echo "model=$(sysctl -n hw.model 2>/dev/null || true)"
    echo "memoryBytes=$(sysctl -n hw.memsize 2>/dev/null || true)"
    echo "fixtures=$FIXTURES"
    echo "wavCount=$wav_count"
    echo "chunkMs=${SAIITY_CAPTION_BENCHMARK_CHUNK_MS:-2240}"
    echo "runs=${SAIITY_CAPTION_BENCHMARK_RUNS:-3}"
    echo "realtime=${SAIITY_CAPTION_BENCHMARK_REALTIME:-1}"
    echo "models=$models"
    echo "translation=${SAIITY_CAPTION_BENCHMARK_TRANSLATION:-off}"
} > "$meta"

run_caption_tests() {
    if [ "$skip_build" = 1 ]; then
        xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS \
            --skip-build --filter CaptionASRPerformanceTests
    else
        xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS \
            --filter CaptionASRPerformanceTests
    fi
}

export SAIITY_CAPTION_BENCHMARK_DIR="$FIXTURES"
export SAIITY_CAPTION_BENCHMARK_MODELS="$models"
evidence_before=""
# Explicit developer downloads can create a previously absent model. Release
# runs disable downloads and require unchanged fingerprints before/after.
if [ "${SAIITY_CAPTION_BENCHMARK_DOWNLOAD:-0}" != "1" ]; then
    evidence_before=$(python3 scripts/benchmark_evidence.py "$FIXTURES" --profile captions)
fi
set +e
run_caption_tests 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e
[ "$status" -eq 0 ] || {
    echo "FATAL: caption matrix failed; see $log." >&2
    exit "$status"
}

result_count=$(grep -c '^SAIITY_CAPTION_BENCHMARK ' "$log" || true)
[ "$result_count" -gt 0 ] || {
    echo "FATAL: caption matrix produced no benchmark records; the test was skipped." >&2
    exit 1
}
for model in "${selected_models[@]}"; do
    case "$model" in
        nemotron) model_prefix="nemotron-" ;;
        whisper) model_prefix="whisper-" ;;
        *) model_prefix="$model" ;;
    esac
    grep -q "\"model\":\"$model_prefix" "$log" || {
        echo "FATAL: $model caption benchmark record is missing." >&2
        exit 1
    }
done
grep -q '"phase":"cold_prepare"' "$log" || {
    echo "FATAL: cold preparation record is missing." >&2
    exit 1
}
grep -q '"phase":"warm_live_stream"' "$log" || {
    echo "FATAL: warm live-stream record is missing." >&2
    exit 1
}

evidence_after=$(python3 scripts/benchmark_evidence.py "$FIXTURES" --profile captions)
if [ -n "$evidence_before" ] && [ "$evidence_before" != "$evidence_after" ]; then
    echo "FATAL: caption benchmark inputs changed during measurement." >&2
    exit 1
fi
printf 'SAIITY_BENCHMARK_EVIDENCE %s\n' "$evidence_after" | tee -a "$log"
cp "$log" "$REPORT_DIR/latest.log"
cp "$meta" "$REPORT_DIR/latest.meta"
echo "caption matrix passed: $result_count records"
