# sAiity product release readiness implementation plan

**Reviewed:** 9 October 2026, repository `/Users/enrico/Documents/GitHub/saiity`, clean `main` at `44f8a6f` (2.6.6 build 2 documentation).

**Goal:** Make the existing local captions and dictation product reliable, quick to start, quick to finish, and understandable without knowing model names.

**Approach:** Repair concrete lifecycle and data problems first. Measure the full processing paths before changing models or memory policy. Simplify the current screens using the components already present; each stage must leave a working product and its own verification evidence.

**Stack:** SwiftUI/AppKit, ScreenCaptureKit/AVFoundation, CoreML/FluidAudio and WhisperKit for recognition, MLX/GGUF for local text processing, Swift Testing and the existing Python/shell release checks.

The user authorized implementation on 9 October 2026 and requested GitHub release readiness. Work on codex/product-release-ready in the current repository. Prepare and verify the code and local release artifacts; do not publish a GitHub release or appcast without a release request. Preserve existing changes, models, transcripts and recovery metadata. Workers use sub2api/gpt-6.1-sol. Do not download model weights or capture new speech without the corresponding authorization.

## Product direction

The useful promise is: **speak or play speech, get dependable text on this Mac, recover the original whenever processing changes it.**

Keep the local-only design, no account/API requirement, original-text recovery, explicit translation, on-demand summary, native window chrome and five current navigation destinations. Captions, Dictation and Transcripts already have enough capabilities for a substantial product.

The recommended approach is a focused reliability/performance cycle, followed by UI simplification. A visual redesign alone would leave the failures below. Adding models, cloud services or a Windows port now would widen the combinations requiring verification.

Use existing types and files. Do not introduce new Manager/Service/Coordinator/Protocol layers, split files just because they are long, or rebuild the shared components. VocabularyEditor, TranslationSettingsRows, TranslationTargetPicker, SheetShell, SettingsSection, AssetControl, FrameStore and LocalGeneration are already reusable.

## What the inspection established

The review mapped setup, model selection/downloads, system and microphone capture, streaming and authoritative dictation transcription, sentence assembly, mixed-language cleanup/translation, bubble history, text delivery, saved sessions, summaries, retention, diagnostics, build/release scripts and relevant tests. The supported workload is one Apple Silicon Mac, short dictations and long caption sessions.

| Finding | Classification | Evidence |
| --- | --- | --- |
| Final translations two or more sentences late do not reach their retained bubble row, although the session receives them | Confirmed caller-level defect | [AppDelegate.swift](/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/AppDelegate.swift:3395); [OverlayWindow.swift](/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/OverlayWindow.swift:1291) |
| Stopping clears the shared caption busy flag before teardown finishes; Start and library work become available too early | Confirmed state/admission defect; simultaneous native inference was not demonstrated | [AppDelegate.swift](/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/AppDelegate.swift:1187); [SettingsPages.swift](/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/SettingsPages.swift:963) |
| Retranslation replaces its initial file snapshot without checking for later appends/translation patches | File-consistency risk with an actual late-write path | [Retranslate.swift](/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/Retranslate.swift:154); [AppDelegate.swift](/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/AppDelegate.swift:3449) |
| Periodic retention does not consult saved-transcript busy state | Confirmed deletion/admission gap | [SegmentCache.swift](/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/SegmentCache.swift:156) |
| Deletion errors are swallowed and retention counts candidates as successfully deleted | Confirmed error-reporting defect | [TranscriptStore.swift](/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/TranscriptStore.swift:480) |
| Choosing an absent cleanup model turns cleanup off; completing its download does not restore the intended selection | Confirmed setup-flow defect | [SettingsPages.swift](/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/SettingsPages.swift:301); [SettingsWindow.swift](/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/SettingsWindow.swift:625) |
| Dictation can say Ready without checking its recognition model or microphone denial | Confirmed readiness mismatch | [SettingsPages.swift](/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/SettingsPages.swift:2162) |
| The system microphone purpose string describes only caption microphone inclusion, although dictation also requests access | Confirmed permission-copy mismatch | [Info.plist](/Users/enrico/Documents/GitHub/saiity/Resources/Info.plist:51) |
| Cleaned text that was only copied can be described as inserted when translation fails | Confirmed delivery-status defect | [DictationController.swift](/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/DictationController.swift:743) |
| Cleanup and translation release each other's resident models | Confirmed load pattern; its actual latency cost still needs measurement | [AppDelegate.swift](/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/AppDelegate.swift:290); [AppDelegate.swift](/Users/enrico/Documents/GitHub/saiity/Sources/sAiity/AppDelegate.swift:821) |
| Release quality checks require rules-only cleanup, translation off and 2240 ms caption timing | Confirmed verification scope gap for enabled processing and Realtime timing | [quality-matrix.sh](/Users/enrico/Documents/GitHub/saiity/scripts/quality-matrix.sh:29); [release-quality.json](/Users/enrico/Documents/GitHub/saiity/docs/benchmarks/release-quality.json:1) |

