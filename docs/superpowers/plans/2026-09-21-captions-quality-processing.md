# Captions Detection, Transcription, and Processing Quality Plan

> Status: proposed. This document is a plan only; it does not authorize
> runtime edits, a commit, a push, or a release.

## Goal

Make live subtitles arrive earlier, break at better speech boundaries, contain
fewer recognition errors, and remain correct while translation, speaker labels,
and transcript persistence run around them.

The work is for the live captions/subtitle path. Dictation remains unchanged
unless a small pure audio or text utility can be reused without changing its
behavior.

## Current Baseline

The current pipeline is:

```text
ScreenCaptureKit
  -> SystemAudioCapture and format conversion
  -> adaptive RMS SpeechGapDetector
  -> StreamingASRBackend / Nemotron or Parakeet
  -> cumulative partial-text commit logic
  -> AppDelegate sentence assembly and speaker attribution
  -> translation, overlay, and TranscriptStore
```

Important current behavior:

- `SystemAudioCapture` distinguishes a healthy digital-silence stream from a
  stalled stream. Speech activity is still inferred mainly from RMS relative to
  a rolling noise floor.
- `SpeechGapDetector` uses a configurable silence hold, currently 750 ms by
  default. It is an endpoint detector, not a full voice activity detector.
- `StreamingASRBackend` keeps one FluidAudio `process()` in flight and feeds a
  cumulative transcript callback. It commits on punctuation, a 3.5-second
  rolling timer, or a character cap, then flushes the tail on a speech gap.
- Final timestamps are estimated from wall-clock time and text length because
  the current engine callback does not expose word timestamps.
- `AppDelegate` owns sentence assembly, display lifecycle, speaker boundaries,
  language inference, live translation, authoritative translation, and
  transcript persistence. It already protects translation with generation and
  latest-wins checks, but those state transitions are spread across the render
  path.
- `ASRAdaptivePolicy` now records caption and dictation measurements
  separately. It chooses only among already-installed tiers, so the next step
  should extend measurement before changing defaults or adding downloads.

## Principles

1. Measure the existing 2.5.2 behavior before changing thresholds, chunk sizes,
   model tiers, or language heuristics.
2. Keep ASR audio continuous by default. Detection should improve endpointing
   and metadata before it is allowed to gate or discard samples.
3. Keep the single FluidAudio operation invariant. Never run concurrent ASR or
   translation inference merely to reduce perceived latency.
4. Preserve the original recognized text as the authoritative caption record.
   Formatting and translation must not silently rewrite recognition.
5. Treat per-segment language and speaker metadata as facts with confidence,
   not as commands to normalize the whole session.
6. Improve defaults internally. Do not add another settings page or expose raw
   VAD thresholds unless measurements show a user-facing control is necessary.

## Phase 0: Reproducible Baseline

### Measurements

Add or reuse monotonic timing and local diagnostics for:

- capture start -> first audio frame;
- capture start -> first speech-activity onset;
- capture start -> first ASR process;
- capture start -> first volatile text;
- capture start -> first final caption;
- detected speech end -> final caption;
- final caption -> translated caption;
- audio processed, real-time factor, process batch size, and peak backlog;
- model preparation, model reloads, and whether the session was warm;
- dropped or skipped audio, if any;
- false boundary count, merged boundary count, and maximum open-caption age.

Do not record audio or transcript payloads in diagnostics. Store only timings,
counts, selected engine/tier, and redacted failure reasons.

### Fixtures

Create a local-only benchmark manifest outside Git with mono Float32 16 kHz
fixtures covering:

- clean German, English, French, Spanish, and Japanese;
- CJK speech with no spaces or Latin punctuation;
- German-English and English-Chinese code switching;
- speech with music, room noise, a call-like narrow band, and notification
  sounds;
- short utterances, long continuous speech, breaths, commas, and deliberate
  pauses;
- digital silence and a simulated stalled capture stream.

Each fixture should define expected text, speech regions, boundary times,
language spans, optional speaker spans, and an allowed WER/CER range.

Run at least five warm and five cold sessions per installed engine/tier before
changing a default. Keep before and after reports separate.

## Phase 1: Better Speech Activity and Endpointing

### 1. Add a pure activity detector

Prefer a small deterministic helper over a new model or dependency. It may use
the existing Accelerate path to calculate per-frame:

