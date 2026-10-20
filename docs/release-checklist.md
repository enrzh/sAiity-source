# Signed-app workflow verification

## Desktop usability cycle — local code/candidate verified; acceptance gates open

The accepted 10 October [desktop plan](superpowers/plans/2026-10-10-desktop-usability-performance-and-ui-polish.md)
is implemented locally, including native UI polish, observational microphone health,
content-free run diagnostics, optional memory-only recent recovery, explicit app
exceptions, named transcripts/search reveal and interaction-aware feedback.
Independent source and synthetic content-layout reviews are APPROVED.

Latest supported suite: **810 registered Swift tests / 82 suites passed**, 24
explicit opt-ins skipped. Python: **30 checks passed**. A separate native app-loop
proof passed **10 focus/idle/recording/draft checks**. The final hook-free signed
local **2.7.0-rc.3/225** candidate passed resource/framework/signature verification
and **32 native smoke checks**. It is not installed, notarized or published.
The prior RC2 bundle and all inherited dirty/untracked/recovery state remain
preserved. Logs, source/artifact hashes and precise limits are consolidated in
`build/desktop-polish-20261010/README.md` and `.superpowers/sdd/progress.md`.

Localized synthetic layouts cover en/de/fr/es/ja, compact/default/large named
readers, late segment reveal and 26 pt body/summary text. They do not establish
composited contrast, actual keyboard/menu traversal or human VoiceOver coverage;
native computer use failed with `Sky Computer Use native pipe closed before response`.
Natural recordings/independent semantic reviewers, quality-preserving native
timing/memory calibration, built-in/USB/Bluetooth qualification, permission/
insertion/sleep/long-session and upgrade workflows remain **OPEN**. The existing
thirty-minute recovery automation stays active while these accepted gates remain.

## Product language cycle — in progress

The accepted 9 October [product/language roadmap](superpowers/plans/2026-10-09-product-quality-and-language-coverage.md)
is implemented from the preserved PRR candidate; its new focused/full-suite,
build and artifact evidence must be recorded separately below when complete.
The previous PRR counts do not validate this newer source.

The reviewed local PQL candidate is now `2.7.0-rc.2/225`: 728 registered Swift
tests / 81 suites passed (20 model/device opt-ins skipped), 30 Python checks
passed, and the normal hook-free signed build, bundled-resource verification and
32 native smoke checks passed. German reader content and native sheet resizing
were checked at compact/default/large sizes. These remain local implementation
evidence. The candidate is not notarized or published. Exact logs, the preserved
previous bundle, source patch and layouts are in `build/product-language-20261010/`.

The language gate now starts with twelve explicitly **UNVERIFIED** natural-speech
cohorts: English, German, Japanese, Simplified/Traditional Chinese, French,
Spanish, Portuguese, Arabic, Russian, Hindi and Korean. Source recognition,
cleanup, translation targets, installation and measured quality are separate
claims. Pure capability/Unicode tests do not establish speech quality.

Reviewed fixtures specify NFC/grapheme normalization and language-appropriate
word scoring; legacy fixtures retain their old defaults. Translation alternatives
are independently reviewed complete references, not fragments to mix and match.
Semantic review must identify the exact produced output hash. Extra or unknown
language labels cannot disappear from the score. A missing corpus, independent
review or target-latency calibration prevents a release pass.

Before publication, run the current strict gate with authorized natural
recordings and reviewers, finish the device/workflow matrix, and record cold/warm
processing and memory on the reference Mac. There is no new recording, download,
permission, push, tag or publication authorization in this implementation task.

## PRR status and release gates

Current PRR integration is not a full release pass. The fresh supported release
suite passed 669 registered tests across 81 suites in 13.809 s, with 20 explicit
native-model/device opt-ins skipped. Python quality/evidence checks passed 15/6
tests. These are deterministic implementation evidence. Real natural-speech corpus quality, macOS 26/27
device trials, signed-app workflows and upgrade acceptance remain **NOT VERIFIED**.
Historical Mac mini measurements are not current MacBook evidence. Bind every
result to the tested revision/build, hardware, OS, toolchain and model assets.
Release readiness does not authorize publication: no push, Pages deployment,
release, tag or appcast update is part of this documentation task.

