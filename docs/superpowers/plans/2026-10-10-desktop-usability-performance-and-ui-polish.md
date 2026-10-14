# sAiity Desktop Usability, Performance and UI Polish Implementation Plan

> **For agentic workers:** Use `subagent-driven-development` or `executing-plans` to implement one bounded task at a time. Checkbox steps track implementation and verification separately.

**Goal:** Make local captions and dictation easier to set up, faster to diagnose, safer to recover, and more polished to read and control.

**Architecture:** Extend the existing capture, dictation, diagnostics, AppState and transcript owners. Keep the shared native views, inference serialization and storage protections; introduce no new manager/service layer or dependency. Changes to presentation must preserve the identity and lifetime of the running speech pipeline.

**Tech stack:** Swift, SwiftUI, AppKit, AVFoundation/Core Audio, the pinned local speech/translation runtimes, Swift Testing and the existing benchmark scripts. macOS 26+ on Apple Silicon.

**Status, 10 October 2026:** Implementation authorized: “Start with it and create a cron to make sure it's completed.” Continue from the current checkpoint and preserve the reviewed PRR/PQL baseline. The existing `continue-saiity-desktop` recovery heartbeat now covers this cycle every 30 minutes; it resumes interrupted work and stays quiet when state is unchanged.

**Implementation checkpoint, 11 October 2026:** Native UI spacing/adaptive presets, microphone observations, correlated diagnostics, memory-only recent recovery, explicit application exceptions, and transcript reveal/naming are implemented. The first integrated focused run passed 278 tests / 14 suites; Python checks passed 30 tests. Independent source reviews identified and main fixed secure copy-only admission, failed-load telemetry and isolated setup resume. Native toast focus still needs an app-loop proof because the SwiftPM test process cannot activate a key window. Four explicit focus-host tests are skipped unless opted in; this is not device acceptance. German everyday layouts at 760/860/980 pt are captured in `build/desktop-polish-20261010/layout-de/`; wider localized reader/composited checks and final full build verification remain pending. Task 4, microphone calibration, natural-speech/reviewer and actual device/upgrade gates remain open. Resume from `.superpowers/sdd/progress.md`; earlier intermediate logs are not the latest completion state.

**Reviewed checkpoint:** The latest supported suite passed 808 registered tests / 82 suites in 13.306 seconds, with 24 explicit opt-ins skipped. A native application-loop proof passed ten focus/idle/recording/draft checks. One inherited queue test was stabilized by waiting for its observed calls with a five-second bound; every original assertion remains. Localized reader captures cover en/de/fr/es/ja, compact/default/large sizes, an 81-line late search match and 26 pt body/summary text. Default/large show the match; shrinking an already-scrolled reader can move it outside the smaller viewport. Content captures are layout evidence. Native computer use failed with `Sky Computer Use native pipe closed before response`, leaving compositor, full keyboard traversal, measured contrast and human VoiceOver open. Final hook-free build evidence is recorded in the ledger when available.

**Latest code evidence:** Two additional diagnostic regressions established and fixed preparation-wait correlation and the once-only terminal for release before capture. The final supported suite is now **810 registered tests / 82 suites passed in 13.084 seconds**, build 102.89 seconds, with the same 24 explicit opt-in skips. Independent implementation review is APPROVED with no remaining Critical/Important findings. Final local candidate and layout evidence is consolidated in `build/desktop-polish-20261010/README.md`. Implementation checkboxes do not close the remaining speech, calibration, device, upgrade or full native UI acceptance gates.

**Local candidate verified:** The final hook-free signed `2.7.0-rc.3/225` bundle built in 235.50 seconds and passed resource/framework/signature checks plus all 32 native smoke checks. The ten-check native application-loop focus proof also passed. Independent final content captures close the two small preset/recent-feedback polish findings. The candidate is local and not installed, notarized or published. Overall plan acceptance remains open for Task 4 and the named natural-speech, calibration, physical workflows, upgrade, compositor, full keyboard/menu and human VoiceOver gates; the existing recovery automation therefore remains active.

## Starting point

Repository: `/Users/enrico/Documents/GitHub/saiity`. Inspected branch: `codex/product-release-ready`; HEAD: `44f8a6f0deaa737f5edab6238b68de3f5db0c3fa`. The checkout contains preserved PRR/PQL changes. Read `.superpowers/sdd/progress.md` again before execution; do not assume this checkpoint is still current.

The current language implementation and available local checks are complete. Recorded evidence is 728 registered Swift tests / 81 suites, 30 Python checks and 32 signed native smoke checks. Twenty explicit model/device opt-ins were skipped. The signed local `2.7.0-rc.2/225` candidate is not notarized. Those results do not prove natural-speech quality, native processing speed or hardware workflows.

Already present, and to reuse:

- Separate caption/dictation translation choices, conservative language handling, safe cleanup and original-text recovery.
- Direct model Download & Use/repair controls, honest readiness state and optional production-path setup trials.
- Visible bubble presets, automatically fitted bubble text, collapsed More options and native resizable transcript reading.
- Cross-session transcript search, final-only storage, summaries with disclosure/language choice, atomic publication and deletion safeguards.
- App-specific system-audio capture, caption history/Jump to latest, serialized realtime translation and content-free timing diagnostics.

Specific remaining opportunities confirmed in the code:

