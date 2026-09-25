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
} > "$meta"

set +e
SAIITY_CAPTION_BENCHMARK_DIR="$FIXTURES" \
    xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS \
    --filter CaptionASRPerformanceTests 2>&1 | tee "$log"
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
grep -q '"model":"nemotron-' "$log" || {
    echo "FATAL: Nemotron caption benchmark record is missing." >&2
    exit 1
}
grep -q '"phase":"cold_prepare"' "$log" || {
    echo "FATAL: cold preparation record is missing." >&2
    exit 1
}
grep -q '"phase":"warm_live_stream"' "$log" || {
    echo "FATAL: warm live-stream record is missing." >&2
    exit 1
}

cp "$log" "$REPORT_DIR/latest.log"
cp "$meta" "$REPORT_DIR/latest.meta"
echo "caption matrix passed: $result_count records"
