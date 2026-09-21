# Captions Latency and Clear-Bubble Recovery Plan

> Status: proposed. This plan does not authorize a release, upload, or push.

## Goal

Make live captions feel responsive on a warm session, reduce cold-start delay
where the measurements justify it, and fix the caption-bubble clear action so
new speech becomes visible again immediately.

The phrase "Clean Captions bubble" is interpreted as the bubble's `xmark.circle`
clear action. If it refers to a different control, reproduce that control
before applying the lifecycle fix.

## Current Findings

- `AppDelegate.start()` moves through `.starting`, ASR preparation, backend
  start, ScreenCaptureKit capture start, and translator preparation. The ASR
  backend can already process while the translator is being prepared, but the
  visible `listening...` update is currently emitted after that await.
- `NemotronEngine` uses a 2240 ms balanced tier by default. The 1120 ms tier is
  available and should lower recognition delay, but it is a separate download
  and costs roughly twice the encoder work per second. `Parakeet EOU` is faster
  still but English-only.
- `StreamingASRBackend` correctly enforces one in-flight engine operation and
  wakes the pump as audio arrives. It currently drains all pending audio into
  each process call, so batching must be changed only after backlog and real-
  time-factor measurements prove it is the bottleneck.
- First-text and first-final timings already exist in `AppDelegate.render()`;
  backend real-time factor and peak backlog are logged when the session stops.
  Diagnostics also records model preparation timings.
- `clearCaption()` sets `clearedSentenceID` and clears the visible history, but
  leaves `sentenceParts`, `lastVolatileText`, the display sentence ID, and the
  recognizer's cumulative state untouched. `render()` suppresses all chunks for
  that ID until a punctuation or speech-gap close advances it. This explains a
  bubble that stays empty after clearing during an open utterance.
- `OverlayWindow.clearHistory(keepVisible: true)` already keeps the window
  visible. The bug is therefore in caption/display state ownership, not in the
  window's clear presentation path.

## Definition of Done

Measure before changing defaults. Record p50/p95 for cold and warm sessions,
with Nemotron balanced, Nemotron fast, and Parakeet where applicable:

- start request -> backend ready
- start request -> capture running
- capture running -> first volatile text
- capture running -> first final text
- clear action -> first new visible text
- backend real-time factor and peak backlog

Initial targets, to be confirmed or adjusted after the baseline:

- warm Nemotron fast first text: <= 1.5 s
- warm Nemotron balanced first text: <= 2.5 s
- steady-state real-time factor: < 0.8
- steady-state peak backlog: < 0.5 s
- clear-to-new-visible-text: <= 250 ms after the backend emits new text
- no dropped, duplicated, or reordered caption text around a clear action

The app must remain local-only. No parallel FluidAudio calls, server fallback,
automatic microphone activation, or forced 640 MB fast-tier download.

## Architecture Decisions

1. Keep the existing `ASRBackendPool` lease and
   `StreamingASRBackend` single-process invariant.
2. Separate "clear what is displayed" from "stop/reset recognition". Clearing
   a bubble must never start a stopped session or request a new permission.
3. On clear during an open sentence, preserve the sentence for the transcript,
   translation, and ordering, but establish a new display baseline so the next
   ASR update is visible. A late translation for the cleared sentence must not
   repaint the bubble.
4. Show the listening state as soon as capture is running. Translator warm-up
   can continue in the background or behind an explicit status without hiding a
   caption that arrived first.
5. Prefer an already-installed faster tier. Do not silently download a second
   model or select an English-only engine for multilingual users.

## Implementation Tasks

### 1. Add a reproducible latency baseline

Files:

- `Sources/sAiity/AppDelegate.swift`
- `Sources/sAiity/StreamingASRBackend.swift`
- `Sources/sAiity/Diagnostics.swift`
- `Tests/sAiityTests/StreamingASRBackendTests.swift`

- [ ] Add monotonic timestamps for start request, ASR prepared, backend started,
      capture running, first process, first volatile, and first final.
- [ ] Keep logs redacted and local. Record engine, tier, translation enabled,
      speaker labels enabled, cold/warm state, RTF, and peak backlog.
- [ ] Add a clear-to-next-render timing field without recording audio or text.
- [ ] Add test hooks for a fake engine so timing and event ordering can be
      tested without model weights.
- [ ] Run at least five cold and five warm sessions per installed engine/tier;
      save the before table in `docs/benchmarks/`.

### 2. Fix clear-bubble state ownership

Files:

- `Sources/sAiity/AppDelegate.swift`
- `Sources/sAiity/OverlayWindow.swift`
- `Tests/sAiityTests/CaptionHistoryTests.swift`
- new focused `Tests/sAiityTests/CaptionLifecycleTests.swift`

- [ ] Add a small pure display-state transition/value helper, or keep the
      transition in `AppDelegate` if that is shorter. Do not introduce a new
      service or pipeline.
- [ ] Define behavior for clear while the current sentence is volatile, final,
      translated, or empty.
- [ ] On clear, keep backend/session state authoritative, clear the visible
      history, invalidate the visible translation for the cleared sentence, and
      make the first subsequent ASR update start a fresh display row.
- [ ] Ensure the prior in-progress text is still emitted once to the transcript
      and is never duplicated when the next cumulative ASR update arrives.
- [ ] Keep `clearHistory(keepVisible: true)` unchanged unless a test proves the
      AppKit window itself is being ordered out.