| Current behavior | Proposed improvement |
| --- | --- |
| `DictationController.onTiming` reports individual operations; diagnostics aggregate them by operation | Correlate one dictation's preparation, recognition, processing and delivery without retaining its words |
| Try Dictation runs the real pipeline, but capture exposes a waveform rather than an input-health explanation | Show the active microphone and observational quiet/clipping hints in that existing trial |
| Original dictation recovery is a single memory snapshot, cleared by the next recording | Offer an explicitly enabled, bounded recent-result list in memory |
| A transcript search hit sets only `state.transcriptToOpen = hit.session` | Open and reveal the matching segment, preserving its surrounding context |
| `SessionMeta` has dates and counts but no optional user title | Let people name a session without editing spoken text |
| Pages reuse native groups but have independently composed rows and long helper copy | Apply a consistent hierarchy and adaptive layout using the existing views |

Related accepted work: `docs/superpowers/plans/2026-10-09-product-quality-and-language-coverage.md`. Its unresolved corpus, reviewers, model measurements and device gates remain obligations; they are not reset by this plan.

## Global constraints

- Preserve dirty/untracked files, recovery metadata, user preferences, installed models and transcript data. No reset, unrelated cleanup or blanket staging.
- The subsequent start instruction authorizes local implementation and recurring recovery checks. Publication, commits/pushes, model downloads, new recordings, permission changes and installed-app replacement still require the applicable authorization.
- For subsequent implementation, use the smallest complete changes in existing files. No component rewrite, new theme system or speculative abstraction.
- Preserve the shared translation-target bridge, original recovery, busy ownership, cancellation draining, exact source Unicode and storage admission rules.
- Preserve captions' Clear behavior: clear displayed content while captions continue. Preserve the removal of the refinement feature.
- Translation remains intentional. App rules must not infer a language or activate translation silently.
- Recent dictations are off by default and never persisted. Transcripts retain their separate existing opt-in storage policy.
- Workers use `sub2api/gpt-6.1-sol`. Main owns serial Swift builds/tests/native inference. Respect provider reset times; no repeated futile retries or model substitution.
- Use ego-browser for any website interaction; diagnose its absence instead of switching browsers.
- Do not run native model probes alongside a competing installed app. Do not stop that app without the applicable user authorization.
- New tests use temporary transcript libraries and isolated preference domains. Never access the real transcript library or replace live preferences to arrange a test.
- Reuse passed baseline evidence while its source/build remains unchanged. Test new behavior and repeat broader checks after relevant changes.

## Product and UI direction

**Design thesis:** A quiet Mac utility whose text is the focus. At a glance, a person should know what it will listen to, what it will do to the words, and what happened to the result.

The recommended approach is an incremental polish of the current native app. A new dashboard or a full visual redesign would introduce navigation and component work without solving the known speech/recovery problems. A processing-only cycle would leave the requested UI improvement incomplete.

### Layout and visual rules

These spacing values are project design decisions, not claims that Apple mandates them.

| Element | Concrete direction |
| --- | --- |
| Page geometry | Reuse the existing 24 pt horizontal inset and 780 pt maximum content column; align every page's groups and disclosure header to that column |
| Section rhythm | 20 pt between unrelated sections; 12 pt between related rows; 6–8 pt between a label and its supporting copy |
| Typography | System font; `.title2` for a page heading when needed, `.headline` for groups, `.body` for controls and reading, `.callout` for useful supporting information; avoid essential status in tiny `.caption2` |
| Color | `windowBackgroundColor`, `textBackgroundColor`, primary/secondary label, separator and control accent roles; use the system's current values rather than hard-coded hex colors |
| Primary action | One prominent action per task: Start/Stop Captions, Try Dictation or Done. Repair actions appear next to the missing requirement |
| Presets | Keep visible previews; selected card has a clear outline and checkmark plus an accessible selected state. Adapt to two columns when four no longer fit |
| Advanced options | Keep the existing single More options disclosure, collapsed initially. Whole header remains a 28 pt-or-larger button with a visible focus state |
| Long rows | Use `ViewThatFits` or a stacked layout when translated labels no longer fit. Do not solve overflow by shrinking labels or clipping model names |
| Status | Place icon + words + a relevant recovery action beside the feature/result. Do not convey readiness or failure through color alone |
| Glass | Preserve the existing optional Liquid Glass bubble preset. Keep transcript reading surfaces and settings content legible; add no glass to transcript text or decorative stacked cards |
| Motion | Preserve Reduce Motion, use brief transitions only for a deliberate state change, and avoid repeated shimmer or animated progress decorations |
| Window chrome | Retain the shared opaque settings/setup base and system titlebar/traffic lights. Test active/inactive appearance in the actual compositor |

Keep bubble font fitting automatic. At large content sizes, wrap and allow scrolling rather than shrinking text below a readable size. The reader must support larger reading text without assuming that iOS Dynamic Type exists on macOS; use the existing font-fitting controls and a native reader text-size adjustment where needed.

### Page-by-page polish