Two initial audit suggestions were rejected after checking callers: failed Paste event creation already falls back honestly to Copied; retranslation cannot recreate a deleted directory. The 50-row overlay cap is also **not** a transcript-save cap: Save uses all committed sessionLines.

## Task 1: Protect saved text and finish stopping honestly

**Priority:** first. Existing transcript data must survive competing operations.

**Files:** AppDelegate.swift, CaptionSession.swift, SettingsWindow.swift, SettingsPages.swift, Retranslate.swift, TranscriptStore.swift and SegmentCache.swift.

- [ ] Keep caption resource occupancy busy throughout starting, running and stopping. Keep the existing isActive semantics for actions, but expose Stopping to the existing UI state; disable Start until teardown actually finishes.
- [ ] Reject summary/retranslation admission during caption teardown. Retain the start guard and native inference gate.
- [ ] Read retranslation input from one captured byte snapshot using the existing segments-from-Data utility. Compare that snapshot and replace the result in the existing TranscriptStore actor, serially with app-owned writes. If it changed, preserve the current file and report that retranslation was not published.
- [ ] Make retention skip/defer protected work. Listing may remain off the main actor, but the final busy check and deletion admission must not have an intervening suspension that admits a conflicting operation.
- [ ] Return deletion success/failure from the existing deletion functions. Invalidate caches only after successful removal and report actual successful counts.
- [ ] Keep summary-only removal, atomic writes and file permissions intact. Do not add a database or a new persistence service.

**Acceptance:** hold teardown open and verify no enabled Start or new library operation; append a final spoken line or translation patch during a fake retranslation and prove it survives; attempt retention during summary and retranslation; simulate deletion failure and prove the UI does not claim removal.

**Tests:** SessionStateTests.swift, RetranslationSafetyTests.swift, TranscriptStoreTests.swift and TranscriptSummaryTests.swift, using temporary libraries and held fake work. Also test concurrent retranslation of the same session, not only two different sessions.

## Task 2: Make setup and model readiness direct

**Priority:** first, alongside stage 1. This is the quickest improvement to successful first use.

**Files:** SettingsPages.swift, SettingsWindow.swift, OnboardingView.swift, SettingsStateHonesty.swift, TranslationTargetPicker.swift, AssetControl.swift and Resources/Info.plist.

- [ ] Put the selected cleanup model's size and **Download & Use** action beside its chooser. After successful installation, enable cleanup only if that same model remains selected. Cancellation, failure or a changed selection must not enable it.
- [ ] Keep generic Models downloads as downloads, rather than enabling features automatically.
- [ ] Show the effective translation engine's installation state and download action next to its target. “Supports this language” must remain distinct from “ready on this Mac.” Make a required large download visible before the first dictation.
- [ ] Compute Dictation readiness from its effective recognizer and microphone state as well as shortcut permission. Distinguish not-yet-requested permission from denial, and missing download from a prepared model.
- [ ] Correct the microphone purpose to: “Used while dictating, and optionally to include your voice in captions. Audio stays on this Mac.” Verify the localized system prompt, not just the app's explanatory label.
- [ ] Keep choosing a translation target separate from explicit permission to translate dictation. Do not silently turn translation on.

**Acceptance:** fresh installation with recognition absent; microphone denied; cleanup selected then downloaded; download cancelled; selection changed mid-download; translator supported but absent. Every state must offer one clear next action and truthful readiness.

**Tests:** SettingsWindowTests.swift, OnboardingTests.swift, existing download/readiness tests, plus the actual signed-app permission trial.

## Task 3: Fix caption continuity and historical translations

**Priority:** next. The user should be able to read earlier rows while live speech continues.

**Files:** AppDelegate.swift, OverlayWindow.swift, CaptionHistory.swift, CaptionProcessing.swift and CaptionLiveTranslation.swift.

