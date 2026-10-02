#!/bin/bash
# Exercise resident local models and enforce accuracy and latency release budgets.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fixtures="${SAIITY_RELEASE_FIXTURES:?Set SAIITY_RELEASE_FIXTURES to a verified local speech corpus}"
report_dir="${SAIITY_RELEASE_QUALITY_OUT:-build/release-quality}"
revision=$(git rev-parse HEAD)
source_state=clean
if [ -n "$(git status --porcelain)" ]; then source_state=dirty; fi
mkdir -p "$report_dir"

# Stamp every log independently. Old, dirty and skipped runs cannot satisfy a
# release gate just because another report contains the required metric names.
run_report() {
    local log="$1"
    local profile="$2"
    local before after
    shift
    shift
    before=$(python3 scripts/benchmark_evidence.py "$fixtures" --profile "$profile")
    printf 'SAIITY_QUALITY_SOURCE %s %s\n' "$revision" "$source_state" > "$log"
    printf 'SAIITY_BENCHMARK_EVIDENCE %s\n' "$before" >> "$log"
    "$@" 2>&1 | tee -a "$log"
    after=$(python3 scripts/benchmark_evidence.py "$fixtures" --profile "$profile")
    [ "$before" = "$after" ] || { echo "FATAL: benchmark inputs changed during $profile." >&2; return 1; }
}
export SAIITY_ASR_BENCHMARK_DIR="$fixtures"
export SAIITY_CAPTION_BENCHMARK_DIR="$fixtures"
export SAIITY_CAPTION_BENCHMARK_RUNS=5
export SAIITY_CAPTION_BENCHMARK_MODELS=nemotron
export SAIITY_CAPTION_BENCHMARK_CHUNK_MS=2240
export SAIITY_CAPTION_BENCHMARK_REALTIME=1
export SAIITY_CAPTION_BENCHMARK_TRANSLATION=off
export SAIITY_DICTATION_PIPELINE_BENCHMARK=0
export SAIITY_DICTATION_BENCHMARK_CLEANUP=rules
export SAIITY_DICTATION_BENCHMARK_TRANSLATION=off
# Never permit inherited developer options to fetch model weights.
export SAIITY_CAPTION_BENCHMARK_DOWNLOAD=0
export SAIITY_CLEANUP_BENCHMARK_DOWNLOAD=0
run_report "$report_dir/asr.log" asr scripts/model-matrix.sh
run_report "$report_dir/captions.log" captions scripts/caption-matrix.sh
export SAIITY_DICTATION_PIPELINE_BENCHMARK=1
run_report "$report_dir/pipeline.log" pipeline xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS \
    --filter DictationASRPerformanceTests.completePipeline
if [ "$(git rev-parse HEAD)" != "$revision" ] || [ "$(git status --porcelain | wc -l | tr -d ' ')" != "0" ]; then
    echo "FATAL: quality measurements require unchanged, clean source." >&2
    exit 1
fi
python3 scripts/verify-quality.py --revision "$revision" --manifest "$fixtures/manifest.json" \
    "$report_dir/asr.log" "$report_dir/captions.log" "$report_dir/pipeline.log" | tee "$report_dir/summary.jsonl"
