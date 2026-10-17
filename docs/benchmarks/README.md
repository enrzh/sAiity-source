# Local ASR fixtures

## 10 October 2026 — local PQL implementation and text timing

The reviewed local source passed 728 registered Swift tests / 81 suites, with
20 explicit native-model/device probes skipped, 30 Python checks and 32 signed
native smoke checks. The hook-free `2.7.0-rc.2/225` candidate is local and not
notarized. This does not establish natural-speech quality or model latency.

The following same-input comparison used 50 warm repetitions of each public
canned text in a Swift interpreter on Apple M4 / 16 GB / macOS 27.0.1 (26A434).
It measures the shared text-span helper only, with no audio, ASR, cleanup,
translation weights or delivery. Values are **p95 milliseconds**, not release
budgets. The accepted cached sample ran after Swift tests finished; an earlier
sample that briefly overlapped a build is excluded.

| Text case | Prior heuristic | New policy, uncached hypotheses | New policy, bounded cache |
| --- | ---: | ---: | ---: |
| Japanese | 0.0118 | 0.1405 | 0.0304 |
| English/Japanese | 0.0224 | 0.9518 | 0.0918 |
| German/English | 0.0210 | 0.5321 | 0.0520 |
| Arabic/Latin identifier | 0.0067 | 0.3657 | 0.0717 |
| Longer German/English | 0.0758 | 0.9187 | 0.1122 |

Correct phrase/uncertainty checks add work compared with the old heuristic.
Caching removes repeated hypothesis processing while retaining those checks;
Japanese false script spans fell from six to one, and the mixed English/Japanese
case from eight to three. This is text-policy evidence, not measured audio
accuracy. The cache uses the existing bounded cache and lock, retains at most
256 snapshots, and excludes input keys above 16 KiB.

Logs and layout/build artifacts are in `build/product-language-20261010/`.
Model load/reload cost, cold/warm end-to-end processing, physical footprint,
target-caption timing calibration, natural corpus/reference quality and device
workflows remain **UNVERIFIED**. No decoding/segmentation thresholds or model
recommendations were changed on the strength of these microbenchmarks.

## 9 October 2026 — PQL7 multilingual evidence contract

The initial natural-speech cohorts are **UNVERIFIED**: `en`, `de`, `ja`,
`zh-Hans`, `zh-Hant`, `fr`, `es`, `pt`, `ar`, `ru`, `hi`, `ko`.
German/English-only reports cannot pass the checked-in expanded policy. No new
authorized recordings, independent native reviewers or native measurements are
supplied by this change. Passing synthetic Python/Swift contract tests is not a
speech-quality pass.

`languageEvidence.requiredCohorts` names the exact release subset; the policy's
existing models/configurations name the measured engine/settings/target subset.
An explicitly selected local policy via `SAIITY_RELEASE_POLICY` may require a
smaller reviewed subset, and the verifier prints its `verifiedCohorts` and
`qualityScope: bounded-release-subset` on each case. Such a pass certifies only
those cases. Every selected fixture is measured, all selected combinations and
both preview states remain required, and skipped/unsupported rows cannot pass.
Do not remove hard budgets to accommodate a subset.

The native harness retains its **1...12 WAVs per batch**, 60-second clip bound,
five warm release repetitions, installed-only models and unchanged accuracy,
latency, completion and source/model/hardware checks. One reviewed clip/speaker
per selected cohort is the bounded release minimum, not complete natural-speech
coverage. The separate `corpusGoal` remains 20 clips/three speakers per cohort:
12 clean, four difficult/noisy and four critical names/numbers/negation/repair or
continuous-speech cases. Build this larger corpus in separate authorized batches;
warm repetitions do not count as independent clips or speakers. Genuine within
utterance switches and each tested language's own/common target need separately
named fixtures/configurations; a German target does not certify untested pairs.

Each local fixture adds the following metadata (contract example only; these
values are not reviewed corpus evidence):