- [ ] Patch every retained sentence's final translation by sentenceID. Continue to suppress cleared IDs and stale session/translator generations; only current/recent completion should change shownTranslationID.
- [ ] Preserve the reader's scroll anchor. A historical translation must not force Jump to latest or attach to the newest sentence.
- [ ] Add tests through the real AppDelegate sentence path. Existing history tests call the overlay directly and cannot catch the caller's two-sentence cutoff.
- [ ] Cover partial revision followed by final, punctuation closure, comma/colon pause, ordinary pause, the length cap, clear during speech and stop with an unfinished tail.
- [ ] Keep authoritative spoken words and sentence content complete. Improve display wrapping/stability without shortening the transcript to make latency figures look better.
- [ ] Make sustained translation overload visible beside caption state while continuing to show originals. Keep the bounded queue; do not replace it with an unlimited backlog.

The late-row correction should stay this small inside the existing guards:

```swift
let behind = self.displayLifecycle.sentenceID - sentenceID
self.overlay.showTranslation(out, forSentenceID: sentenceID, stale: behind > 0)
if behind <= 1 { self.shownTranslationID = sentenceID }
```

**Acceptance:** delay sentence N's translation until N+2 is visible; N updates without changing N+1/N+2 or scrolling. Repeat with hidden bubble, translation display off, cleared/evicted rows and stop/start. Saved order must agree with spoken order.

**Tests:** SentenceAssemblyTests.swift, CaptionLifecycleTests.swift, CaptionHistoryTests.swift, OverlayWindowTests.swift and CaptionLiveTranslationTests.swift. Use mocked engines for ordinary tests.

## Task 4: Measure and improve the full dictation path

**Priority:** next; measure first, then make the smallest demonstrated improvement.

**Files:** AppDelegate.swift, DictationController.swift, DictationCleanupSession.swift, DictationCleanupValidator.swift, LocalGeneration.swift, TranslationRuntime.swift and the existing benchmark tests.

The application already keeps models warm for roughly five minutes. Extending that timeout will not fix cleanup and translation releasing each other's weights.

- [ ] Benchmark 5–10-second dictations repeatedly with rules-only cleanup, model cleanup, translation, and both enabled. Measure cold and warm preparation, transcription, cleanup, translation, release-to-result, delivery, memory and load count.
- [ ] Compare draft text on/off separately. Streaming drafts intentionally cost an additional authoritative segmented decode; reuse must prove equivalent final coverage and language preservation before replacing that path.
- [ ] Keep deterministic cleanup as the cheap first pass. For clean input, verify that it does not call the model. For model-required input, report accepted output, rejected output and unavailable model accurately.
- [ ] Fix the copied-but-described-as-inserted branch. Preserve the existing safe copy-only fallback when focus changed or Paste cannot be sent.
- [ ] Carry enough outcome information through the existing cleanup result to distinguish rules-only success from requested model cleanup falling back. Avoid an alarming error when the deterministic result was sufficient.
- [ ] If measured reload cost dominates, first reduce unnecessary model calls and preparation work. Retain both large models only after proving that the target 16 GB Mac does not swap or regress under pressure; keep inference sequential.
- [ ] Compare the supported installed Nemotron and Whisper options against the same corpus. Change the recommendation only when complete-word accuracy, language preservation and latency improve together. Do not add another engine on reputation alone.

**Acceptance:** no missing beginning/end, names/numbers/negation preserved, mixed languages remain mixed with translation off, whole message reaches the chosen language with translation on, cancellation never delivers a late result, and every memory optimization has before/after evidence.

**Tests:** DictationControllerTests.swift, DictationCleanupSessionTests.swift, DictationCleanupValidatorTests.swift, ModelLifecycleTests.swift, WhisperModelCacheTests.swift, DictationTranscriptionTests.swift and DictationASRPerformanceTests.swift.

## Task 5: Simplify the everyday UI using the current design

**Priority:** after readiness semantics are correct.

Keep system type/colors, native window controls, GroupBox sections, the current sidebar and the existing shared views. This is an information/layout pass.

| Page | Everyday controls | More options |
| --- | --- | --- |
| Captions | Start/Stop + live status, output language, timing preset, bubble appearance presets | Alternative recognition/translation engines, capture source, microphone inclusion, speakers, pause tuning, dictionary, shortcut editing, fine layout |
| Dictation | Enabled + shortcut, processing preset with a one-line explanation, optional translation target, cleanup choice/readiness, appearance presets | Recognition alternatives, detailed timing, manual language for Whisper, realtime drafts, dictionary, fine layout |
| Transcripts | Search and compact session rows; existing reader and session menu | Retention and export details; keep summary actions in the reader |
| Setup | Feature-specific readiness and direct repair/download actions | Diagnostics, startup details and About |
| Models | Installed/downloaded size, active use and explicit Download/Resume/Repair/Delete | Legacy asset cleanup, custom GGUF import |

