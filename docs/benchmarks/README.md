# Local ASR fixtures

Keep real recordings out of Git. A fixture directory used by
`scripts/model-matrix.sh` contains mono Float32 16 kHz WAV files and a sidecar
`manifest.json`:

```json
{
  "fixtures": [
    {
      "audio": "german-english.wav",
      "expectedText": "Das ist ein test and now I am speaking English.",
      "expectedLanguages": ["de", "en"],
      "categories": ["mixed"],
      "maxWER": 0.25
    }
  ]
}
```

The benchmark runs Nemotron and Whisper sequentially, keeps model weights
resident between regions, and emits latency, real-time factor, WER, and
language-preservation fields. Use separate reports for before/after changes;
do not compare cold preparation with warm segmented decode.

For a real-time caption soak with the same local fixtures, run:

```sh
SAIITY_CAPTION_BENCHMARK_DIR=/absolute/fixtures scripts/caption-matrix.sh
```

That harness reports first volatile/final caption latency, backlog, dropped
audio, and real-time factor. It never downloads weights.

Select production engines with `SAIITY_CAPTION_BENCHMARK_MODELS=nemotron,qwen-small,qwen-large,whisper`.
Select only installed engines; missing weights fail explicitly. Qwen uses the
application's VAD and ten-second force cuts. Its MLX tests need a built app;
the matrix reuses `scripts/stage-mlx-metallib.sh` to stage shaders in the test
image. Set `SAIITY_CAPTION_BENCHMARK_RUNS=5` for five warm repetitions.
`SAIITY_CAPTION_BENCHMARK_TRANSLATION=madlad` or `hy-mt2` adds concurrent
translation through the same serialized gate and four-request bound as the
app; the default target is German, overridable with
`SAIITY_CAPTION_BENCHMARK_TARGET`. Records include skipped translations, native
failures, gate wait and translation drain time. Each engine's weights remain
resident between runs. Inference remains sequential within each model.

Measure release through the production dictation controller and insertion:

```sh
SAIITY_ASR_BENCHMARK_DIR=/absolute/fixtures \
SAIITY_DICTATION_PIPELINE_BENCHMARK=1 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS \
  --filter DictationASRPerformanceTests.completePipeline
```

This runs both preview states, five times per fixture, with retained fixture PCM
instead of a microphone and an in-memory pasteboard instead of user documents.
Cleanup defaults to `rules`; `SAIITY_DICTATION_BENCHMARK_CLEANUP=off|rules|model`
chooses the stage. `model` requires the already-installed selected cleanup model.
`SAIITY_DICTATION_BENCHMARK_TRANSLATION=off|hy-mt2|madlad` chooses translation;
`SAIITY_DICTATION_BENCHMARK_TARGET` defaults to German. Run
`scripts/stage-mlx-metallib.sh` after building tests for MADLAD. The harness keeps
the safe production cleanup/translation eviction policy. It fails if a requested
stage silently falls back. It measures the clipboard insertion path; real focused
field paste and acoustic quality still require device testing.

`SAIITY_NATIVE_GENERATION_BENCHMARK=1` with `--filter LocalGenerationTests.nativeLimits`
checks token limits, deadlines, cancellation acknowledgement and a following
successful request using installed Hy-MT2. `SAIITY_CLEANUP_BENCHMARK=1` with
`--filter DictationPerformanceTests` evaluates semantic cleanup assertions and
five repetitions; missing models fail unless the caller explicitly enables
`SAIITY_CLEANUP_BENCHMARK_DOWNLOAD=1`.

All new measurements include physical memory footprint, rather than RSS alone.
With reference transcripts the ASR reports include WER, CER and missing words
(CJK symbols are individual tokens for WER). Transcript content is omitted by
default. Set `SAIITY_BENCHMARK_INCLUDE_TEXT=1` only when inspecting local fixture
wording intentionally. Reports without verified references cannot establish
accuracy or justify changing recommendations. Keep real microphone recordings
outside Git, and cover German, English, French, Spanish, mixed languages,
accents, quiet speech, technical terms, quoted instructions, continuous speech,
noise/music and silence followed by speech.