```json
{
  "cohort": "ja",
  "provenance": {
    "reviewed": true, "source": "local authorized collection",
    "license": "documented permitted use", "consent": "documented permission",
    "speechType": "natural", "speaker": "anonymous speaker ID", "reviewer": "curator ID"
  },
  "referenceReview": {"reviewed": true, "independent": true, "reviewer": "native listener ID"},
  "scoring": {"language": "ja", "wordUnit": "natural-language", "normalization": "nfc-grapheme-v1"}
}
```

The cohort must match an explicit `expectedLanguages` entry, retaining the
Chinese script distinction. Reference/scoring language comes from independent
review, never the recognizer's guess. `natural-language` means Foundation's
existing NaturalLanguage word tokenizer with that reviewed language; CER uses
NFC canonical graphemes and includes combining marks, independently of WER and
missing-word deletions. No stemming, transliteration, compatibility folding or
whitespace-only/scalar-as-word flattening is a reviewed word metric. Legacy
fixtures without scoring metadata keep the legacy word-tokenization contract;
they cannot satisfy the new multilingual policy. Unknown/extra nonadjacent
language labels fail exact ordered language evidence; adjacent duplicate tags
and regional labels remain normalized for base language identity only.

Every measured row for a multilingual gate must echo `scoring`, `cer`,
`scoredLanguages` and `outputSHA256`. Untranslated pipeline rows additionally
carry `outputCER` and `scoredOutputLanguages`. A separately supplied
`qualityReview` must name an independent reviewer, `reviewed: true`,
`independent: true`, the exact `outputSHA256`, and explicit true outcomes for
`meaning`, `names`, `numbers`, `negation`, `omissions`, `naturalness`. Numeric
scores do not manufacture that review. Missing review remains a gate, even when
all WER values are zero. Private outputs stay local; public evidence contains
hashes and review outcomes. The harness cannot certify meaning automatically.

Target references retain `text`/`reviewed` and may add at most eight distinct
nonempty `alternatives`; all alternatives require the independent target
reference review. Scoring uses one complete reference, chosen by lowest WER,
then CER; metrics must not take unrelated minima from different references.
The original `translationReferenceSHA256` continues to hash primary UTF-8 text.
`translationReferencesSHA256` hashes the newline-joined ordered SHA-256 hashes
of primary text and alternatives. The complete byte-exact manifest hash binds
all reference/review/scoring fields, so changed alternatives invalidate old
evidence. Target references under the multilingual policy also include
`referenceReview` and their own `scoring` using the exact target language;
rows echo it as `translationScoring` and retain independent translation CER.
Chinese script targets require `targetVariantPreserved` separately: base `zh`
identity alone cannot certify `zh-Hans` → `zh-Hant`. Ambiguous output remains
unverified.

Provenance/cohort preflight runs before native commands. The normal release
matrix will therefore fail until a reviewed corpus exists. Python unit tests
use clearly synthetic temporary bytes only to test rejection and binding;
they neither load installed weights nor establish measured quality.

## 7 October 2026 — transcript reading controls

On `339f295` plus the preserved local changes, session rows now keep the date,
line count and one secondary-action menu. Summarize, Summarize Again and Remove
Summary live in the reader, with local-model attribution and a warning that the
result can omit or invent details. Session-specific progress retains Cancel;
deletion of the active session is disabled. Removing a summary deletes only
`summary.json`, preserving spoken lines, metadata and exports.

The supported release suite passed **636 registered tests / 80 suites**, 12.887 s
(`/tmp/saiity-transcript-design-tests-verified.log`). Added checks cover summary-only
removal, refusing external/symlinked session directories and preserving a summary
while generation owns the busy state. The normal build without test hooks passed
signature/resource/version verification; its app passed **32 native smoke checks**
(`/tmp/saiity-transcript-design-build-final.log`,
`/tmp/saiity-transcript-design-smoke-final.log`).