| Surface | Desired result |
| --- | --- |
| Setup | Current short feature → model → permission → trial flow; one clear next action and a useful trial result, with optional microphone health underneath |
| Captions | Start/Stop and state first; Capture source and Translate to next; appearance previews after behavior; detailed models/timing/speakers/vocabulary inside More options |
| Dictation | Shortcut and Try Dictation first; effective processing/translation choices together; appearance previews next; recent-result opt-in and application exceptions in More options |
| Models | Stable name/action alignment, selected vs installed vs recommended distinctions, progress/failure beside the model; use existing AssetControl rather than another download UI |
| Caption bubble | Spoken text leads, translation is distinguishable, speaker annotations stay quiet, and the compact control strip has stable geometry and comfortable targets |
| Dictation bubble | Recording/processing/result states share a stable control strip; copied/inserted/fallback outcomes remain truthful; Copy Original/Retry Copy stay easy to reach |
| Transcripts | Search at the top of Saved sessions; optional name, date/count/language and a quiet Summary marker; one action menu; reader opens the exact search match |
| General/support | Task-oriented grouping and short descriptions; detailed diagnostics remain in troubleshooting; About & Support retains a visible dismissal action |

### Layout sketches

Illustrative regular settings layout; preserve the existing sidebar and native window frame:

```text
┌──────────────────┬────────────────────────────────────────────────┐
│ Setup            │ Captions                       [Start Captions]│
│ Captions         │ Ready · Local processing                       │
│ Dictation        │                                                │
│ Models           │ Capture source       [Everything            ▾] │
│ Transcripts      │ Translate to         [Off                   ▾] │
│                  │                                                │
│                  │ Bubble appearance                              │
│                  │ [Minimal] [Balanced ✓] [Readable] [Liquid Glass]│
│                  │                                                │
│                  │ ▸ More options                                 │
└──────────────────┴────────────────────────────────────────────────┘
```

At a narrower width, retain reading order and stack long rows:

```text
Captions
[Start Captions]   Ready · Local processing

Capture source
[Everything                                      ▾]
Translate to
[Off                                             ▾]

Bubble appearance
[Minimal             ] [Balanced ✓              ]
[Readable            ] [Liquid Glass             ]

▸ More options
```

The signature is the existing live text/bubble preview: people see the actual reading treatment before choosing it. Surrounding settings stay quiet. Remove redundant explanation and duplicate visual indicators; retain information that distinguishes installation, compatibility and actual use.

### Design evidence and limits

Reviewed current source and the saved German synthetic layouts in `build/product-language-20261010/layout-de/`, including the session list and compact summary reader. Those captures support layout and wrapping review. `SelfCapture` explicitly omits full window chrome and can omit material/accent compositing, so this plan does not diagnose contrast or titlebar defects from those images alone.

Guidance used from Apple Design's local HIG references:

- `layout.md › Best practices`: “Make essential information easy to find by giving it sufficient space.”
- `settings.md › Best practices`: “Minimize the number of settings you offer.”
- `feedback.md › Best practices`: “Consider integrating status feedback into your interface.”
- `windows.md › Best practices`: “Avoid creating custom window UI.”
- `typography.md › Ensuring legibility`: “Use font sizes that most people can read easily.”
- `color.md › System colors`: “Avoid hard-coding system color values in your app.”
- `accessibility.md › Mobility`: macOS default control target 28×28 pt; aim for that size, with space between controls.
- `searching.md › Best practices`: “Clearly display the current scope of a search.”
- `onboarding.md › Best practices`: “Teach through interactivity.”
- `liquid-glass.md › Review checklist`: opaque fallback under Reduce Transparency; stronger fills/borders under Increase Contrast.
- `designing-for-macos.md › Best practices`: preserve native commands, keyboard access and adaptable windows.

Measure rendered text/background contrast during composited QA: 4.5:1 for ordinary body/supporting text and 3:1 for large text under the applicable criteria. No contrast ratio is inferred from a content-only screenshot. System semantic colors take precedence over inventing a fixed palette for this utility.

## Execution order and ownership

| Wave | Tasks | Independent work and dependency |
| --- | --- | --- |
| A | 1–2 and Task 7's search-reveal checkpoint: UI foundation, input health and direct search navigation | UI owner changes SettingsWindow/SettingsPages; capture owner changes DictationMicrophoneCapture/tests. Main integrates shared page/AppDelegate wiring serially |
| B | 3–4: one-run diagnostics and measured quality/speed | Requires unchanged source/corpus settings; deterministic diagnostics can proceed while approved recordings/reviewers are unavailable |
| C | 5–7: recent recovery, application rules and transcript naming | Work in separate owners where possible; SettingsPages, AppDelegate, AppState and storage integration have one editor at a time |
| D | 8: bubble polish and whole-product qualification | Integrate completed behavior, then validate presentation, long sessions and actual delivery; release follows a separate release request |

Recheck active workers before assigning a task. Do not start another owner on the same file. Each task ends with its own reviewable diff and evidence; a later task must not hide an earlier failed gate.

## Task 1: Polish the existing native settings and reader layout

**Syllivra naming follow-up, 12 October 2026:** The human-selected name is implemented across the local app, executable/product, menus/setup/localizations, new exports/diagnostics, installer and current build/release/CI callers. Stable app/data/model/preferences/automation/internal module identifiers preserve compatibility; remote repo/feed and historical links are retained. RC8/225 passed the full supported 823-test/82-suite run (24 existing opt-ins skipped), 30 Python checks, hook-free build/signature/resources, 32 synthetic native checks and fresh mounted local DMG validation. Evidence: `build/syllivra-rename-20261012/README.md`; artifact: `/Users/enrico/Downloads/Syllivra-2.7.0-rc.8-local.dmg`. Local/unnotarized/uninstalled; actual single-copy installation, TCC/login upgrade, custom Finder placement, full native UI and the broader speech/reviewer/calibration/device gates remain open. The existing recovery monitor has the new display name and current browser policy; its schedule/scope/gates are unchanged.