Translated-caption first/final/drain p50/p95 are now recorded separately from
source ASR. Their production hard-budget calibration remains **UNVERIFIED**;
the quality verifier refuses a complete pass until measured limits are supplied.
Model-cleanup cases require actual successful model calls for each configuration
and preview state; rules-only bypass does not count as model execution. Offline
evidence must include the successful post-run revision/fingerprint marker.

| Named PRR gate | Required observation / current acceptance status |
| --- | --- |
| PRR-STOP-ADMISSION | During native drain/stopping, Start, setup trial, dictation and other conflicting capture/model work cannot admit a new session; delayed callbacks cannot repaint or start capture. Runtime acceptance NOT VERIFIED. |
| PRR-CAPTURE-ROOT-STORAGE | With disposable roots, race queued writes, save, refresh, summary/retranslation and deletion against root changes; operations stay bound to their captured library/session and cannot publish into another root. A different bundle ID alone does not isolate the fixed transcript root. Runtime acceptance NOT VERIFIED. |
| PRR-HISTORY-TRANSLATION | Final translations patch their original committed rows, including rows outside the latest-50 display; target/session changes cannot relabel old translations. While reviewing history, updates do not scroll the reader; Jump to latest resumes follow. Runtime acceptance NOT VERIFIED. |
| PRR-SAVE-OVER-50 | Save a session with more than 50 committed lines and pending final translations; every committed line at the save action survives, the latest-50 display cap does not truncate storage, and the saved session opens. Check failure, clear/restart and session/root races without a false success. Runtime acceptance NOT VERIFIED. |
| PRR-DELETE-COUNTS | Force single and bulk deletion failures in disposable storage; report actual successful/failed counts, refresh from disk and never claim that failed deletion preserved or removed a transcript without checking. Runtime acceptance NOT VERIFIED. |
| PRR-DOWNLOAD-USE | Direct Download & Use enables only a successfully downloaded compatible still-selected cleanup model. Failure, cancellation, selecting Off or another model during download must not enable stale cleanup. Missing recognition/translation assets must remain visibly unavailable with repair actions. Runtime acceptance NOT VERIFIED. |
| PRR-PRESETS-LOCALIZATION-ACCESSIBILITY | Fresh and upgraded settings show truthful effective preset/readiness state, visible representative bubble previews and collapsed More options; check minimum/760/980-point widths, de/en/fr/es/ja, light/dark, VoiceOver, keyboard, Increased Contrast and Reduce Motion. Verify the actual system microphone prompt and localized usage explanation, including denial/recovery. Runtime acceptance NOT VERIFIED. |
| PRR-NATURAL-SPEECH-QUALITY | Authorized natural recordings with reviewed source and target references, provenance/licence or consent pass the expanded current policy with installed models and build-matched evidence. NOT VERIFIED. |
| PRR-DEVICE-UPGRADE | macOS 26 and 27 Bluetooth switching, sleep/wake, ordinary editable fields, focus changes, secure fields and previous-release upgrade preserve data and give truthful recovery. NOT VERIFIED; unavailable combinations must be recorded explicitly. |

## Expanded local quality policy

Use [quality-matrix.sh](../scripts/quality-matrix.sh),
[verify-quality.py](../scripts/verify-quality.py),
[benchmark_evidence.py](../scripts/benchmark_evidence.py) and the exact
[release-quality.json](benchmarks/release-quality.json) policy. The required
gate is one Nemotron 2240 ASR run, two untranslated Nemotron caption runs
(1120 and 2240), and two rules-cleanup dictation runs (1120 and 2240). This is
not every combination. Each requires five runs per fixture; dictation needs
both preview states. Missing required runs, a failed budget, translation
failures on a case that ran, dirty or changed source, and mismatched
fingerprints fail the gate.

The wider matrix stays in `futureTier` and does not block 2.7.0: the
12-language reviewed-provenance contract, Whisper base, model cleanup at both
chunk sizes, Hy-MT2, and MADLAD translation. `quality-matrix.sh` runs each of
those cases only when its installed weights and reviewed references exist,
then the same verifier gates it. Otherwise it logs
`SKIP (optional future tier): <case> — <reason>`. A skip of that tier does not
fail the release. See [the benchmark notes](benchmarks/README.md).