Native previews cover English and German session rows and four reader states:
summary, missing model, progress and failure. All four sheets start at 640×680,
are natively resizable with a 560×480 minimum, and expand to 820×800. There are
26 captures under `/tmp/saiity-transcript-ui.bARORe/{en,de}-verified/`; the capture
runner uses a disposable library and a separate app preference domain. The
reader needs `.presentationSizing(.fitted)` on macOS 27; flexible content alone
left the sheet non-resizable. Async capture now awaits the library/view reads
instead of blocking their main-actor continuations with a nested run loop.
`cacheDisplay` omits some material/header compositing, so these are layout checks,
not verification of the primary button's fill or composited header appearance.
No Gemma is installed; the real summary-generation probe remains **not run**.

## 7 October 2026 — saved-summary lifecycle fixes

Local source is `339f295` plus the preserved settings/dictionary cleanup and
these fixes. Summaries now hold the shared saved-transcript busy state through
file reading, generation, cancellation drain and completion. Starting captions,
onboarding trials and model cleanup consult the same state. Retranslation refuses
to enter during a summary; multiple queued retranslations retain busy ownership
until the last run exits.

Summary progress is awaited on the main actor, so no queued update can arrive
after the completion callback clears the progress row. Cancellation retains the
task handle until native work unwinds. Input is decoded from one captured
`segments.jsonl` byte snapshot; changed or missing input is rejected before
publishing, preserving the previous summary. Atomic replacement, 0600 permissions,
whole-line chunking and spoken-only subtitle export retain their existing paths.

The supported release test command passed **634 registered tests / 80 suites**,
12.900 s. New checks exercise busy ownership, refusal of caption start/model
deletion/partial cleanup, cancellation while generation drains, late UI progress,
and changed input with/without an existing summary. Tests using the process-wide
library busy state are serialized together; existing assertions remain in place.
Log: `/tmp/saiity-summary-lifecycle-tests.log`.

The final build without test hooks passed signature/resource/version verification,
and the signed app passed **32 native smoke checks**. Logs:
`/tmp/saiity-summary-lifecycle-build.log` and
`/tmp/saiity-summary-lifecycle-smoke.log`. The unbundled test host initially opened
a Sparkle modal when exercising Start; updater startup now requires an actual app
bundle, preserving normal app behavior. No Gemma weights are installed here, so
the real Gemma summary probe remains **not run**. No models were downloaded and
no release was published for these local fixes.

## 4 October 2026 — shipped 2.6.4, then a local summary

Published 2.6.4 is `1ae1163`. The summary work is an uncommitted change on top
of that commit. No release is represented by these results. No model weights
were downloaded for this check. The only GGUF on this Mac is Hy-MT2; Gemma 3
is absent, so the opt-in summary probe (`SAIITY_SUMMARY_PROBE=1`) did not run.

Verification on this Mac mini M1 / 16 GB / macOS 27.0.1 (26A434) / Xcode 27.0
(27A266a):

- The release suite, built with the supported flags and then run with
  `--no-parallel --skip takeOwnsSamplesAgainstLateCallback`, passed
  **627 tests / 79 suites**, 17.070 s. Twenty of those are opt-in probes or
  benchmarks and were skipped, including the Gemma summary probe. Log:
  `/tmp/saiity-summary-release-tests-serial.log`.
- `DictationMicrophoneCaptureTests.takeOwnsSamplesAgainstLateCallback` was
  excluded. Twice, in a full run, `stop()` hung inside `AVAudioEngine.inputNode`
  after `beginForTesting()` had marked the capture running without starting the
  engine. That case is **not tested** here.
- A run that did not pass `--no-parallel` executed suites together. Three
  dictionary assertions then failed because they share
  `DictationVocabulary.corrections`. The same three passed in the serial run
  above. Log of the parallel failure:
  `/tmp/saiity-summary-release-tests-3.log`.

