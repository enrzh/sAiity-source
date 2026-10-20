#!/bin/bash
# Run the opt-in, local-only Nemotron/Whisper regression matrix.
#
#   SAIITY_ASR_BENCHMARK_DIR=/path/to/fixtures scripts/model-matrix.sh
#
# The fixture directory must contain mono Float32 16 kHz WAVs and a manifest.json
# with expected text/language metadata. Model weights are never downloaded by
# the test. Results are JSON lines plus a hardware header under build/.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    cat <<'USAGE'
Usage:
  SAIITY_ASR_BENCHMARK_DIR=/absolute/fixtures scripts/model-matrix.sh
  scripts/model-matrix.sh --check-only

The fixture directory must contain 1...12 mono Float32 16 kHz WAV files and
manifest.json. Set SAIITY_MODEL_MATRIX_REQUIRE_MACOS27=1 to require macOS 27
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
if [ "${SAIITY_MODEL_MATRIX_REQUIRE_MACOS27:-0}" = "1" ]; then
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
    echo "model matrix prerequisites: macOS $(sw_vers -productVersion), arch=$arch"
    echo "developer dir: $DEVELOPER_DIR"
    exit 0
fi

FIXTURES="${SAIITY_ASR_BENCHMARK_DIR:-}"
[ -n "$FIXTURES" ] || {
    echo "FATAL: set SAIITY_ASR_BENCHMARK_DIR to a local fixture directory." >&2
    usage >&2
    exit 1
}
[ -d "$FIXTURES" ] || { echo "FATAL: fixture directory does not exist: $FIXTURES" >&2; exit 1; }
[ -f "$FIXTURES/manifest.json" ] || {
    echo "FATAL: golden fixture manifest is missing: $FIXTURES/manifest.json" >&2
    exit 1
}

wav_count=$(find "$FIXTURES" -maxdepth 1 -type f -iname '*.wav' | wc -l | tr -d ' ')
case "$wav_count" in
    1|2|3|4|5|6|7|8|9|10|11|12) ;;
    *) echo "FATAL: expected 1...12 WAV fixtures, found $wav_count." >&2; exit 1 ;;
esac

REPORT_DIR="${SAIITY_MODEL_MATRIX_OUT:-build/model-matrix}"
mkdir -p "$REPORT_DIR"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
log="$REPORT_DIR/model-matrix-$stamp.log"
meta="$REPORT_DIR/model-matrix-$stamp.meta"
{
    echo "date=$stamp"
    echo "macOS=$(sw_vers -productVersion)"
    echo "arch=$arch"
    echo "model=$(sysctl -n hw.model 2>/dev/null || true)"
    echo "memoryBytes=$(sysctl -n hw.memsize 2>/dev/null || true)"
    echo "fixtures=$FIXTURES"
    echo "wavCount=$wav_count"
} > "$meta"

evidence_before=$(python3 scripts/benchmark_evidence.py "$FIXTURES" --profile asr)
set +e
SAIITY_ASR_BENCHMARK_DIR="$FIXTURES" \
    xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS \
    --filter DictationASRPerformanceTests 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e
[ "$status" -eq 0 ] || { echo "FATAL: model matrix failed; see $log." >&2; exit "$status"; }

result_count=$(grep -c '^SAIITY_ASR_BENCHMARK ' "$log" || true)
[ "$result_count" -gt 0 ] || {
    echo "FATAL: model matrix produced no benchmark records; the test was skipped." >&2
    exit 1
}
grep -q '"model":"nemotron-2240"' "$log" || {
    echo "FATAL: Nemotron benchmark record is missing." >&2
    exit 1
}
# Whisper base shares this harness. Require its records only when the
# fingerprint found an installed, ready model. A missing install is not a
# failed Nemotron run.
if printf '%s\n' "$evidence_before" | grep -q '"whisper-base"'; then
    grep -q '"model":"whisper-base"' "$log" || {
        echo "FATAL: Whisper benchmark record is missing." >&2
        exit 1
    }
fi
grep -q '"phase":"cold_prepare"' "$log" || {
    echo "FATAL: cold preparation record is missing." >&2
    exit 1
}
grep -q '"phase":"warm_segmented_decode"' "$log" || {
    echo "FATAL: warm segmented decode record is missing." >&2
    exit 1
}

evidence_after=$(python3 scripts/benchmark_evidence.py "$FIXTURES" --profile asr)
[ "$evidence_before" = "$evidence_after" ] || { echo "FATAL: ASR benchmark inputs changed during measurement." >&2; exit 1; }
printf 'SAIITY_BENCHMARK_EVIDENCE %s\n' "$evidence_after" | tee -a "$log"
cp "$log" "$REPORT_DIR/latest.log"
cp "$meta" "$REPORT_DIR/latest.meta"
echo "model matrix passed: $result_count records"