## Release acceptance

`scripts/release.sh` runs `scripts/quality-matrix.sh` before notarizing or
tagging. Set `SAIITY_RELEASE_FIXTURES` to a verified local corpus. Each fixture
needs expected text, language metadata and `categories`. Across the corpus,
include `german`, `english`, `mixed`, `noise` and `technical`. A fixture may cover
several categories. Verify the references by listening; synthesized speech and
an ASR model's own output do not establish natural-speech accuracy. Include
short and long phrases, names/numbers, quiet speech and language switches inside
a sentence. Keep audio and the reference text outside Git.

The runner reuses the existing ASR, paced-caption and complete-dictation
harnesses. It runs five warm repetitions, both dictation preview states, keeps
weights resident during each harness, and explicitly disables downloads.
`docs/benchmarks/release-quality.json` defines initial acceptance budgets:

| Measurement | Maximum |
| --- | --- |
| WER for each run | 25% |
| Missing words for each run | 2 |
| Dictation ASR p95 real-time factor | 1.0 |
| Caption first text / first final p95 | 5 / 8 seconds |
| Caption finalization p95 | 5 seconds |
| Dropped caption audio | 0 seconds |
| Rules-cleanup dictation release-to-insertion p95 | 8 seconds |

Language-span preservation must pass on every run. Missing/null/non-finite
metrics, missing preview modes, duplicate runs, missing speech categories and
stale/dirty source reports fail. Accuracy uses the worst run so an occasional
lost-word or translation regression cannot hide behind a percentile. Summaries
contain p50/p95 and measured memory footprint, without transcript contents.
Cold model load is recorded separately and never combined with warm inference.
The five-run p95 is the worst of five observations, not a reliable estimate of
the production tail; longer device runs remain necessary.

These are explicit initial acceptance targets, not a claim that every supported
device/model meets them. Change budgets only alongside reviewed measurements;
do not loosen them merely to make a release pass. The default gate covers
Nemotron and Whisper dictation, Nemotron live captions, and deterministic
cleanup. Model cleanup and translated dictation need the existing additional
native-generation/cleanup/translation benchmarks and signed-app checklist.

```sh
SAIITY_RELEASE_FIXTURES=/absolute/verified-fixtures scripts/quality-matrix.sh
python3 Tests/release_quality_test.py
```

Reports are written to `build/release-quality/` (override with
`SAIITY_RELEASE_QUALITY_OUT`). Each log names the exact clean Git revision;
the source must stay unchanged until measurement completes. To inspect existing
reports against the same policy:

```sh
python3 scripts/verify-quality.py --revision FULL_GIT_SHA \
  --manifest /absolute/verified-fixtures/manifest.json \
  build/release-quality/asr.log build/release-quality/captions.log \
  build/release-quality/pipeline.log
```

## 2 October 2026 project verification

Implemented the CI build-mode correction and toolchain-specific cache, explicit
release accuracy/latency gate, production-path setup trials, concrete caption
resource and translator lifetime owners, and current build/translation/platform
documentation. Windows prototype jobs are now manual. Existing uncommitted and
untracked project work was retained; this verification includes that work on
`main` at baseline `a3659a3`.

The native smoke test exposed stale saved dictation dimensions overriding the
Minimal preset. Recording now restores position while sizing from the current
preset. A related frame test now checks position plus configured width/54-point
height, and an additional oversized-frame regression covers recording → result
→ recording. Workflow review also found the existing focused-app insertion
guard disconnected from the controller: focus is now captured at press, passed
through the insertion protocol, and checked before pasting. A changed or unknown
app receives a clipboard copy without a synthetic paste.

Local evidence on macOS 27.0 / Apple Silicon:

- Supported release test command: **597 tests / 76 suites passed**, 19.112 s.
  Log: `/tmp/saiity-project-improvements-tests.log`.
- Standard-library release-gate checks: **7 tests passed**, including missing
  runs, wrong preview mode, invalid/non-finite metrics, stale/dirty source,
  malformed JSON and an individual accuracy failure among twenty runs.
- `./build-app.sh --no-test-hooks`: signed bundle, bundled native resources,
  version and absence of test hooks verified.
  Log: `/tmp/saiity-project-improvements-build.log`.