The summary tests cover chunking, a short fixed output budget, section
parsing, a stand-in generator that leaves `segments.jsonl` untouched, cancel
keeping an older summary, a multi-piece reduce, Markdown versus SRT, and
refusal when the cleanup model is missing or captions or dictation are busy.
Localization covered the new strings.

These rows were **not tested** on this machine: Copy Original in the signed
app, the shared dictionary in the GUI, caption scroll and Jump to latest,
dictation paste and focus, a notarized DMG upgrade, Low Power Mode on a
laptop, Bluetooth device changes, sleep/wake, the M4 MacBook Air crash
recheck, and a consented natural-speech corpus. Recordings and transcripts
were not added to Git.

## 3 October 2026 product follow-up

Working source is `9c8c91e` plus the existing realtime changes and this local
follow-up. No release is represented by these results. Original dictation can
be copied from the bubble or menu without pasting; the processed result remains
intact. The shared native dictionary editor keeps existing names, adds explicit
whole-phrase corrections, preserves technical punctuation, and never learns
replacements automatically. Corrected text reaches cleanup/translation while
the uncorrected recognition text stays recoverable in memory. Caption corrections
apply once to the assembled raw sentence, including cross-chunk phrases. When
wording changes, exports use the saved corrected text with the existing span
timing interpolation instead of the recognizer's old word text.

Caption history stops following when the reader scrolls upward, preserves the
visible row during updates, and resumes on Jump to latest, reaching the bottom
or clearing. Jump to latest is also reachable from the menu while reviewing
history. Interim translation pacing uses the normal 400 ms window, at least
1500 ms under Low Power Mode or thermal/memory pressure, and up to 2 seconds
after sustained slow native decoding. It keeps one in-flight decode and the
newest pending revision; final translations retain their existing priority.

Verification on this Mac mini M1 / 16 GB / macOS 27.0 / Xcode 27.0:

- The supported release command passed **619 registered tests / 77 suites**,
  18.678 s, after the final source changes. Log:
  `/tmp/saiity-product-improvements-tests-final.log`. New mocked checks cover
  recovery, correction boundaries/non-cascading replacements, mixed metadata,
  processing order, corrected caption export across chunk boundaries,
  reader-controlled scrolling and adaptive pacing/recovery.
- **11 Python checks passed** across release-quality and evidence validation.
  Logs: `/tmp/saiity-product-quality-checks.log` and
  `/tmp/saiity-product-evidence-checks.log`.
- The final `./build-app.sh --no-test-hooks` passed native-resource, version and
  signature verification. Its `--selftest 20` passed **32 native checks**,
  including Copy Original actions across all four bubble presets. Logs:
  `/tmp/saiity-product-improvements-build.log` and
  `/tmp/saiity-product-improvements-smoke.log`. The app is at `build/Syllivra.app`.
- Resident Hy-MT2 processed 80 revisable updates per cohort, three paired runs.
  Simulated constrained mode reduced native calls from **8 to 4** every run.
  Median accumulated decode time was **5.247 → 2.393 s**; final translation after
  draining previews was **0.552 → 0.552 s**. This measures local inference work,
  not battery energy or actual Low Power Mode on a laptop. Models stayed resident
  and all calls were sequential. Log: `/tmp/saiity-product-adaptive-native.log`.
- The production dictation controller, rules cleanup and in-memory clipboard
  processed all five existing fixtures, five times with each preview state:
  **50 native runs passed**. Pooled release-to-copy p50 / p95 was **0.352 / 0.417 s**
  with preview off and **0.439 / 0.680 s** with preview on. Worst WER was **0.0455**,
  missing words **0**, and expected languages survived every run. Five observations
  per fixture and pooled percentiles do not establish a population tail. This
  benchmark does not exercise a real microphone or focused-field paste. Log:
  `/tmp/saiity-product-pipeline-native.log`.
