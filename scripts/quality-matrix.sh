#!/bin/bash
# Exercise resident local models and enforce accuracy and latency release budgets.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

if [ "${1:-}" = "--product" ]; then
    if [ "${2:-}" = "--help" ]; then
        cat <<'USAGE'
Usage: scripts/quality-matrix.sh --product
Requires an approved SAIITY_RELEASE_FIXTURES corpus and explicit metadata:
SAIITY_PRODUCT_VERSION, SAIITY_PRODUCT_BUILD, SAIITY_PRODUCT_MACHINE_ID,
SAIITY_PRODUCT_POWER_MODE, SAIITY_PRODUCT_THERMAL_STATE,
SAIITY_PRODUCT_MEMORY_PRESSURE. The measured test image and clean revision
are resolved from this build. Output remains copied; this memory-pasteboard
harness does not establish physical input, compositor state or visible insertion.
SAIITY_DICTATION_BENCHMARK_RUNS accepts 1..50. SAIITY_PRODUCT_LIFECYCLE is
warm (default), cold-start or post-eviction. Cold-start needs RUNS=1, an explicit
SAIITY_PRODUCT_FIXTURE and SAIITY_PRODUCT_PREVIEW=0/1 in each fresh process.
Optional SAIITY_PRODUCT_OBSERVATIONS supplies independent content-free evidence
to the product verifier. Missing evidence remains UNVERIFIED and exits nonzero.
The existing invocation without --product retains its release-matrix behavior.
USAGE
        exit 0
    fi
    [ "$#" = 1 ] || { echo "FATAL: unsupported product arguments; use --product --help." >&2; exit 1; }
    if [ -z "${CODEX_TASK_TMP:-}" ]; then
        exec /Users/enrico/.codex/bin/codex-task /bin/bash "$0" --product
    fi
    revision=$(git rev-parse HEAD)
    [ -z "$(git status --porcelain --untracked-files=all)" ] || {
        echo "FATAL: product qualification requires actual clean source before native work." >&2; exit 1;
    }
    fixtures="${SAIITY_RELEASE_FIXTURES:?Set SAIITY_RELEASE_FIXTURES to an approved natural-speech corpus}"
    policy="${SAIITY_RELEASE_POLICY:-docs/benchmarks/product-quality.json}"
    export SAIITY_PRODUCT_BENCHMARK=1 SAIITY_PRODUCT_REVISION="$revision"
    export SAIITY_ASR_BENCHMARK_DIR="$fixtures" SAIITY_DICTATION_PIPELINE_BENCHMARK=1
    export SAIITY_BENCHMARK_INCLUDE_TEXT=0 SAIITY_CAPTION_BENCHMARK_DOWNLOAD=0 SAIITY_CLEANUP_BENCHMARK_DOWNLOAD=0
    # Validate explicit conditions and independent corpus review before compiling.
    python3 - "$policy" "$fixtures/manifest.json" <<'PY'
import json, os, runpy, sys
from scripts.benchmark_evidence import configuration
names = {"version": "VERSION", "build": "BUILD", "revision": "REVISION", "machineID": "MACHINE_ID",
         "powerMode": "POWER_MODE", "thermalState": "THERMAL_STATE", "memoryPressure": "MEMORY_PRESSURE"}