- [ ] If the actual reproduction is a stopped/stalled session rather than a
      blank bubble, fix that explicit state transition separately and display an
      actionable restart status. Do not make the clear button auto-start audio.

### 3. Remove avoidable perceived startup delay

Files:

- `Sources/sAiity/AppDelegate.swift`
- `Sources/sAiity/SystemAudioCapture.swift`
- `Sources/sAiity/ASRBackendPool.swift`

- [ ] Publish `Listening` and keep the bubble visible immediately after capture
      starts, before translator preparation finishes.
- [ ] Guard the post-preparation status update so it cannot overwrite a caption
      already rendered by the ASR callback.
- [ ] Preserve the existing five-minute warm ASR cache and verify that a warm
      start does not reload model weights.
- [ ] Measure `SCShareableContent` and capture startup separately. Only cache or
      prefetch shareable content if it is a measured cold-start bottleneck and
      the cache can be invalidated safely when running apps/displays change.
- [ ] Keep translator preparation single-flight and independent from ASR; it
      must never block first caption rendering.

### 4. Evaluate the faster recognition path

Files:

- `Sources/sAiity/NemotronBackend.swift`
- `Sources/sAiity/ASREngine.swift`
- `Sources/sAiity/SettingsWindow.swift`
- `Sources/sAiity/SettingsPages.swift`

- [ ] Compare Nemotron 2240 ms and 1120 ms using the same audio and device.
- [ ] If the fast tier meets the targets without an unacceptable RTF/backlog or
      thermal impact, make it the recommended caption tier for new users only
      when it is already installed. Keep existing explicit selections stable.
- [ ] Do not auto-download the fast tier. Make the download cost and battery
      tradeoff visible beside the choice.
- [ ] Keep Parakeet as an explicit English-only speed option; never use it as an
      automatic fallback for multilingual captions.
- [ ] Do not change `StreamingASRBackend` batch size until the baseline proves
      that the current drain-all behavior increases latency. If it does, use a
      bounded batch while preserving one in-flight processing and sample order.

### 5. Verify translation, speaker labels, and silence interactions

Files:

- `Sources/sAiity/AppDelegate.swift`
- `Sources/sAiity/SystemAudioCapture.swift`
- `Sources/sAiity/SpeakerDiarizationSession.swift`
- `Tests/sAiityTests/SpeechGapDetectorTests.swift`
- `Tests/sAiityTests/StreamingASRBackendTests.swift`

- [ ] Measure captions with translation off, translation on, and translator
      cold/warm. Translation latency must not change first-text timing.
- [ ] Measure speaker labels off/on. If diarization consumes enough budget to
      affect RTF, keep it optional and surface the tradeoff rather than silently
      dropping caption audio.
- [ ] Confirm silence flush still closes the sentence once, and a clear during
      the 350 ms/80 ms speech-gap flush cannot resurrect stale text.
- [ ] Confirm a stalled capture stream remains distinguishable from digital
      silence and does not silently claim that captions are running.

### 6. Test matrix and acceptance

- [ ] Pure unit tests for clear transitions: volatile text, final text, pending
      translation, empty bubble, clear twice, clear then immediate speech, and
      clear during a speech gap.
- [ ] Regression tests for window visibility after `clearHistory(keepVisible:
      true)` and for no duplicate transcript entries.
- [ ] Fake-engine tests for first-text ordering, cancellation, bounded backlog,
      and the one-process-in-flight invariant.
- [ ] Manual matrix: cold/warm Nemotron balanced, Nemotron fast, Parakeet
      English, translation off/on, speaker labels off/on, digital silence,
      clear during speech, clear after a final, and clear while translation is
      pending.
- [ ] Run the repository release test command:

      `DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS`

- [ ] Run the normal release build, then repeat the latency matrix on the built
      app. Compare the before/after table instead of relying on subjective feel.
- [ ] Only after the clear/resume behavior and latency targets pass should a
      release plan be created. This plan itself does not create a release.

## Non-Goals

- No live-caption redesign or language-switch button.
- No server, API, cloud inference, or telemetry.
- No concurrent ASR/FluidAudio inference.
- No automatic microphone permission or automatic restart of a stopped session
  from the clear button.
- No forced model download and no broad rewrite of the working overlay system.

## Copy-Paste Execution Prompt

Implement `docs/superpowers/plans/2026-09-21-captions-latency-clear-recovery.md` in
the current sAiity repository. Preserve all dirty and untracked files. Start by
measuring cold/warm first-text, first-final, backend RTF, peak backlog, and
clear-to-next-visible-text using the existing timing/logging paths. Interpret
"Clean Captions bubble" as the caption bubble clear button unless a different
control is reproduced.

Fix the smallest owning state transition: clearing must keep recognition and
the overlay alive, preserve transcript/translation ordering, prevent stale
translation repaint, and make the next ASR update visible without requiring a
manual caption restart. If the actual failure is a stopped or stalled session,
fix that transition explicitly and do not auto-start audio from Clear.

Then move the listening UI before translator warm-up, benchmark Nemotron 2240
ms versus 1120 ms and Parakeet where installed, and change defaults only when
the measured target and battery/RTF tradeoff support it. Preserve the
single-flight ASR invariant and do not add parallel model calls.

Add focused mocked tests for clear transitions, visibility, stale translations,
first-text ordering, cancellation, and backlog behavior. Run the repository
supported release test command and the normal app build. Report before/after
latency measurements, files changed, test results, and any hardware-specific
limitations. Do not create a release until separately authorized.