- The existing capture harness rendered the dictionary in German at 480 and
  640 points with sample names and an explicit correction. Entry/field layouts
  were inspected at `/tmp/saiity-product-ui.rd3iIN/captures/`; the temporary QA
  app was stopped and its preferences domain removed. `cacheDisplay` cannot establish
  native material/button appearance. Direct UI automation failed with
  `Sky Computer Use native pipe closed before response`; do not treat the
  component captures as a complete keyboard/mouse or appearance trial.

The corpus manifest has references/categories but no recorded provenance or
license/consent review. Broader natural-speech accuracy, accents, quiet/overlapping
voices, Bluetooth transitions, sleep/wake and the M4 MacBook Air therefore remain
**not verified**. The expanded cases and required observations are in
`docs/release-checklist.md`. Keep these outstanding gates separate from local
functional checks and model measurements. No weights or recordings were fetched.

## Realtime subtitle verification

The captions page exposes the existing 1120 ms Nemotron tier as **Realtime** and
2240 ms as **Balanced**, with an explicit download control for a missing tier.
The model stays resident and recognition still uses its one processing pump.
Qwen continues to emit pause-final captions. Selecting a subtitle timing uses
the existing caption preference and engine-change lifecycle; existing automatic
tier selection and persisted choices are retained.

**Translation timing → Realtime** now receives volatile words as well as
committed clauses. A 400 ms fixed coalescing window avoids starvation during
continuous speech; it retains one active translation and one newest request.
Each request carries sentence/session/translator identity and target language.
Hidden bubbles, closed/cleared sentences, changed targets/models and stopped
sessions reject stale previews. Cancellation drains native inference before the
next preview can enter, and does not count as a translator failure. Final
sentence translations take priority over previews and remain the only
translations written to the transcript.

Normal verification uses mocked requests and checks coalescing, one in-flight
decode, bounded pending revisions, cancelled work draining, session replacement
and stale target/sentence output. These functional tests have a suite timeout;
their wall time in the full UI suite is not a latency benchmark.

To measure the coalescing window plus resident native translation separately,
use the installed Hy-MT2 model:

```sh
SAIITY_REALTIME_TRANSLATION_BENCHMARK=1 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS \
  --filter CaptionLiveTranslationTests.installedPreviewLatency
```

This measures three text fixtures, including German/English and Chinese/English
switches, three times each without reloading the model or downloading weights.
It reports time to a translated preview and verifies a meaning-bearing target
term, without logging the output text. It does not include ASR delay, system
audio capture or display compositing. Use paced `CaptionASRPerformanceTests`
with each tier for first-recognition-text latency and dropped-audio metrics.

Local results, 3 October 2026, baseline `9c8c91e` on `main`, Mac mini M1 / 16 GB,
macOS 27.0, Xcode 27.0. Five existing fixtures (German, English, mixed speech,
noise and technical wording) were paced in real time, three repetitions each.
Nemotron and translation benchmarks ran sequentially; no weights were fetched.

| Cohort | First interim text p50 | Recognition RTF p50 | Process footprint p50 | Worst WER | Dropped audio |
| --- | --- | --- | --- | --- | --- |
| Balanced before | 2.425 s | 0.046 | 76.4 MiB | 0.091 | 0 s |
| Balanced after | 2.432 s | 0.045 | 65.2 MiB | 0.091 | 0 s |
| Realtime after | 1.586 s | 0.258 | 1365.3 MiB | 0.091 | 0 s |

Realtime reached first text about 35% sooner in this fixture set, with materially
more compute and process memory. These are observed model-tier tradeoffs, not
an algorithmic improvement to Nemotron and not a general subsecond promise.
Process footprint excludes memory held by system services; do not treat it as
total model memory. Balanced remains available and existing defaults are retained.
Logs: `/tmp/saiity-realtime-before-2240.log`,
`/tmp/saiity-realtime-after-2240.log`, `/tmp/saiity-realtime-after-1120.log`.