- Signed application's `--selftest 20`: **24 native checks passed**, including
  all four bubble presets, caption clear/new content, dictation result/reset and
  all three setup trial layouts. No audio was captured by this smoke test.
  Log: `/tmp/saiity-project-improvements-smoke.log`.
- German setup layouts inspected from a separate temporary QA bundle using the
  existing capture harness: `/tmp/saiity-project-qa.GlLMh1/captures/`.
  The temporary preferences domain was removed afterward.

These gates do **not** establish speech accuracy or release-to-paste speed on
real recordings, M4 MacBook Air behavior, macOS 26 behavior, real focused-field
paste, permission recovery, device changes/sleep, DMG installation or Sparkle
upgrade. A verified licensed corpus and the device checks in
`docs/release-checklist.md` remain required. No new release or publication was
performed. Build timings were affected by other Xcode jobs on this Mac and are
not inference performance measurements.

## 1–2 October 2026 processing implementation

Source baseline: `a3659a3` on `main`. Hardware: Mac mini M1 (`Macmini9,1`),
16 GB, macOS 27.0 / 26A428. These are local development measurements, not M4
MacBook Air results. The three installed WAV fixtures have no verified reference
transcripts, so these runs establish timing and delivery only. No weights were
downloaded. Each warm row below uses five repetitions; p95 is the largest of
those five samples, not a reliable population tail estimate.

The implementation makes recognition errors terminal and releases all drain
waiters; bounds Qwen's silent PCM history; applies independent authoritative
dictation decoding with either preview state; preserves per-region language tags
and intentional repetitions; tightens cleanup eligibility and meaning checks;
quotes prompt input and strictly parses batch markers; bounds native generation
without releasing its model early; and persists ordered source rows before
append-only translation updates. The existing four-translation bound and model
eviction policy remain in place. Recommendations remain Nemotron and Gemma 3 1B.

Changed application files, grouped by responsibility:

- Capture and captions: `TranscriptionBackend.swift`, `StreamingASRBackend.swift`,
  `QwenASREngine.swift`, `SystemAudioCapture.swift`, `CaptionProcessing.swift`,
  `MemoryPolicy.swift`, and `AppDelegate.swift`.
- Dictation: `DictationController.swift`, `DictationTranscription.swift`,
  `WhisperDictationBackend.swift`, `DictationCleanupSession.swift`, and
  `DictationCleanupValidator.swift`.
- Text models, translation and recording: `LocalGeneration.swift`,
  `Translators.swift`, `HyMT2Translator.swift`, `TranslationEngine.swift`,
  `TranslationOutputValidator.swift`, and `TranscriptStore.swift`.
- Harness and integration: `DictationBenchmarking.swift`, `Package.swift`,
  `Vendor/SaiityLLM/`, `Resources/Localizable.xcstrings`, focused regression and
  performance tests, `scripts/caption-matrix.sh`, and `build-app.sh`.

The LLM wrapper patch is repository-owned and pinned to the already-resolved
upstream revision. Its native binary is unchanged. A native prompt-evaluation
or individual decode call still cannot be interrupted; cancellation waits for
completion. Token/time/context exhaustion discards partial generated output.
Rejected cleanup retains the validated deterministic baseline or source.
Examples covered by the tests include a translated mixed transcript, removed
negation/uncertainty, duplicate/reordered batch markers, and literal punctuation
words being mistaken for formatting commands.

### Caption comparison

Nemotron 2240, translation off, paced PCM; all 15 warm runs in each cohort had
zero dropped audio. The baseline is `/tmp/saiity-plan-baseline.zhEAmJ/latest.log`;
the after run is `/tmp/saiity-plan-after.YzUNn9/latest.log`.

| Fixture | First text p50 before → after | First final p50 before → after | Finalization p50 / p95 before → after | RTF p50 before → after |
| --- | --- | --- | --- | --- |
| Spanish | 2.410 → 2.442 s | 4.713 → 4.790 s | 0.124 / 0.130 → 0.123 / 0.191 s | 0.0523 → 0.0646 |
| Japanese | 2.410 → 2.404 s | 2.778 → 2.777 s | 0.079 / 0.086 → 0.075 / 0.080 s | 0.0419 → 0.0390 |
| JFK English | 2.415 → 2.409 s | 4.693 → 4.690 s | 0.115 / 0.135 → 0.131 / 0.145 s | 0.0444 → 0.0447 |