```sh
SAIITY_RELEASE_FIXTURES=/absolute/verified-fixtures \
SAIITY_RELEASE_QUALITY_OUT=/absolute/evidence/current-build \
scripts/quality-matrix.sh
```

These are instructions for the authorized validation owner, not commands run
by this documentation worker. To include the optional model-cleanup rows, also
set `SAIITY_DICTATION_BENCHMARK_CLEANUP_MODEL` to the basename of a nonempty
compatible `.gguf` already in `Models/qwen`. No default substitution or
preference read establishes that choice. Omitting it skips those rows. Corpus
audio and references stay outside Git. Reviewed natural-speech provenance and
`expectedTranslations` are required only for the future-tier cases that run.

The runner sets `SAIITY_ASR_BENCHMARK_DIR`, `SAIITY_CAPTION_BENCHMARK_DIR`,
`SAIITY_CAPTION_BENCHMARK_MODELS=nemotron`,
`SAIITY_CAPTION_BENCHMARK_RUNS=5`, `SAIITY_CAPTION_BENCHMARK_REALTIME=1`,
`SAIITY_CAPTION_BENCHMARK_WHISPER=0`, and per-case
`SAIITY_CAPTION_BENCHMARK_CHUNK_MS`, `SAIITY_CAPTION_BENCHMARK_TRANSLATION`,
`SAIITY_CAPTION_BENCHMARK_TARGET`, `SAIITY_DICTATION_BENCHMARK_CHUNK_MS`,
`SAIITY_DICTATION_BENCHMARK_CLEANUP`, `SAIITY_DICTATION_BENCHMARK_TRANSLATION`
and `SAIITY_DICTATION_BENCHMARK_TARGET`. Pipeline cases set
`SAIITY_DICTATION_PIPELINE_BENCHMARK=1`; the other phases keep it off.
It forces `SAIITY_BENCHMARK_INCLUDE_TEXT=0`,
`SAIITY_CAPTION_BENCHMARK_DOWNLOAD=0` and `SAIITY_CLEANUP_BENCHMARK_DOWNLOAD=0`.
`DEVELOPER_DIR` defaults to `/Applications/Xcode.app/Contents/Developer`.
The constituent [model-matrix.sh](../scripts/model-matrix.sh) and
[caption-matrix.sh](../scripts/caption-matrix.sh) remain the standalone entry points.

Translated cases require each fixture's
`expectedTranslations[target] = {"text": "reviewed target text", "reviewed": true}`.
Source `wer`, `cer`, `missingWords` and `languagePreserved` score independent
raw recognition, even with translation enabled. Target `translationWER`,
`translationMissingWords` and `targetLanguagePreserved` score translated output
against that separate reviewed reference; its UTF-8 SHA-256 is bound as
`translationReferenceSHA256`. Untranslated cleanup additionally checks
`outputWER`, `outputMissingWords` and `outputLanguagePreserved`. Review source
and target references independently; generated speech or recognizer-produced
references do not prove natural-speech quality. Exact configuration, source,
corpus/model checksums and matching hardware/toolchain must accompany records.
Acceptance ceilings remain targets, not measured product improvements.

## Signed-app and device observations

Use a build without test hooks (`./build-app.sh --no-test-hooks`) for local
checks and the notarized app from the actual release DMG for installation and
update checks. Record the source revision, bundle version/build, macOS version,
hardware, installed models and each outcome. A passing unit suite or `--selftest`
does not establish microphone accuracy, Accessibility paste, installation or
Sparkle updating.