Resident Hy-MT2 passed nine translated-preview runs: English, German/English,
and Chinese/English requests, three runs each. A preview had to change the
input and preserve the meaning-bearing target word. Coalescing plus translation
took 1.114–1.206 s, median 1.154 s; this is additional to ASR latency.
Log: `/tmp/saiity-realtime-native-preview-final.log`. Very short mixed-language
spans remain subject to the existing language detector's ambiguity; these
fixtures do not prove arbitrary language-switch accuracy.

The supported release test command passed **610 registered tests / 77 suites**,
18.478 s. Mocked realtime tests ran normally; native measurements are opt-in.
Log: `/tmp/saiity-realtime-tests-verified.log`. Earlier verification caught an
overly short polling deadline in a new test when unrelated UI work occupied the
main actor; the new suite now uses the test framework timeout. No unrelated
test was skipped or changed. Three warm observations per clip establish local
behavior, not a reliable production-tail estimate or M4/macOS 26 validation.

The normal signed application build without test hooks passed native-resource,
version, signature and release-mode checks. Its `--selftest 20` completed all
28 native checks. Logs: `/tmp/saiity-realtime-build.log` and
`/tmp/saiity-realtime-smoke.log`. The existing capture harness rendered the new
German Quick controls in an isolated QA app at
`/tmp/saiity-realtime-ui.vSoK3c/captures/settings-captions.png`; the temporary
preferences domain was removed afterward. The settings pane remains scrollable
at the supported compact size. No GitHub release, model download or publication
was performed for this feature implementation.

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

Release-quality logs now also carry a `SAIITY_BENCHMARK_EVIDENCE` JSON header.
It records SHA-256 of each WAV, the reference manifest, and the complete files
of each loaded model, plus hardware, macOS build, Xcode toolchain and benchmark
settings. Hashes are streamed in 1 MiB blocks; reference/transcript contents are
not included. Model filenames and bytes both contribute to the tree digest.
`scripts/benchmark_evidence.py` can also fingerprint an existing local corpus
for a standalone ASR/caption/pipeline report:

```sh
python3 scripts/benchmark_evidence.py /absolute/verified-fixtures --profile asr
```

The release runner compares fingerprints before and after each harness. The
verifier rejects missing fingerprints, changed reference/audio bytes, different
hardware/toolchains, incompatible settings or conflicting model hashes across
reports. Summaries retain the complete evidence header. Hashing runs outside
inference timings and may warm the OS file cache; a cold preparation measurement
still means fresh model state, not guaranteed cold storage. Old reports without
these fingerprints remain historical evidence and cannot pass the new gate.

## 2 October 2026 project verification

### Follow-up: insertion, setup preferences and benchmark identity

At baseline `625c2e0` on `main`, clipboard write failures now return a distinct
outcome, skip synthetic Paste and leave the complete result in a persistent,
selectable bubble. Its native action changes to localized **Retry Copy**;
retry copies the retained output only. The same outcome reaches the controller's
existing recovery state, so failure cannot be reported as a successful copy.

The press-time focus token now retains the macOS accessibility field handle.
Automatic insertion requires the same app and field at completion, with a
second check after copying and before sending Paste. Missing/changed field
identity falls back to copy. Apps that recreate editor accessibility elements
may therefore require manual paste. Apps that reuse a single field identity
when changing documents may not expose that document change to this guard;
the real-app checklist remains necessary. No destination contents or field
handles are written to diagnostics.

Caption first-text, first-final and visible-lag diagnostics now report cold as
the inverse of the prepared-model state. Reopening setup reads the persisted
automatic-update preference rather than defaulting an existing opt-in to off.
Benchmark reports fingerprint recordings, reference manifests and model bytes,
record hardware/macOS/Xcode/Swift/SDK/settings, and reject inconsistent inputs.

Verification on macOS 27.0, Mac mini M1, 16 GB, Xcode 27.0:

- **604 Swift tests / 76 suites passed**, 17.786 s, using the supported release
  test command. Log: `/tmp/saiity-next-improvements-tests-verified.log`.
