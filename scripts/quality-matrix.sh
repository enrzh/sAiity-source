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
[ "$source_state" = clean ] || { echo "FATAL: release quality requires clean source before inference." >&2; exit 1; }
mkdir -p "$report_dir"
policy="${SAIITY_RELEASE_POLICY:-docs/benchmarks/release-quality.json}"
# Reject missing consent/reference/cohort evidence before any native command.
python3 - "$policy" "$fixtures/manifest.json" <<'PY'
import json, runpy, sys
sys.path.insert(0, "scripts")
gate = runpy.run_path("scripts/verify-quality.py")
policy = json.load(open(sys.argv[1]))
manifest = json.load(open(sys.argv[2]))
gate["reviewed_coverage"](policy, {fixture["audio"]: fixture for fixture in manifest["fixtures"]})
PY

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
    [ "$(git rev-parse HEAD)" = "$revision" ] && [ -z "$(git status --porcelain)" ] || {
        echo "FATAL: source changed during $profile." >&2; return 1;
    }
    python3 - "$revision" "$before" "$after" >> "$log" <<'PY'
import json, sys
from scripts.benchmark_evidence import digest
print("SAIITY_QUALITY_COMPLETE " + json.dumps({"revision": sys.argv[1],
    "beforeSHA256": digest(json.loads(sys.argv[2])), "afterSHA256": digest(json.loads(sys.argv[3]))}, sort_keys=True))
PY
}
export SAIITY_ASR_BENCHMARK_DIR="$fixtures"
export SAIITY_CAPTION_BENCHMARK_DIR="$fixtures"
export SAIITY_CAPTION_BENCHMARK_RUNS=5
export SAIITY_CAPTION_BENCHMARK_MODELS=nemotron
export SAIITY_CAPTION_BENCHMARK_REALTIME=1
export SAIITY_CAPTION_BENCHMARK_WHISPER=0
export SAIITY_BENCHMARK_INCLUDE_TEXT=0
export SAIITY_DICTATION_PIPELINE_BENCHMARK=0
# Never permit inherited developer options to fetch model weights.
export SAIITY_CAPTION_BENCHMARK_DOWNLOAD=0
export SAIITY_CLEANUP_BENCHMARK_DOWNLOAD=0
# Use the policy's representative cases, not a Cartesian product of every model.
matrix=$(python3 - "$policy" <<'PY'
import json, sys
policy = json.load(open(sys.argv[1]))
profiles = {"warm_segmented_decode": "asr", "warm_live_stream": "captions", "release_to_insertion": "pipeline"}
for phase, configs in policy["configurations"].items():
    for config in configs:
        print(profiles[phase], config["chunkMs"], config["cleanup"], config["translation"], config["target"] or "off")
PY
)
logs=()
while read -r profile chunk cleanup translation target; do
    export SAIITY_CAPTION_BENCHMARK_CHUNK_MS="$chunk"
    export SAIITY_CAPTION_BENCHMARK_TRANSLATION="$translation"
    export SAIITY_CAPTION_BENCHMARK_TARGET="$target"
    export SAIITY_DICTATION_BENCHMARK_CHUNK_MS="$chunk"
    export SAIITY_DICTATION_BENCHMARK_CLEANUP="$cleanup"
    export SAIITY_DICTATION_BENCHMARK_TRANSLATION="$translation"
    export SAIITY_DICTATION_BENCHMARK_TARGET="$target"
    log="$report_dir/$profile-$chunk-$cleanup-$translation-$target.log"
    case "$profile" in
        asr) run_report "$log" "$profile" scripts/model-matrix.sh ;;
        captions) run_report "$log" "$profile" scripts/caption-matrix.sh ;;
        pipeline)
            export SAIITY_DICTATION_PIPELINE_BENCHMARK=1
            # MADLAD uses the existing native test-bundle Metal staging path.
            if [ "$translation" = madlad ]; then
                xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --list-tests >/dev/null
                scripts/stage-mlx-metallib.sh
            fi
            run_report "$log" "$profile" xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS \
                --filter DictationASRPerformanceTests.completePipeline
            export SAIITY_DICTATION_PIPELINE_BENCHMARK=0 ;;
    esac
    logs+=("$log")
done <<< "$matrix"
if [ "$(git rev-parse HEAD)" != "$revision" ] || [ "$(git status --porcelain | wc -l | tr -d ' ')" != "0" ]; then
    echo "FATAL: quality measurements require unchanged, clean source." >&2
    exit 1
fi
python3 scripts/verify-quality.py --revision "$revision" --policy "$policy" --manifest "$fixtures/manifest.json" \
    "${logs[@]}" | tee "$report_dir/summary.jsonl"