- log RMS energy;
- short-term energy change/spectral flux;
- speech-band versus full-band energy;
- optional zero-crossing or high-frequency ratio for click rejection.

Keep the current adaptive noise-floor detector as the floor signal. Add
hysteresis so onset and offset have different thresholds, a short minimum speech
run, and a hangover after speech ends. Start with tunable values around:

- 20-40 ms analysis frames;
- 120-200 ms pre-roll;
- 80-150 ms minimum speech onset;
- 300-500 ms post-roll/hangover;
- 600-900 ms end-of-speech hold, tuned from the fixture report.

These values are not defaults until the baseline supports them.

### 2. Do not confuse stream health with speech

Keep `audible`, `silent`, and `stalled` as separate capture states. A stream
that delivers digital zeros is healthy and should not be displayed as an error.
A stream that stops delivering buffers is an error and must not be treated as a
long pause.

Only flush a pending caption when the detector has observed speech followed by
an end boundary. A session that starts silent must not create empty caption
segments or repeatedly show a "nothing is playing" row.

### 3. Preserve all samples

Attach a monotonically increasing sample/frame sequence to capture batches and
keep the exact sample range used for each endpoint event. The detector may
produce metadata, but it must not drop audio from the ASR stream. If a future
quality experiment gates inference during non-speech, it must be benchmarked as
a separate opt-in experiment and report every skipped range.

### 4. Handle continuous background sound

Tune against music-bed and call-like fixtures rather than only digital silence.
Use relative energy and band changes to identify a speech pause above a stable
bed. Add a confidence/hysteresis requirement before closing a caption so one
click, consonant, or music transient cannot split a sentence.

If deterministic features cannot separate a voice from a soundtrack at the
required quality, record that limitation and evaluate one small local VAD model
as a measured follow-up. Do not add a second model speculatively.

## Phase 2: More Accurate Streaming Transcription

### 1. Reconcile cumulative ASR revisions explicitly

Extract the current prefix/volatile-tail logic from
`StreamingASRBackend` into a pure reconciler only if doing so reduces the
existing state complexity. It must handle:

- a cumulative transcript that grows normally;
- a model correction in the last one or two words;
- punctuation arriving after the words;
- a reset or shorter callback without duplicating the old prefix;
- Latin, CJK, and mixed-script spacing;
- empty and punctuation-only callbacks.

Keep the settled prefix immutable unless the engine explicitly revises the
recent volatile window. Never reset the entire committed prefix just because a
single cumulative callback differs.

### 2. Use endpoint evidence, not only character age

Introduce a pure endpoint policy that combines:

- speech-activity end events;
- punctuation and script-aware terminators;
- repeated identical partials or a stable recent token window;
- maximum volatile age and maximum caption length;
- speaker changes with confidence;
- cancellation and session generation.

Short captions should be allowed to finalize quickly. Continuous speech should
emit readable clauses without waiting 3.5 seconds, but clauses should still be
assembled into one display sentence and one translation unit when the speaker
has not finished.

Never cut inside a word. Never require a Latin space to detect a CJK boundary.
Keep the existing CJK and mixed-language behavior covered by pure tests.

### 3. Improve audio-to-text timing

Prefer sample-clock timestamps derived from the capture sequence and processed
sample count. Use engine timestamps if FluidAudio exposes them; otherwise use
the end of the processed audio window, not `Date` plus estimated characters.
Keep timestamp uncertainty explicit in exports rather than claiming precision
the engine does not provide.

### 4. Bound processing latency without violating single-flight

Measure the current drain-all behavior in `StreamingASRBackend`. If it causes
head-of-line blocking, process bounded audio windows while retaining one
in-flight `process()` call and ordered samples. Start with a window around
80-160 ms only if the selected engine can sustain it; otherwise retain native
model chunking.

When the backend cannot keep real time, do not silently pretend the captions
are current. Record the backlog, surface a recoverable status, and use the
already-installed adaptive tier policy. Do not auto-download a faster model or
run two model calls in parallel.

## Phase 3: Structured Caption Processing

### 1. Introduce a small segment value model

Keep ownership in `AppDelegate` unless tests show it cannot remain coherent.
If a value model is needed, use one immutable `CaptionSegment` carrying:

- stable segment ID and revision;
- sample/time start and end;
- original text and final/volatile state;
- language spans plus confidence and dominant-language metadata;
- optional speaker label and confidence;
- translation state and generation.