This does not establish a general caption speed improvement. Spanish RTF was
23% higher in this cohort, with the slowest run accumulating 0.24 seconds of
backlog; later Spanish runs were faster. This is reported rather than hidden
in an overall average. Warm physical-memory snapshots after the change were
approximately 52–72 MiB; no comparable baseline footprint was recorded.

The deterministic Qwen test advances one hour of silence while retaining at
most 16,000 Float32 samples (64 kB), versus the previous unbounded storage of
approximately 230 MB per hour. Closed and continuously active slices are capped
at ten seconds, with rounded absolute VAD sample positions and conservation of
speech samples. Real Qwen latency/memory remains unmeasured because its production
weights are not installed.

### Dictation and native generation

The complete controller harness uses an in-memory pasteboard and real installed
Nemotron, with five releases for each fixture and preview state. Rules cleanup
does not load an LLM. The following includes transcription, cleanup and insertion:

| Fixture | Preview off p50 / p95 | Preview on p50 / p95 | Rules cleanup p50 off / on |
| --- | --- | --- | --- |
| Spanish | 0.417 / 0.478 s | 0.447 / 0.465 s | 10.0 / 9.4 ms |
| Japanese | 0.146 / 0.178 s | 0.236 / 0.371 s | 1.4 / 2.1 ms |
| JFK English | 0.427 / 0.476 s | 0.897 / 1.073 s | 11.2 / 16.5 ms |

Preview on has additional capture-time recognition and never replaces the final
segmented decode. On the longer English clip it added about 470 ms to median
release latency in this cohort. There is no pre-change complete-dictation
baseline, so these are a comparison of the new preview states, not an asserted
improvement over the former single-session preview path. Physical-memory
snapshots were roughly 60–81 MiB.

Native Hy-MT2 runtime verification passed token exhaustion, a zero-duration
budget, cancellation acknowledgement, and a subsequent successful request.
Preparation was 1.581 seconds; cancellation acknowledged in 0.095 seconds; the
following short translation took 0.642 seconds (12 generated tokens). Logs:
`/tmp/saiity-processing-verified-tests.log`. These measurements do not establish
Gemma cleanup performance.

### Verification and remaining evidence

The exact repository-supported release-test command passed: 573 tests in 74
suites. Real-weight suites remain opt-in in a normal run. A separate full
serialized run with the native Hy-MT2 checks also passed (572 cases before the
last overlap regression was added). Early parallel runs exposed process-wide
test-directory/preference interference; transcript tests now use their existing
task-local library, and speech-gap concurrency tests inject settings into the
same capture method instead of racing unrelated preferences. Assertions were
retained. The latest default parallel release suite is green.

The migration suite also snapshots shared preference keys and now serializes
its own cases; its original assertions are unchanged. The final parallel run,
including the personal-name/ordinary-greeting regression assertions, passed
all 573 registered cases in 74 suites in 17.504 seconds.

Localization JSON and coverage checks passed (715 catalog keys), shell syntax
checks passed, and `git diff --check` passed. `./build-app.sh` built and signed
the local app successfully, and `--selftest 20` passed the launch body, editing
menu routing, run loop and window-server checks on macOS 27. Logs:
`/tmp/saiity-processing-app-build-verified.log` and
`/tmp/saiity-processing-launch-smoke.log`.

The normal build originally called the release-only verifier despite deliberately
including local test hooks. `build-app.sh` now verifies the local signature and
launch separately; hook-free/notarized builds still run the unchanged stricter
release verifier. A direct release-verifier check correctly rejected the local
hook-enabled bundle with exit status 1.

The built-in capture harness rendered all five settings panes without a crash.
Captions and dictation captures were inspected at
`/tmp/saiity-processing-ui.GHNTvC/`. Native interactive QA was blocked twice by
the computer-use bridge returning `Sky Computer Use native pipe closed before
response`. The launch and view-capture evidence does not replace manual keypress,
model-switch and clear/restart interaction testing.