**Font control follow-up, 12 October 2026:** Local RC7/225 moves the existing native Font size slider directly below the shared preset cards on both caption/dictation pages. Existing persistence, live updates, ranges and localized labels are retained; no new setting/schema was added. Full supported verification passed 823 registered tests / 82 suites with 24 existing opt-ins skipped; English/German content layouts, hook-free build, 32 synthetic smoke checks and mounted local DMG verification passed. At compact widths the slider follows the two-column cards below the initial viewport. Evidence: `build/font-slider-20261012/README.md`; artifact: `/Users/enrico/Downloads/sAiity-2.7.0-rc.7-local.dmg`. Actual keyboard/VoiceOver/compositor and the broader accepted speech/device gates remain open.

**Follow-up candidate, 12 October 2026:** Local RC6/225 includes the shared background transparency toggles and a test-first caption Stop ordering fix. Capture stops before waiting on preview translation, while final ASR/translation/Save/storage drains retain their existing owner. Full supported verification passed 823 registered tests / 82 suites with 24 existing opt-ins skipped; the hook-free build, 32 synthetic smoke checks and fresh mounted local DMG verification passed. Evidence is in `build/caption-stop-20261011/README.md`; DMG is `/Users/enrico/Downloads/sAiity-2.7.0-rc.6-local.dmg`. It is unnotarized and uninstalled. Real capture/Stop clicks, speech/reviewer, performance/calibration, device/upgrade and native UI gates remain open; the recovery heartbeat remains active.

**Modify:** `Sources/sAiity/SettingsWindow.swift` (`SettingsSection`, `SettingsDisclosure`, native window setup), `Sources/sAiity/SettingsPages.swift` (quick controls, `BubbleStylePresetControl`, model rows, reader action layout), `Sources/sAiity/OnboardingView.swift`, `Resources/Localizable.xcstrings`.

**Verify through:** existing `Sources/sAiity/SelfCapture.swift`, `Tests/sAiityTests/SettingsWindowTests.swift`, `Tests/sAiityTests/SettingsStateHonestyTests.swift`, `Tests/sAiityTests/OnboardingTests.swift`. Extend SelfCapture only for missing synthetic states, not to read user content.

**Interface:** Existing bindings and native shared views remain the source of state. Presets modify appearance only; process settings and saved preferences remain independent.

- [ ] Record the proposed before/after layout at the existing minimum, 760, 860 and 980 pt settings widths; use 560×480 and 820×800 reader sizes. Confirm the actual NSWindow minimum before choosing compact breakpoints.
- [x] Apply the shared spacing/type rules in current view bodies; replace only overflowing HStacks with adaptive/stacked layouts. Keep the existing four preset choices and single disclosure.
- [ ] Make selected, unavailable, downloading, stopped, running and failed states distinguishable with accessible words/icons. Preserve native action styling and the placement of the actual primary action.
- [ ] Wrap summary actions and the mixed-summary language row at compact widths. Keep the existing model disclosure, Summarize Again/Remove Summary and spoken text as primary reading content.
- [x] Localize new copy for de/en/fr/es/ja; verify that long labels wrap without shrinking the content.
- [x] Run the focused existing settings/onboarding suites after behavior wiring changes. For spacing-only edits, use layout/native interaction checks instead of tests that merely assert padding constants.

**Pass when:** All current settings are reachable, everyday controls are visible, advanced details remain collapsed, long localized labels fit, and the UI preserves caption/dictation state while changing appearance. Native keyboard focus and full header click targets work. Existing native titlebar opacity tests continue to pass.

## Task 2: Add observational microphone health to Try Dictation

**Modify:** `Sources/sAiity/DictationMicrophoneCapture.swift`, the existing capture interface in `Sources/sAiity/DictationController.swift`, `Sources/sAiity/Onboarding.swift`, `Sources/sAiity/OnboardingView.swift`, `Sources/sAiity/AppDelegate.swift`, `Sources/sAiity/SettingsPages.swift`, `Resources/Localizable.xcstrings`.

**Tests:** `Tests/sAiityTests/DictationMicrophoneCaptureTests.swift`, `Tests/sAiityTests/DictationControllerTests.swift`, `Tests/sAiityTests/OnboardingTests.swift`.

**Proposed interface:** Add a small `DictationInputHealth` value in the existing microphone file: accepted sample count, RMS dBFS, clipped-sample fraction and observed duration. Its accumulator consumes the accepted buffer once; an optional snapshot on the existing capture interface defaults to unavailable for captures that cannot report it. It holds no audio/text and resets each session.