Use a pure reducer or transition helper for display and persistence decisions.
Do not create a service layer with one caller.

### 2. Make original text authoritative

The recognized original should be committed once to `TranscriptStore`. A later
translation or formatting result updates the same segment ID rather than
appending another row. A restarted or cancelled session must not duplicate the
last final chunk.

Keep live volatile text display-only. Translation should normally run on a
stable final segment or a deliberately coalesced latest revision, never once
for every partial callback.

### 3. Make language handling segment-aware

Use per-segment ASR language metadata when the engine provides it. Use text
language detection only as a bounded fallback with confidence and hysteresis.
The accumulated `LanguageDetector` result may describe the dominant session
language, but it must never overwrite a later segment's language.

For mixed segments, preserve each language span in the original. If translation
is enabled, translate only the necessary source spans or complete stable
segments using the requested target. Never pass the first session language as
the source language for all later text.

### 4. Keep cleanup conservative

Live captions should not wait for an LLM cleanup model. Apply only deterministic
caption-safe formatting by default: whitespace normalization, punctuation-only
filtering, script-aware joining, and removal of an obvious repeated boundary
token when the ASR reconciler proves it is a duplicate.

If a future optional refinement model is evaluated, it must be asynchronous,
generation-bound, locally validated, and able to fall back to the original
caption with no visible data loss. It must never translate, summarize, or turn
mixed language into one language.

### 5. Keep translation from blocking recognition

Retain the existing serial translator gate and latest-wins behavior. Improve it
by keying requests on `(session, segment, revision, target, engine)`, cancelling
superseded queued work, caching identical stable requests, and dropping stale
results before they reach the overlay or transcript store.

Translation timing must not affect first caption timing. A translation failure
must leave the original caption visible and record a redacted diagnostic.

## Phase 4: Adaptive Performance and Memory

- Keep model weights resident between caption sessions and reuse the prepared
  backend pool.
- Select only among installed Nemotron tiers. Prefer the fast tier only after
  its measured real-time factor, backlog, memory, and thermal cost meet the
  target on the current device.
- Keep Parakeet an explicit English-only choice. Never use it as a multilingual
  automatic fallback.
- Reuse capture and processing buffers. Avoid copying the complete audio session
  for a streaming caption path.
- Keep ASR, translation, diarization, and cleanup inference serialized at the
  boundaries where their models or engines are not concurrency-safe.
- Add signpost-style timing around capture, ASR, endpointing, translation, and
  persistence only if the existing diagnostics cannot answer the latency
  question. Do not add telemetry or a server path.

## Tests

Add mocked, weight-free tests for:

- activity onset/offset, hysteresis, pre-roll, hangover, minimum speech, and
  music-bed pauses;
- healthy digital silence versus stalled capture;
- sample/frame conservation and monotonic timestamps;
- cumulative ASR revisions, punctuation, CJK spacing, mixed-script joins, and
  duplicate-prefix prevention;
- endpoint policy for short speech, long speech, repeated partials, pauses,
  speaker changes, cancellation, and maximum volatile age;
- bounded streaming batches, one `process()` call in flight, cancellation,
  backlog accounting, and model reset ordering;
- first-text-before-translation ordering;
- segment IDs, translation generations, stale-result rejection, and one-time
  transcript persistence;
- language metadata that retains German -> English -> German and
  English -> Chinese -> English spans;
- translation-off preservation and intentional mixed-source translation;
- pure German, pure English, CJK, noisy speech, and code-switched fixtures.

Keep existing live-caption, dictation, translation, UI, and release tests
unchanged unless a shared pure utility genuinely replaces duplicated behavior.

## Acceptance Gates

Use the 2.5.2 build as the baseline and do not call the work complete until the
same fixtures produce an after report.

Initial targets, to be confirmed after measurement:

- warm first volatile caption: p50 <= 1.2 s, p95 <= 2.0 s;
- warm first final caption: p50 <= 2.0 s, p95 <= 3.0 s;
- end-of-speech finalization: p95 <= 1.0 s after confirmed speech end;
- steady-state real-time factor below 0.8 and peak backlog below 0.5 s;
- no unreported dropped audio ranges in a healthy session;
- no duplicate or missing final text around pauses, clears, resets, or speaker
  changes;
- WER/CER does not regress by more than 5 percent relative to 2.5.2 on pure
  language fixtures;