| Workflow | Required observation |
| --- | --- |
| Fresh installation | DMG opens, Applications installation launches, setup offers one recognition download and explains required permissions |
| Permission denial/recovery | Trial explains Microphone or Screen Recording failure; returning from System Settings and retrying succeeds |
| Dictation | Hold/release the configured key; expected complete text lands in an editable field in TextEdit and another ordinary app |
| Focus change / secure field | Switching apps, documents or text fields during processing does not paste into the wrong field; unavailable field identity falls back to copy; a password field refuses insertion |
| Clipboard failure / retry | Failure does not send Paste or claim success; retained text remains selectable and Retry Copy copies it without pasting into a newly focused field |
| Original-text recovery | After cleanup, translation or dictionary correction, Copy Original copies the exact recognition text without pasting or replacing the displayed processed result; retry a failed copy; the menu action works after the bubble dismisses and resets on the next dictation |
| Personal dictionary | Existing names survive upgrade; add/remove a name and a correction on both pages; C++, .NET and non-Latin names keep punctuation; only whole approved phrases change, without cascading replacements |
| Cleanup / translation | Names, numbers and intended meaning survive cleanup; mixed languages remain mixed with translation off and become the target language when on |
| Cancellation | Close setup or cancel while preparing/recording/processing; no later microphone start, result, paste or stale bubble appears |
| Caption clear/restart | Clear the bubble during continuous speech and during a pause; new speech appears without restarting captioning |
| Caption history | Scroll up while speech continues and translations arrive; the visible row stays in place; Jump to latest and manually reaching the bottom resume following; check the 50-row history limit and clearing |
| Realtime power/load | On a laptop, enable/disable Low Power Mode during a session; repeat under sustained load; interim translations update less frequently, original captions continue, final translations complete, stale previews never overwrite them |
| Devices and sleep | Change input devices and sleep/wake; capture resumes or gives a recovery action rather than silently stalling |
| Appearance and displays | All presets work in light/dark, increased contrast and reduced motion; bubbles stay visible after disconnecting an external display |
| Keyboard and accessibility | Tab/Shift-Tab, Space, Escape, standard editing shortcuts and VoiceOver reach trial and settings controls |
| Upgrade | Sparkle installs the offered notarized version; models, shortcuts, style and saved transcripts survive |

At minimum verify macOS 26 and 27 on Apple Silicon, including the M4 MacBook Air
that previously reproduced crashes. Mark unavailable combinations **not tested**.
Keep recordings and transcripts outside Git; diagnostics should contain timings
and error summaries rather than conversation content.

For broader speech validation, provide an authorized natural-speech corpus with
reviewed reference transcripts and recorded provenance/license or consent.
Include accented German/English, other supported languages, quiet/fast speech,
proper names and numbers, within-sentence language switches, competing
noise/music, silence followed by speech, long continuous speech and two-person
turn taking/overlap. Speaker labels may identify turns; overlapping words cannot
be separated. Bluetooth switching and sleep/wake require actual device checks,
not merely a recording played through a model.

Reuse `scripts/caption-matrix.sh` and the `DictationASRPerformanceTests.completePipeline`
benchmark with these fixtures. Run both caption tiers and cleanup/translation
off/on with installed compatible engines, sequentially. Never download a model
silently or treat synthesized fixtures as evidence of natural-speech accuracy.
Record every unavailable combination as **not tested**, and keep device results
separate from mocked tests, local model measurements and release publication.

Automatic coverage: CI runs the release Swift tests, quality-gate self-checks,
builds without test hooks, verifies native resources/signatures and runs the
signed bundle's `--selftest`. That smoke test exercises bubble presets, caption
clear/new content, dictation waveform/result/reset and all setup trial layouts.
`scripts/release.sh` additionally requires current, clean-source real-model
quality reports and a successful GUI smoke test before creating the release tag.

For the preliminary short-dictation product gate, use
`scripts/quality-matrix.sh --product --help` and the separate contract in
`docs/benchmarks/product-qualification.md`. This harness hashes the measured
test code image and emits copied outcomes only; passing its synthetic checks
does not certify the shipping app or visible insertion. Preserve the old
twelve-cohort language gate. Missing natural recordings, independent semantic
review, physical/compositor observations or calibrated hardware evidence must
remain UNVERIFIED.

New optional Gemma 4 E2B/E4B, TranslateGemma 4B and commercial Granite TurboCTC
choices retain the existing defaults and need explicit downloads from Models.
Verify exact selected files, terms and availability, removal after native
quiescence, and missing/corrupt recovery. Granite is English-only with final
audio regions, no live partials, timestamps or audio language detection. Native
abort polls at run entry; Stop can require the active encoder to return before
resources are released. No quality or speed superiority follows from the
catalogue or adapter tests. Keep new weights and real-device qualification
separate from local implementation evidence.