- [ ] Keep the cleanup chooser direct. A simpler default screen must not bury the model/readiness repair behind a second sheet.
- [ ] Explain Fast/Balanced/Accurate with their actual processing behavior. Do not present Accurate as a measured quality guarantee.
- [ ] Keep selected advanced engines identifiable in a quiet current-model caption, even when their chooser is collapsed.
- [ ] Move appearance presets into the everyday section; keep fine controls collapsed. Reuse BubbleStylePresetControl rather than adding another style system.
- [ ] Make preset previews show representative text/translation or waveform/result proportions instead of nearly identical placeholder bars.
- [ ] Give error/loading/ready state one consistent location. Avoid duplicating model warnings and controls across Quick controls, More options and separate sheets.
- [ ] Check minimum width, German/Japanese labels, keyboard focus, VoiceOver, increased contrast and reduced motion. Do not introduce animation that moves controls or resizes the titlebar unexpectedly.

**Acceptance:** someone can enable dictation, repair a missing model and choose translation from one page; captions can start without selecting an engine name; advanced choices remain available and keep existing preferences.

**Design references used:** Apple HIG windows — system-defined window UI; layout — enough space for essential information; settings — a brief explanation of options; generative AI — honest disclosure and user control. Fresh visual verification is still needed.

## Task 6: Improve saved-session and bubble feedback

**Priority:** polish after the functional fixes, not a second transcript redesign.

**Files:** SettingsPages.swift, DictationToastWindow.swift, AppDelegate.swift, TranscriptStore.swift and Export.swift.

- [ ] Preserve the resizable transcript reader and local-summary attribution. Keep SRT/WebVTT spoken-only.
- [ ] Put successful bubble Save feedback where the user clicked: “Saved to Transcripts” with a way to open the saved session. The current save status is mainly in the menu bar.
- [ ] Explain that bubble history is limited but saving uses all committed session lines. Test saving more than 50 lines; do not wrongly increase the UI history cap to fix a non-existent save cap.
- [ ] Keep generated dictation text recoverable after delivery problems, Copy Original and Retry Copy. Add a modest persistent-result choice only if testing shows the existing 4.5-second dismissal prevents reading/copying; failure recovery already persists.
- [ ] On deletion/export failure, identify the session and what remains. Keep success feedback quiet; do not add repeated modal alerts for ordinary successful actions.

**Acceptance:** Save from the bubble is visibly confirmed; the saved session includes more than the last 50 rows; no summary removal changes spoken lines; delivery failure never hides the only retained output.

## Task 7: Verify real speech, languages and speakers

**Priority:** begins with the performance baseline and gates recommendation changes.

**Files:** existing DictationASRPerformanceTests.swift, CaptionASRPerformanceTests.swift, CaptionEndToEndTests.swift, CaptionSpeakerTests.swift, scripts/caption-matrix.sh, scripts/model-matrix.sh and docs/release-checklist.md.

- [ ] Use an authorized natural-speech corpus with reviewed references and provenance. Keep recordings and transcripts outside Git and logs.
- [ ] Cover German/English, French/Spanish and at least one non-Latin language; fast/quiet speech, numbers, names, technical words, fillers, false starts, noise/music and continuous speech.
- [ ] Test language switches without a deliberate pause, including German → English → German and English → Chinese → English. Region segmentation and language heuristics alone are not accuracy evidence.
- [ ] Test both 1120 and 2240 ms caption tiers and representative enabled translation/cleanup combinations.
- [ ] Keep speaker labels optional, anonymous and evidence-based. Verify two-person turns and overlap; do not claim to separate simultaneous speech or infer people from wording/language changes.
- [ ] Add deterministic speaker-frame checks for duplicate/overlapping/out-of-order intervals and incomplete coverage. Treat these as robustness tests until a real upstream violation is demonstrated, not as a proven everyday diarization failure.
- [ ] Verify device changes, Bluetooth, sleep/wake, Low Power Mode and pressure on actual hardware. A WAV replay does not prove those workflows.