- code-switched language-span preservation >= 95 percent on the mixed fixtures;
- translation never changes first-text timing and stale translations never
  repaint a newer segment;
- no additional account, server, API, or uploaded audio.

## Manual Matrix

Run on the release device with warm and cold models:

1. Pure German with natural pauses and punctuation.
2. Pure English with continuous speech and no punctuation from the engine.
3. `Das ist ein test and now I'm speaking English.`
4. `Can you send mir bitte die Rechnung?`
5. `你好，this is an English sentence，然后我们继续。`
6. Speech over music and a call-like audio bed.
7. Digital silence before playback, during playback, and after playback.
8. Captions clear during volatile text, final text, pending translation, and a
   speech-gap flush.
9. Speaker labels off and on with alternating speakers.
10. Translation off, translation on with a warm model, and translation on
    while the translator is still preparing.
11. Stop/start, engine switch, cancellation, and a stalled stream.

## Files and Ownership

Likely existing files:

- `Sources/sAiity/SystemAudioCapture.swift`
- `Sources/sAiity/SpeechGapDetector.swift`
- `Sources/sAiity/SpeechGap.swift`
- `Sources/sAiity/StreamingASRBackend.swift`
- `Sources/sAiity/TranscriptionBackend.swift`
- `Sources/sAiity/NemotronBackend.swift`
- `Sources/sAiity/ASRAdaptivePolicy.swift`
- `Sources/sAiity/AppDelegate.swift`
- `Sources/sAiity/LanguageDetector.swift`
- `Sources/sAiity/Diagnostics.swift`
- `Sources/sAiity/TranscriptStore.swift`
- `Sources/sAiity/TranslationOutputValidator.swift`

Likely focused test files:

- `Tests/sAiityTests/StreamingASRBackendTests.swift`
- `Tests/sAiityTests/AudioBacklogTests.swift`
- `Tests/sAiityTests/SpeechGapDetectorTests.swift`
- `Tests/sAiityTests/CaptionHistoryTests.swift`
- `Tests/sAiityTests/CaptionLifecycleTests.swift`
- new pure detector/reconciler/endpoint tests only where existing suites do not
  already own the behavior.

## Verification

Run the repository-supported test command:

```sh
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcrun swift test -c release -Xswiftc -enable-testing \
  -Xswiftc -DSAIITY_TEST_HOOKS
```

Then run the normal application build, the benchmark matrix with real local
fixtures, `scripts/verify-release.sh`, and manual matrix above. Report cold and
warm before/after numbers separately. A build passing without the fixture and
manual gates is not enough to claim better captions.

## Non-Goals

- No redesign of the dictation pipeline.
- No language-switch button or language announcement requirement.
- No cloud inference, account, API, telemetry, or uploaded audio.
- No parallel FluidAudio or translation calls.
- No automatic download of another 600+ MB model.
- No LLM in the hot caption path unless a measured, validated experiment shows
  deterministic processing cannot meet the quality target.
- No new user-facing knobs until the benchmark demonstrates a real choice users
  need to make.

## Copy-Paste Execution Prompt

Implement `docs/superpowers/plans/2026-09-21-captions-quality-processing.md` in
the current sAiity repository. Preserve all dirty and untracked files, including
the existing captions recovery plan and `graphify-out/`. Do not start by
changing a threshold or model default. First build a local fixture manifest and
measure 2.5.2 cold/warm capture, first-text, first-final, endpoint, WER/CER,
language-span, translation, real-time-factor, backlog, and dropped-audio
metrics.

Improve the smallest owning boundaries in this order: deterministic speech
activity/endpoint metadata, cumulative ASR reconciliation and timestamping,
caption segment state, then translation/persistence generation checks. Keep the
ASR audio stream continuous, preserve one FluidAudio process in flight, reuse
resident model weights, and never let translation delay first recognition.
Only change chunk sizes, endpoint defaults, or adaptive model selection when
the before/after report supports the change on the same device. Add mocked pure
tests for all new transitions and run the repository-supported release test
command plus the normal app build.

Report files changed, baseline and after measurements, WER/CER and
code-switching results, first-text/final latency, RTF/backlog, translation
behavior, test results, manual matrix results, and known hardware limitations.
Do not create a commit, push, GitHub release, or DMG unless separately
authorized after the quality gates pass.