- [x] Write regressions for empty buffers, zero signal, finite normal samples, repeated near-full-scale samples, nonfinite input and reset between sessions. Keep capture sample-conservation and drain assertions intact.
- [x] Run only those new tests and confirm their intended failures before behavior edits.
- [x] Calculate statistics over accepted frames without copying buffers or creating a second microphone tap. Update the displayed hint at most once per second using the existing UI update path; do no UI work on the audio callback.
- [ ] Show the active input device name from Core Audio, the live waveform and a text hint in the existing explicit trial. Initial copy: “Speak a short sentence to check this microphone.” After sufficient signal: “Input is very quiet” or “Input may be clipping”, with a relevant device/settings action.
- [ ] Treat 2 seconds of observation, RMS below −50 dBFS and more than 1% samples at magnitude ≥0.995 as provisional hint criteria, not speech-quality certification. Confirm/update these criteria with approved built-in/USB/Bluetooth microphone trials before shipping warnings.
- [ ] Keep low-volume, clipped or unknown-health audio in the normal recognition path. Health must not silently reject speech, change gain, start capture on its own or request another permission.
- [ ] Confirm Stop/closing setup stops capture and drains callbacks; a setup trial still neither pastes nor changes the clipboard.

**Pass when:** The user can identify the microphone and investigate obvious input problems in the existing trial. Pure lifecycle/statistics checks pass, and actual device calibration is recorded separately. Quiet speech that transcribes correctly must not be labelled unusable.

## Task 3: Correlate existing timings into one content-free dictation run

**Modify:** `Sources/sAiity/Diagnostics.swift`, `Sources/sAiity/DictationController.swift`, `Sources/sAiity/AppDelegate.swift`, `Sources/sAiity/LocalGeneration.swift`, `Sources/sAiity/Translators.swift` only where actual model-load events are available; troubleshooting in `Sources/sAiity/SettingsPages.swift`.

**Tests:** `Tests/sAiityTests/DiagnosticsTests.swift`, `Tests/sAiityTests/DictationControllerTests.swift`, `Tests/sAiityTests/DictationCleanupSessionTests.swift`.

**Proposed interface:** Extend `DiagnosticsRuntimeTiming` with optional `runID: String?`, `outcome: String?`, `fallbackReason: String?`, `modelLoadCount: Int?` and `modelCallCount: Int?`; keep its existing `cold` field. These fields need compatible initializer defaults and legacy Codable tests. Keep outcomes to controlled codes for inserted/copied/copy-failed/cancelled/failed. Populate fallbackReason only from an observed cleanup-unavailable, translation-unavailable or validation-rejected outcome; leave it nil when no such observation exists. Carry one random run ID through the controller's existing timing callback; do not encode transcript text, target field contents, window titles or filenames into it.

- [x] Add regressions for decoding legacy records, interleaved run IDs, cancellation during each processing stage, terminal outcome only once, finite durations and bounded diagnostics history.
- [x] Keep existing aggregate p50/p95 rows; add a grouped troubleshooting view for the last run with preparation, recognition, cleanup, translation and delivery durations. Explain the result in ordinary words, such as “Most time was spent loading the cleanup model.”
- [x] Record cold/warm only from actual load/readiness observations. Count native/model calls and loads at their invocation sites, not from the selected preference or the number of text regions.
- [x] Include capture start and release-to-delivery; preserve the difference between inserted, copied, copy failed, cancelled and processing fallback. Keep numeric stage details out of everyday bubble controls.
- [x] Bound stored timing events to the existing history policy and verify DiagnosticsRedactor still excludes speech/source content.
- [x] Run the focused diagnostics/controller/cleanup suites serially. Inspect a synthetic exported report before any real-content run.

**Pass when:** One slow or failed dictation can be attributed to its actual stage and outcome, including cold loading, without logging what the person said. Older diagnostic data remains readable.

## Task 4: Establish real-speech evidence, then optimize the measured bottleneck

**Existing owners:** `Sources/sAiity/DictationBenchmarking.swift`, `Sources/sAiity/DictationTranscription.swift`, `Sources/sAiity/DictationController.swift`, `Sources/sAiity/DictationCleanupSession.swift`, `Sources/sAiity/TranslationRuntime.swift`, `Sources/sAiity/MemoryPolicy.swift`, `Sources/sAiity/CaptionLiveTranslation.swift`, `Tests/sAiityTests/DictationASRPerformanceTests.swift`, `Tests/sAiityTests/CaptionASRPerformanceTests.swift`, `scripts/quality-matrix.sh`, `docs/benchmarks/release-quality.json`, `docs/benchmarks/README.md`.

**Consumes:** Task 3's correlated measurements; the accepted language roadmap's corpus/provenance/review/scoring contracts. **Produces:** A before/after result for a specific bottleneck or explicit evidence that changing it is unjustified.

- [ ] Reuse the existing twelve initial cohorts and reviewed source/target references. Start with the reported Japanese/English/Chinese problems as a bounded investigation, then complete the required matrix; do not substitute synthesized audio for natural-speech acceptance.
- [ ] Require authorized licensed/consented audio and independent native source/target/semantic review before inference. If absent, record this gate once and proceed with independent UI/code tasks.
- [ ] Compare identical recordings and settings across the installed recommended recognizers. Record raw recognition errors before cleanup, processed-output omissions/facts and translation failures separately.
- [ ] Capture cold preparation, warm five-run p50/p95, model load/reload counts, process footprint/memory pressure, and release-to-insert/copy. For captions, record first useful original, stable final and first/final target text plus dropped audio and backlog.
- [ ] Change only the largest demonstrated repeat cost: unnecessary preparation, a duplicate language pass, avoidable cleanup calls or model reloads. The earlier bounded language cache already exists; do not recreate it.
- [ ] Test one residency change at a time. Keep serial native inference; do not introduce simultaneous large-model residency until the 16 GB reference Mac has no pressure/swap regression in the tested workload.
- [ ] Add a failing regression at the changed lifecycle/call-count boundary, implement the smallest fix and rerun the exact affected corpus cells. Re-run broader cells only when that change affects them.
- [ ] Keep current recommendations and decoding settings until raw/final quality and latency improve together. A faster result obtained by dropping speech or disabling requested translation fails.