**Acceptance:** record first text/final latency, release-to-result, word omissions/errors, language-span preservation, dropped audio, queue delay and peak memory. Device and real-model outcomes remain separate from mocked tests.

## Task 8: Make release evidence match what users enable

**Priority:** required before claiming the whole improvement cycle complete.

**Files:** scripts/quality-matrix.sh, scripts/verify-quality.py, scripts/benchmark_evidence.py, docs/benchmarks/release-quality.json, .github/workflows/macos.yml, docs/release-checklist.md, README.md and docs/ROADMAP-2.0.md.

- [ ] Extend existing matrix/config fingerprints to include Realtime timing and cleanup/translation enabled. Keep unsupported combinations explicit rather than treating a skipped probe as a pass.
- [ ] Retain exact revision, corpus/model checksums, hardware, configuration and p50/p95 (median and slow-end response time). Avoid replacing these with one favorable average.
- [ ] Establish tighter latency goals on the target Mac before changing hard release limits. Current ceilings permit 5 seconds to first partial caption, 8 seconds to first final and 8 seconds from release to insertion, which is too permissive for the desired feel.
- [ ] Store durable release evidence with the matching build. Historical Mac mini notes and temporary log paths are useful history, not fresh MacBook results.
- [ ] Rewrite the README's first-use path as a short setup guide; move deep model/benchmark detail lower down. Update the roadmap that still calls the shipped summary the next feature.
- [ ] Review the public release/Pages content using ego-browser once available. The source repository and public distribution repository are distinct; do not deploy source docs to the wrong repository.
- [ ] A release, DMG, Sparkle update and public-page update are final steps after verification and a release request. This review does not publish anything.

### Proposed product targets — to validate, not measured results

For a named 16 GB Apple Silicon reference Mac, warm installed models and 5–10-second speech fixtures:

| Path | Proposed p95 goal |
| --- | --- |
| First meaningful caption in Realtime mode | ≤ 2.5 s from speech onset |
| Rules-only dictation, release to result | ≤ 2.5 s |
| Dictation with model cleanup | ≤ 4 s |
| Dictation with cleanup and translation | ≤ 5 s |
| Retained-row translation update after decode finishes | Next UI update, without scroll jump |
| Caption audio dropped under the supported workload | 0 s |

These are starting product goals. Report an engine that cannot meet them, and explain the quality/memory trade-off. Never discard audio, normalize mixed language, silently disable requested processing or weaken the corpus to meet a number.

## Verification commands and completion gates

Run focused regression tests while implementing, then one supported full release test run and normal build:

```sh
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS
./build-app.sh --no-test-hooks
build/sAiity.app/Contents/MacOS/sAiity --selftest 20
PYTHONDONTWRITEBYTECODE=1 python3 Tests/release_quality_test.py
PYTHONDONTWRITEBYTECODE=1 python3 Tests/benchmark_evidence_test.py
```

For real-model checks, use the existing matrix scripts with authorized fixture environment variables and installed model weights. Missing corpus/hardware/models remain named outstanding gates. Verify macOS 26 and 27, including the previously affected M4 MacBook Air, and test actual TextEdit/another editable app, secure fields, focus changes and upgrade preservation.

Completion requires independent evidence for deterministic correctness, real-model quality, signed-app workflows, native visual/accessibility behavior and any requested release/publication. Passing one gate does not imply the rest.

## What was checked during this review

- Clean main at 44f8a6f, current source and relevant tests, workflows, package pins, build/release scripts and recorded benchmark/checklist evidence.
- Fresh Python release-quality checks: 7 tests passed. Fresh benchmark-evidence checks: 4 tests passed.
- Existing local bundle passed verify-release.sh: version 2.6.6, build 224, valid resources/signature and no release test hooks. This was not a new build, notarization run or upgrade test.
- Native UI inspection was blocked by “Sky Computer Use native pipe closed before response.”
- ego-browser/ego lite was not available at the required MacBook path or on PATH; no alternate browser was used.

No fresh full Swift suite, real speech/latency experiment, Gemma generation, live permission trial, Bluetooth/sleep test, native visual/accessibility pass or public Pages/CI-state check was performed. Model kernels/vendor internals and the unsupported Windows prototype were not audited line by line.

**Recommended order:** stages 1–2 first; then 3 and the stage-4/7 baseline; then measured processing improvements and stage 5; finish 6 and 8. Keep unsupported experiments out of the default setup while retaining legacy downloads' removal paths.