- **11 Python checks passed**: quality-gate validation and streamed hashes,
  including mutated audio/reference/model files, conflicting device/model
  reports and missing inputs. Shell syntax, workflow YAML and `git diff --check`
  also passed.
- The existing five-recording local corpus and resident Nemotron/Whisper models
  produced identical fingerprints on repeated reads. Logs:
  `/tmp/saiity-next-real-evidence.json` and
  `/tmp/saiity-next-real-evidence-repeat.json`. This checks fingerprint stability,
  not speech accuracy or inference performance.
- `./build-app.sh --no-test-hooks` passed bundle/native-resource/signature
  verification. Log: `/tmp/saiity-next-improvements-build.log`.
- The signed app's `--selftest 20` completed **28 native checks**, including
  Retry Copy actions across all four bubble presets.
  Log: `/tmp/saiity-next-improvements-smoke.log`.

The normal Swift test host initially exited without a final summary after
native button animation in the added recovery test. That test now invokes the
same production action handler and captures accessibility announcements through
the existing test hook; native button activation remains checked in the actual
signed application. No existing tests were skipped or weakened. Actual
Accessibility insertion into third-party documents and clipboard-service failure
are represented by mocks in this run; device/manual checks remain distinct.

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

## Preliminary product collection (14 October 2026)

`scripts/quality-matrix.sh --product --help` describes the separate pipeline
collector. The original invocation retains the twelve-cohort release matrix.
Product collection requires an actually clean matching revision, an explicitly
approved natural-speech corpus, independent reference reviews and already
installed weights. It never downloads models. Run disposable work through
`/Users/enrico/.codex/bin/codex-task`; the script does so automatically when
called outside that wrapper.

Supply `SAIITY_RELEASE_FIXTURES`, `SAIITY_PRODUCT_VERSION`,
`SAIITY_PRODUCT_BUILD`, `SAIITY_PRODUCT_MACHINE_ID`, `SAIITY_PRODUCT_POWER_MODE`,
`SAIITY_PRODUCT_THERMAL_STATE` and `SAIITY_PRODUCT_MEMORY_PRESSURE` explicitly.
The script resolves the actual compiled test code image, fingerprints it and
the corpus/models before and after measurement, and binds the existing
SOURCE/EVIDENCE/COMPLETE markers. Version/build label this test image; its hash
does not certify a separately packaged or installed app. Conditions are operator
observations, not inferred hardware claims.

`SAIITY_DICTATION_BENCHMARK_RUNS` accepts 1–50 in explicit product mode; legacy
pipeline defaults remain five. Cleanup/translation/tier use the existing
benchmark variables. Both product preview states receive paced, growing PCM;
scoring runs after an immutable actual delivery completion time. Native rows
bind the UUID and exact successfully copied payload hash, including separators,
plus accumulated measured capture/load/queue/recognition/cleanup/translation/
delivery/drain durations. Recognized ranges are checked against accepted input.
Native completion is distinct from physical input cessation and compositor
disappearance.

`SAIITY_PRODUCT_LIFECYCLE=warm` is the default. `post-eviction` waits for the
pool's actual native release acknowledgement before each run. `cold-start`
requires a fresh process, `SAIITY_DICTATION_BENCHMARK_RUNS=1`, one explicit
`SAIITY_PRODUCT_FIXTURE` and `SAIITY_PRODUCT_PREVIEW=0` or `1`. Repeating a loop
or manually invalidating a warm pool never establishes a cold start.

The memory pasteboard keeps this harness **copied only**. It does not touch
another app's focused field and cannot qualify visible insertion. Missing
`SAIITY_PRODUCT_OBSERVATIONS` returns nonzero with UNVERIFIED after retaining
the completed batch. When supplied, that file goes to the existing product
verifier; it must contain genuine independent observations and output/header-
bound semantic reviews. See `product-qualification.md` for the frozen contract.
No approved recordings, new model weights or production observations were
collected during implementation. Natural-speech quality, competitive latency,
physical shortcuts, device capture and visible insertion remain unqualified.