### Translation pipeline measurements

Both preview states passed five iterations per fixture with translation alone
and with rules cleanup plus Hy-MT2: 60 complete translated dictations, with
assertions that translation happened and enabled cleanup stayed available.

| Fixture | Hy-MT2 only, preview off p50 / p95 | Hy-MT2 only, preview on p50 / p95 | Rules + Hy-MT2, preview off p50 / p95 | Rules + Hy-MT2, preview on p50 / p95 |
| --- | --- | --- | --- | --- |
| Spanish | 2.295 / 2.672 s | 2.728 / 3.656 s | 1.936 / 2.949 s | 2.027 / 2.219 s |
| Japanese | 0.647 / 0.680 s | 0.660 / 1.157 s | 0.546 / 0.570 s | 0.543 / 0.572 s |
| JFK English | 2.759 / 2.780 s | 1.926 / 1.988 s | 2.058 / 2.792 s | 1.797 / 2.061 s |

These are separate warm cohorts, not proof that enabling cleanup speeds up
translation. The small sample and preparation/thermal variation matter.
Physical-memory snapshots were roughly 274–302 MiB. Logs:
`/tmp/saiity-processing-dictation-rules.log`,
`/tmp/saiity-processing-dictation-translation.log`, and
`/tmp/saiity-processing-dictation-both.log`.

The recommended MADLAD path also ran with real installed weights concurrently
with paced Nemotron capture, five times per fixture. It translated all 30 final
caption lines with zero declined lines, native failures or lost audio. Cold
translation preparation was 3.531 seconds. Median first text was 2.413 seconds
for Spanish, 2.401 for Japanese and 2.425 for English; median summed gate wait
per clip was below 0.2 ms. Physical-memory snapshots were approximately
2,098–2,165 MiB. See `/tmp/saiity-plan-after.YzUNn9/madlad/latest.log`.
This observed workload does not justify retaining an additional cleanup model
on a constrained device.

The matrix stages the existing compiled Metal library after building in test
mode, then runs with `--skip-build`. This avoids both wiping staged resources
and the full dependency rebuild caused by alternating `swift build --build-tests`
and `swift test` on this Xcode version.
A rerun of this corrected workflow passed in 26.315 seconds with a 2.41-second
build step, three additional translated clips and no failures; its output is
`/tmp/saiity-plan-after.YzUNn9/madlad-workflow-check/latest.log`.

Missing evidence: real production Qwen 0.6B/1.7B runs, eligible Gemma cleanup and
Gemma-plus-translation coexistence, verified acoustic references for the broader
language/noise/technical corpus, M4 MacBook Air validation, and focused-field
insertion on another app. Same-script switches consisting of very short spans
can still lack reliable language evidence. The implementation keeps unknown
language metadata unknown rather than assigning the first region's language.
Until those measurements exist, no residency relaxation, model recommendation
change or universal subsecond promise is justified.

## 2 October 2026: mixed translation and multiple speakers

Hy-MT2 now receives an explicit mixed-source contract: translate every spoken
span into the requested target, preserving content already in that target.
Caption and dictation translation share `TranslationProcedure`, which preserves
region order and CJK spacing, retries only missing batch outputs and rejects
the combined result if any requested region fails. A source-language hint cannot
by itself skip a mixed region. Same-target shortcuts require confident text
evidence and check strong foreign-word hints (including short switches such as
“Can you bitte send it today?”). Unknown caption spans reach automatic
translation instead of silently remaining in a supposedly translated result.
Recognition/cleanup remain local and keep their existing language-preservation
and cancellation contracts. Language classification is still heuristic; very
short ambiguous switches need acoustic validation.

Installed Hy-MT2 passed seven synthetic mixed-language cases with expected
meaning-bearing terms: German/English in both directions, English/Chinese,
three-language input and numeric content. Calls took 0.60–1.14 seconds in the
last focused run on this M1 Mac mini. These are text-translation measurements,
not release-to-insertion timings or a general accuracy score. Run them with
`SAIITY_HYMT2_MIXED=1` and `--filter HyMT2TranslationTests.realMixedLanguage`.
Logs: `/tmp/saiity-speakers-focused-native.log` and
`/tmp/saiity-speakers-final-focused.log`.