**Goals to validate, not measured promises:** Warm 5–10-second dictation p95 ≤2.5 seconds with rules, ≤4 seconds with model cleanup and ≤5 seconds with cleanup plus translation. First useful realtime caption ≤2.5 seconds from speech onset. Preserve existing release ceilings; calibrate target-caption limits using actual reviewed measurements.

**Pass when:** Build-matched, reviewed evidence demonstrates a specific quality-preserving gain. If evidence supports no safe change, retain current runtime behavior and record why. Missing corpus/hardware is still an open gate, not a passing optimization.

## Task 5: Offer bounded recent dictations without disk history

**Modify:** `Sources/sAiity/DictationState.swift`, `Sources/sAiity/AppDelegate.swift`, `Sources/sAiity/DictationController.swift` (delivery-completion hook), `Sources/sAiity/TextInsertion.swift`, `Sources/sAiity/SettingsWindow.swift`, `Sources/sAiity/SettingsPages.swift`, `Resources/Localizable.xcstrings`.

**Tests:** `Tests/sAiityTests/SessionStateTests.swift`, `Tests/sAiityTests/DictationControllerTests.swift`, `Tests/sAiityTests/TextInsertionTests.swift`.

**Proposed interface:** A bounded array on the existing main-actor state, using `DictationResultSnapshot` plus a random identity and completion date. Add a final delivery callback carrying the snapshot and `TextInsertionResult`, because current `onResult` runs before `inserter.insert` and cannot establish the delivery outcome. Add `var secureTargetObserved: Bool = false` to that existing result value, populated from the inserter's existing single target snapshot; do not change its clipboard/paste semantics. Exclude observed secure-target runs from the new history. Unavailable accessibility information cannot certify that a field was nonsensitive. The preference is only an enabled Boolean; capacity is five and combined raw/output content is capped at 100,000 characters.

- [x] Add tests for opt-out retaining no history, six results evicting the oldest, total character bounds, Unicode preservation, duplicate completion suppression and clearing on disable.
- [x] Verify that trials, cancelled/stale runs and secure-field-refused delivery do not populate history. A valid copy failure may be retained for recovery, with its real status.
- [x] Keep the current single-result Copy Original behavior regardless of the new opt-in. History opens only when requested and offers Copy Result/Copy Original; it never pastes into a newly focused app.
- [x] Add one More options toggle: “Keep the last 5 dictations until quitting.” Explain that nothing is saved to disk and turning it off clears this list.
- [x] Add a Recent Dictations menu command opening a compact native list with completion time, outcome and explicit copy controls. Avoid transcript previews in the menu; reveal words only in the opened list. Include Clear Recent Dictations.
- [ ] Verify the recent array is excluded from preferences, diagnostics, transcript exports and any recovery artifact. Use synthetic words to inspect these boundaries.

**Pass when:** A user who opted in can recover an earlier result without retaining a durable microphone transcript. Off, Clear and quit remove the new history. Copy actions preserve exact Unicode and never trigger insertion.

## Task 6: Add one explicit application exception for original text

**Modify:** `Sources/sAiity/DictationState.swift`, `Sources/sAiity/SettingsWindow.swift`, `Sources/sAiity/SettingsPages.swift`, `Sources/sAiity/DictationController.swift`, `Sources/sAiity/AppDelegate.swift`, `Sources/sAiity/TextInsertion.swift` only if its existing focus token needs a small extension; `Resources/Localizable.xcstrings`.

**Tests:** `Tests/sAiityTests/SettingsStateHonestyTests.swift`, `Tests/sAiityTests/DictationControllerTests.swift`, `Tests/sAiityTests/TextInsertionTests.swift`.

**Smallest feature:** An explicit set of application bundle IDs that should receive original recognition text. Inherit global settings everywhere else. This delivers the Terminal/editor use case without a second preset/model/translation configuration system.

**Proposed policy interface in the existing dictation state file:**

```swift
func usesOriginalText(bundleIdentifier: String?, exceptions: Set<String>) -> Bool {
    guard let bundleIdentifier else { return false }
    return exceptions.contains(bundleIdentifier)
}
```

The function is a proposed pure helper, not implemented by this document. Caller behavior must also be tested; membership alone is not adequate verification.

- [ ] Add a pure membership regression and controller regressions proving the captured app wins over a later focus change, unknown apps inherit, and preference edits affect only the next recording.
- [x] Capture the effective exception once at press-down using `DictationFocusToken.bundleIdentifier`. Do not inspect document contents or identify a language from the app name.
- [x] For an exception, deliver authoritative recognition text without dictionary replacement, lexical/model cleanup or translation. This is an explicit user-selected exception; it cannot repair wrong ASR words or promise correct shell commands.
- [x] Skip unnecessary cleanup/translator preparation for this session. Keep source recognition, sample conservation, cancellation and secure-field/focus checks unchanged.
- [x] Add an Application Exceptions group inside Dictation's existing More options. Use the native application chooser, list named apps with Remove, and show “Original text · cleanup and translation off for this app.” Empty by default; no automatic Terminal rule.
- [x] Show a quiet effective-mode note while that exception applies. Global controls retain their stored values and indicate inheritance/override rather than being silently overwritten.
- [ ] Test raw paragraphs, casing, technical punctuation and mixed scripts through final output and copying; removal restores global settings on the next run.