product = {key: os.environ.get("SAIITY_PRODUCT_" + suffix) for key, suffix in names.items()}
product["binary"] = "/pending-measured-test-image"
configuration("pipeline", product=product)
gate = runpy.run_path("scripts/verify-quality.py")
with open(sys.argv[1]) as stream: policy = json.load(stream)
with open(sys.argv[2]) as stream: manifest = json.load(stream)
gate["reviewed_coverage"](policy, {row["audio"]: row for row in manifest["fixtures"]})
PY
    report_dir="${SAIITY_RELEASE_QUALITY_OUT:-$CODEX_TASK_ARTIFACTS}"
    mkdir -p "$report_dir"
    stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
    swift_scratch="${SAIITY_SWIFT_SCRATCH:-$CODEX_TASK_TMP/swift}"
    xcrun swift test --scratch-path "$swift_scratch" --disable-automatic-resolution \
        -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS --list-tests \
        > "$report_dir/product-compile-$stamp.log" 2>&1
    bin_path=$(xcrun swift build --scratch-path "$swift_scratch" -c release --show-bin-path)
    export SAIITY_TEST_BUNDLE="$bin_path/sAiityTests.xctest"
    export SAIITY_PRODUCT_BINARY="$SAIITY_TEST_BUNDLE/Contents/MacOS/sAiityTests"
    [ -f "$SAIITY_PRODUCT_BINARY" ] || { echo "FATAL: measured native test image is missing." >&2; exit 1; }
    if [ "${SAIITY_DICTATION_BENCHMARK_TRANSLATION:-off}" = madlad ]; then
        scripts/stage-mlx-metallib.sh > "$report_dir/product-metal-$stamp.log" 2>&1
    fi
    metadata=(--product --binary "$SAIITY_PRODUCT_BINARY" --version "$SAIITY_PRODUCT_VERSION"
        --build "$SAIITY_PRODUCT_BUILD" --revision "$revision" --machine-id "$SAIITY_PRODUCT_MACHINE_ID"
        --power-mode "$SAIITY_PRODUCT_POWER_MODE" --thermal-state "$SAIITY_PRODUCT_THERMAL_STATE"
        --memory-pressure "$SAIITY_PRODUCT_MEMORY_PRESSURE")
    before=$(python3 scripts/benchmark_evidence.py "$fixtures" --profile pipeline "${metadata[@]}")
    log="$report_dir/product-batch-$stamp.log"
    printf 'SAIITY_QUALITY_SOURCE %s clean\nSAIITY_BENCHMARK_EVIDENCE %s\n' "$revision" "$before" > "$log"
    xcrun swift test --scratch-path "$swift_scratch" --disable-automatic-resolution --skip-build \
        -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS \
        --filter DictationASRPerformanceTests.completePipeline 2>&1 | tee -a "$log"
    after=$(python3 scripts/benchmark_evidence.py "$fixtures" --profile pipeline "${metadata[@]}")
    [ "$before" = "$after" ] || { echo "FATAL: product inputs changed during measurement." >&2; exit 1; }
    python3 - "$revision" "$before" "$after" >> "$log" <<'PY'
import json, sys
from scripts.benchmark_evidence import digest
print("SAIITY_QUALITY_COMPLETE " + json.dumps({"revision": sys.argv[1],
    "beforeSHA256": digest(json.loads(sys.argv[2])), "afterSHA256": digest(json.loads(sys.argv[3]))}, sort_keys=True))
PY
    printf 'Content-free product batch retained: %s\n' "$log"
    if [ -z "${SAIITY_PRODUCT_OBSERVATIONS:-}" ]; then
        echo "UNVERIFIED: copied output requires independent observations and semantic reviews; no visible-insertion qualification." >&2
        exit 1
    fi
    python3 scripts/verify-quality.py --product --revision "$revision" --policy "$policy" \
        --manifest "$fixtures/manifest.json" --observations "$SAIITY_PRODUCT_OBSERVATIONS" "$log" \
        | tee "$report_dir/product-summary-$stamp.jsonl"
    exit 0
fi

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
# Required cases always run. futureTier cases are appended only when their
# weights and reviewed references exist; each omission is one explicit line.
effective_policy="$report_dir/effective-policy.json"
matrix=$(python3 - "$policy" "$fixtures/manifest.json" "$effective_policy" <<'PY'
import json, os, runpy, sys
from pathlib import Path
sys.path.insert(0, "scripts")
gate = runpy.run_path("scripts/verify-quality.py")
policy = json.load(open(sys.argv[1]))
manifest = json.load(open(sys.argv[2]))
plan = gate["release_plan"](policy, manifest, environment=os.environ)
Path(sys.argv[3]).write_text(json.dumps(plan["policy"], indent=2) + "\n")
for skip in plan["skips"]:
    print(gate["skip_line"](skip["case"], skip["reason"]), file=sys.stderr)
profiles = {"warm_segmented_decode": "asr", "warm_live_stream": "captions", "release_to_insertion": "pipeline"}
for run in plan["runs"]:
    config = run["configuration"]
    print(profiles[run["phase"]], config["chunkMs"], config["cleanup"], config["translation"], config.get("target") or "off")
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
                legacy_bin_path=$(xcrun swift build -c release --show-bin-path)
                export SAIITY_TEST_BUNDLE="$legacy_bin_path/sAiityTests.xctest"
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
python3 scripts/verify-quality.py --revision "$revision" --policy "$effective_policy" --manifest "$fixtures/manifest.json" \
    "${logs[@]}" | tee "$report_dir/summary.jsonl"