Optional multiple-person captions use FluidAudio's existing LS-EEND DIHARD III
CoreML adapter (up to ten voices), with no additional dependency or account.
Enable **Captions → Advanced → Capture → Identify speakers** and explicitly
download **Speaker identification** through the existing Models controls. The
feature defaults off and never downloads at session start. The loaded model is
owned by one CPU queue for the entire caption session; recognition and translation
continue on their existing engines. Pending PCM is capped at five seconds, and
confirmed speaker evidence at 120 seconds. Overload or model failure disables
labels rather than stalling captions or feeding discontinuous PCM to the model.

Labels are anonymous and local to the session: “Speaker 1”, “Speaker 2”, etc.
Language changes and pauses are not used as identity guesses. When a sentence
contains consecutive voices without usable word timestamps, its row names both
voices rather than assigning its words to one person. Simultaneous activity is
marked “Overlapping voices”; this does not isolate overlapping words or create
a second transcription. Live text does not wait for labels. Confirmed labels
patch the original saved row by stable session/index, including after recording
closes, and appear in bubble history, the transcript viewer and TXT/Markdown/
SRT/VTT exports. Deprecated `speaker-*` metadata remains readable and is not
mistaken for new acoustic evidence.

ASR timestamps now include discarded backlog in the captured sample clock.
The clock is frozen atomically when the next inference batch is selected, so
a concurrent later drop cannot shift the active batch. This also keeps speaker
evidence aligned after ASR overload. Native diarization is drained before model
release, final evidence is applied before the next session and older callbacks
cannot move its timeline backwards.

Mocked tests cover speaker turns, recurring identities, overlap, bounded history,
serial processing, stop/drain ownership, overload, final evidence, late recording
patches, exports, legacy records, translation cancellation and incomplete mixed
output. Real speaker weights and verified multi-person audio are not installed
on this machine; no diarization accuracy or latency claim is established yet.
The opt-in `CaptionSpeakerTests.installedModel` fails explicitly if either is
missing. Use a local `SAIITY_SPEAKER_BENCHMARK_DIR` containing `speakers.wav`
(16 kHz mono PCM, at most 60 seconds) and:

```json
{
  "turns": [
    { "start": 1.0, "end": 3.0, "speaker": "a", "overlapping": false },
    { "start": 4.0, "end": 6.0, "speaker": "b", "overlapping": false },
    { "start": 7.0, "end": 9.0, "speaker": "a", "overlapping": false },
    { "start": 10.0, "end": 11.0, "speaker": null, "overlapping": true }
  ]
}
```

Reference names need not match the model's anonymous numbers: the test checks
consistent one-to-one identity mapping, recurring voices and overlap. Include
quiet/short turns, accents, music/noise, several people and microphone mixing
before relying on live labels. The model is subject to its own domain and
one-hour-recording limits documented by FluidAudio.

Final local verification passed on 2 October: 590 registered tests in 76 suites
with the repository-supported release command (19.564 seconds), localization
coverage/JSON checks (725 keys), shell syntax checks and `git diff --check`.
The transcript library cache now keys by full session path, so two library roots
with matching timestamp names and file stamps cannot share a cached session.
The deterministic regression uses the existing nested task-local test helper.
Logs: `/tmp/saiity-speakers-resumed-tests.log`.

The normal `./build-app.sh` build, signature verification and macOS 27
`--selftest 20` launch checks also passed. This is a local hook-enabled build;
the strict release verifier still rejects test hooks. Logs:
`/tmp/saiity-speakers-app-build.log` and `/tmp/saiity-speakers-launch.log`.
The built-in capture harness rendered all five settings panes without a crash;
captions and dictation captures were inspected at
`/tmp/saiity-speakers-ui.kGZ4PN/`. Interactive and real speaker-acoustic QA remain
distinct from these checks. No weights were downloaded and no release or DMG
was created.