**Pass when:** An explicit application exception reliably chooses the original text for the app captured at recording start, without changing global settings or silently applying elsewhere.

## Task 7: Reveal transcript search matches and support optional session names

**Modify:** `Sources/sAiity/SettingsWindow.swift` (existing transcript-open state), `Sources/sAiity/SettingsPages.swift` (`TranscriptsView`, search/open callers, `TranscriptViewerSheet`), `Sources/sAiity/TranscriptStore.swift`, `Sources/sAiity/SegmentCache.swift` only if required for targeted metadata invalidation, `Sources/sAiity/Export.swift`, `Resources/Localizable.xcstrings`.

**Tests:** `Tests/sAiityTests/TranscriptStoreTests.swift`, `Tests/sAiityTests/SettingsWindowTests.swift`, `Tests/sAiityTests/ExportCueTests.swift`, with the existing temporary transcript-library scope.

**Proposed interfaces:** Add `AppState.transcriptSegmentToReveal: Int?` beside the existing `transcriptToOpen` and expose one `AppState.openTranscript(_ session: SessionRef, revealing segment: Int? = nil)` helper that sets both fields. Update all existing open callers to use it, pass the anchor as `TranscriptViewerSheet.initialSegmentIndex: Int?`, and clear it when the reader closes. Add `title: String?` to `SessionMeta` and `TranscriptStore.renameSession(_ session: SessionRef, title: String?) throws` on the existing actor.

**Review checkpoints:** Search reveal can ship independently in Wave A. Rename/metadata/export safety is a separate checkpoint in Wave C; search approval is not rename approval.

- [ ] Add regressions for opening a search result at the correct segment, switching sessions clearing the anchor, missing segments opening safely, and a normal Open returning to the ordinary reader state.
- [x] Use a `ScrollViewReader` around the existing spoken-line list, retain stable segment IDs, reveal after async load, and mark the matching row using the system find-highlight treatment. Preserve full surrounding speech rather than filtering the reader to one line.
- [ ] Ensure the anchor still opens when a summary is above the speech and works for a late match in a long transcript. Cmd-F and keyboard navigation remain useful in the reader.
- [x] Add backward-compatibility tests for metadata without a title and tests for rename failure, blank-title reset, multilingual titles and concurrent metadata updates.
- [x] Limit a user title to 80 Characters, reject multiline/control-containing titles, and let blank clear it. Preserve meaningful Unicode and never use the title as a filesystem path or session identity.
- [x] Rename by reading the latest metadata inside the store actor, changing only title and atomically publishing mode-0600 metadata. Reject missing/outside/symlink/active recording targets using the existing storage rules. Never recreate a deleted session or overwrite newer counters/dates/targets with a stale SessionRef.
- [x] Compare exact `segments.jsonl`, `summary.json` and existing exported-file bytes before/after both successful and failed rename. Invalidate only relevant list metadata and refresh the visible session after success.
- [x] Put Rename in the existing row menu and use the shared SheetShell for the short input task. Display title if present, with date/count/language underneath; retain the Summary caption. Include the optional title in newly generated Markdown/text exports; SRT/WebVTT spoken cues remain unchanged.

**Pass when:** A search click takes the user straight to the spoken line, and naming a session changes only compatible metadata and new human-readable export headings. Stored speech, summary, identity and existing files survive.

## Task 8: Polish bubbles and qualify the complete native workflow

**Modify where checks demonstrate a need:** `Sources/sAiity/OverlayWindow.swift`, `Sources/sAiity/DictationToastWindow.swift`, `Sources/sAiity/BubbleSurfaceView.swift`, `Sources/sAiity/BubbleGeometry.swift`, `Sources/sAiity/CaptionStyle.swift`, existing touched views and localization.

**Tests:** `Tests/sAiityTests/OverlayWindowTests.swift`, `Tests/sAiityTests/SettingsWindowTests.swift`, `Tests/sAiityTests/DictationControllerTests.swift`, existing history/lifecycle/geometry suites. Extend SelfCapture with synthetic representative states only.

- [ ] Keep a stable control strip across listening, processing, result and failure states. Give icon-only actions at least a 28×28 pt target and accessible labels; keep captions' Clear distinct from Stop and dictation's recovery actions distinct from dismissal.
- [ ] Keep original and translated speech distinguishable through labels/structure as well as color. Preserve speaker annotations, paused scrolling and Jump to latest.
- [ ] Confirm changing a bubble preset does not recreate the speech/result owner, hide waveform/text/symbols or reset the recording. Confirm result-to-idle returns to the compact bubble geometry.
- [ ] Avoid automatic dismissal while a person is selecting text, using keyboard/VoiceOver controls or handling a copy failure. Preserve the existing ordinary idle behavior when interaction is over.
- [ ] Check light/dark, active/inactive windows, Reduce Motion, Reduce Transparency, Increase Contrast and 200% reader text. Verify CJK, halfwidth forms, Arabic/Hebrew mixed direction, Thai, Indic combining marks, long terms and numerical facts on screen and after copy/export.
- [ ] Use native composited observations to check accent controls, chrome and actual contrast. Content-only layouts are a separate evidence category.
- [ ] Run consented long caption sessions with translation off/on and optional mic mixing. Exercise Clear/restart, pending translations, Save over 50 lines, repeated short dictations, cancellation, model removal while busy, and memory-pressure behavior.
- [ ] Test built-in/USB/Bluetooth input, device changes, sleep/wake and permission denial/recovery on available macOS 26/27 hardware. Test TextEdit and another ordinary app, changed focus, secure fields and Retry Copy. Record every unavailable combination explicitly.
- [ ] Confirm a previous-version upgrade retains presets, vocabulary, translation choices, transcript metadata, summary compatibility and opt-out defaults for the new recent list/application exceptions.

**Pass when:** Native interactions and reading are polished without changing capture/storage/delivery semantics, and the actual device matrix has recorded outcomes. A passing layout capture cannot stand in for VoiceOver, field insertion or long-session speech evidence.

## Verification commands and completion rules

Run from `/Users/enrico/Documents/GitHub/saiity`. Main executes native commands serially. Keep model/device opt-ins disabled for deterministic focused tests; run installed-model probes only with approved inputs and an uncontended process.

Focused commands after the relevant tasks:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer NSUnbufferedIO=YES \
  xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS \
  --filter 'SettingsWindowTests|SettingsStateHonestyTests|OnboardingTests'

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer NSUnbufferedIO=YES \
  xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS \
  --filter 'DictationMicrophoneCaptureTests|DictationControllerTests|DiagnosticsTests|TextInsertionTests|SessionStateTests'

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer NSUnbufferedIO=YES \
  xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS \
  --filter 'TranscriptStoreTests|ExportCueTests|TranscriptSummaryTests|RetranslationSafetyTests|OverlayWindowTests'
```

For each nontrivial new behavior, first run its new test method alone and record the intended RED, then the affected suite GREEN. Do not weaken old assertions. Shared-state tests must use the established serialized suites and isolated roots.

Final integration after relevant source changes:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer NSUnbufferedIO=YES \
  xcrun swift test -c release -Xswiftc -enable-testing -Xswiftc -DSAIITY_TEST_HOOKS
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests -p '*_test.py'
./build-app.sh --no-test-hooks
scripts/verify-release.sh build/sAiity.app
build/sAiity.app/Contents/MacOS/sAiity --selftest 20
git diff --check
```

Expected: affected/full deterministic suites pass, packaging verification and native smoke exit 0, no whitespace errors. Preserve the actual new test count and skipped cases; do not assume the previous 728-test count remains current.

Capture synthetic UI using the existing SelfCapture workflow in an isolated preview bundle/domain and temporary library, with dictation disabled, retention 0 and the pre-launch transcript-routing flag. The capture process may not inspect the real saved library. For actual microphone/model/device checks, the prerequisites above govern execution.

### Separate acceptance categories

| Category | Required evidence |
| --- | --- |
| Implementation | Reviewed bounded diffs; regression RED/GREEN; callers/resources/exports updated |
| Local candidate | Supported full suite, normal hook-free signed build, resources/native smoke and source/build hashes |
| Visual polish | Localized compact/regular layouts plus native composited chrome, focus and contrast checks |
| Speech quality | Authorized natural recordings, independently reviewed source/target/meaning, per-engine/mode/language outcomes |
| Performance | Same-input quality-preserving cold/warm latency, load/reload counts, footprint and caption backlog/target calibration |
| Device workflows | Actual permission, capture, Bluetooth/sleep, insertion, accessibility, upgrade and long-session results |
| Distribution | Applicable gates closed, clean reviewed source with commit authority, release request, notarization/assets/update/public-site verification |

Do not collapse these categories into “release ready” from a passing unit suite. Preserve source patches and artifact hashes for local candidates. Do not publish, update Sparkle/GitHub Pages or delete the existing heartbeat while its accepted gates remain open.

## Effort and first deliverable

| Work | Planning estimate |
| --- | --- |
| Native settings/reader polish and localized layouts | 1–2 engineering days |
| Microphone health and grouped run diagnostics | 1–2 days, plus device calibration |
| Recent recovery and the small application exception | 2–3 days |
| Transcript reveal/naming and storage regressions | 1–2 days |
| Bubble polish, integration and local candidate | 1–2 days |
| Real-speech profiling/optimization and device qualification | Depends on approved recordings, reviewers and hardware; budget separately |

Estimate: 6–11 engineering days for the bounded local code/UI cycle, excluding data/reviewer/device wait time. This is an effort estimate, not a completion date or a promise of universal language accuracy.

The first useful deliverable is the polished everyday Captions/Dictation pages, the existing trial with microphone health, and transcript search that opens the matching line. Start speech evidence collection in parallel when its inputs are authorized; use those measurements to choose the speed change.

## Deliberate limits

Keep the present native visual identity, system colors, optional bubble presets and existing shared components. This cycle adds no theme picker, AI chat/refinement, automatic translation, automatic meeting summary, background audio recording, persistent dictation history, new cloud service, model-switching heuristic or Windows scope. Longer files alone are not a reason to split them.

The app can preserve correct recognition and reject some unsafe processing, but it cannot infer missing spoken words or certify a model's meaning from text heuristics. Real speech, actual native interaction and an authorized distribution workflow remain required for their respective acceptance claims.
